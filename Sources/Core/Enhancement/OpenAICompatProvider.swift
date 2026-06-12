import Foundation

/// OpenAI chat-completions over localhost (ARCHITECTURE.md §5). One code path
/// works against Ollama (:11434/v1), LM Studio (:1234/v1), and llama-server
/// (:8080/v1) — and any "remote-but-private" home-server endpoint.
final class OpenAICompatProvider: LLMProvider {
    struct Settings {
        var baseURL = URL(string: "http://localhost:11434/v1")!
        var defaultModel = "qwen3:4b"
        /// Unused by Ollama; LM Studio accepts any value.
        var apiKey: String?

        /// Settings-window values; falls back to the Ollama defaults above so
        /// the provider works before the user ever opens Settings.
        static func fromDefaults() -> Settings {
            let defaults = UserDefaults.standard
            var settings = Settings()
            if let url = defaults.string(forKey: SettingsKeys.llmBaseURL)
                .flatMap(URL.init(string:)) {
                settings.baseURL = url
            }
            if let model = defaults.string(forKey: SettingsKeys.llmModel), !model.isEmpty {
                settings.defaultModel = model
            }
            settings.apiKey = defaults.string(forKey: SettingsKeys.llmAPIKey)
            return settings
        }
    }

    /// Read fresh on every request so Settings-window edits apply immediately.
    var settings: Settings { .fromDefaults() }
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func isAvailable() async -> Bool {
        (try? await listModels()) != nil
    }

    func enhance(_ transcript: String,
                 systemPrompt: String,
                 model: String? = nil,
                 temperature: Double? = nil) async throws -> String {
        let request = ChatRequest(
            model: model ?? settings.defaultModel,
            messages: [
                ChatMessage(role: "system", content: systemPrompt + "\n\n" + LLMPromptRules.outputGuard),
                ChatMessage(role: "user", content: transcript),
            ],
            temperature: temperature,
            stream: false
        )
        let response: ChatResponse = try await post("chat/completions", body: request)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listModels() async throws -> [String] {
        let response: ModelsResponse = try await get("models")
        return response.data.map(\.id).sorted()
    }

    // MARK: - Transport

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = URLRequest(url: settings.baseURL.appendingPathComponent(path))
        applyHeaders(&request)
        return try await send(request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: settings.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        applyHeaders(&request)
        return try await send(request)
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = settings.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Wire types

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: ChatMessage }
        let choices: [Choice]
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }
}
