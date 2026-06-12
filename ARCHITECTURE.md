# Architecture — Undertone

Undertone: fully local system-wide dictation for macOS, inspired by Superwhisper: system-wide voice-to-text with on-device
transcription and local-LLM post-processing. This document is the source of truth for
the system design; the module layout under `Sources/` mirrors the components described
here one-to-one.

---

## 1. Goals and non-goals

**Goals**

- **Fully local.** Audio never leaves the machine. Transcription runs on-device
  (Core ML / Metal / ANE). LLM post-processing talks only to `localhost` (Ollama,
  LM Studio, llama-server). The app makes no other network calls except model
  downloads, which are explicit, user-initiated, and from Hugging Face.
- **System-wide.** Works in any app: press a hotkey anywhere, speak, and the text
  lands at the cursor.
- **Feature parity with Superwhisper** (built in phases, §9): dictation, AI modes
  with custom prompts, per-app mode activation, file transcription, meeting
  (system-audio) recording, history, and custom vocabulary.
- **Single-binary simplicity.** One menu-bar app, no helper daemons, no kernel
  extensions, no virtual audio drivers.

**Non-goals**

- Intel Macs. Inference performance depends on Apple Silicon (ANE/Metal).
- Windows/Linux. The system-integration layer (TCC, AX, CGEvent, Core Audio taps)
  is macOS-specific by nature.
- Multi-user/server deployment, accounts, sync, telemetry. None of these exist.

**Platform floor: macOS 14.4, Apple Silicon.**
14.0 gives us SwiftData and `@Observable`; 14.4 is required by Core Audio process
taps (§7), which power meeting recording. This is the same floor VoiceInk (the
leading open-source app in this category) settled on.

---

## 2. System overview

One process: a SwiftUI `MenuBarExtra` agent app (`LSUIElement = true`, no Dock icon).
All features are front-ends to a single pipeline:

```
                       ┌────────────────────────────────────────────────┐
                       │                DictationSession                │
                       │   idle → recording → transcribing → enhancing  │
                       │        → inserting → idle   (cancellable)      │
                       └────────────────────────────────────────────────┘
  HotkeyManager ──────────────┘     │            │            │
  (key down/up)                     ▼            ▼            ▼
                              AudioRecorder  Transcription  LLMProvider
  ActiveAppMonitor ──► mode   (AVAudioEngine  Engine        (llama.cpp embedded /
  (frontmost app)     select   16 kHz mono)  (WhisperKit)    Ollama HTTP / Apple FM)
                                                  │            │
  FileTranscriber ──► decode ──► same engine      ▼            ▼
  MeetingRecorder ──► mic + system tap       TextInserter ──► frontmost app
                                             (paste / AX)
                                                  │
                                                  ▼
                                             HistoryStore (SwiftData)
```

Design rules:

1. **`DictationSession` is the only orchestrator.** Every other component does one
   thing and is driven by the session. No component talks to another behind the
   session's back.
2. **Everything behind a protocol where there is a real second implementation**
   (`TranscriptionEngine`, `TextInserter`) — and *only* there. No speculative
   abstraction for components with one sensible implementation (recorder, hotkeys).
3. **All pipeline stages are `async` and cancellable.** Pressing Esc (or the hotkey
   again, configurable) cancels the in-flight `Task` at any stage; cancellation
   restores the clipboard if insertion had begun.

---

## 3. Speech-to-text: pluggable engines, WhisperKit first

### The protocol

```swift
protocol TranscriptionEngine {
    var isReady: Bool { get }
    func prepare() async throws                       // load / download model
    func transcribe(_ audio: TranscribableAudio,
                    options: TranscriptionOptions) async throws -> TranscriptionResult
}
```

`TranscribableAudio` is 16 kHz mono `[Float]` PCM — the lingua franca every Whisper
implementation and Apple's APIs can consume. Both live dictation and file
transcription normalize to it (§6.4), so engines never deal with formats.

`TranscriptionOptions` carries: language (or auto), an optional *initial prompt*
(used for vocabulary biasing, §6.7), and translation flag.

### Engine choice and trade-offs

| Engine | Speed | Accuracy | Languages | Why / why not |
|---|---|---|---|---|
| **WhisperKit** (Argmax) — **primary** | Good (ANE + Metal via Core ML) | Whisper large-v3 class | 99+ | Swift-native, async API, ships pre-converted Core ML weights, handles model download + storage. The least glue code by far. |
| whisper.cpp via SPM (`whisper.spm` / SwiftWhisper) | Good (Metal), but Metal support in the SPM packaging has been historically patchy | Same models | 99+ | More control, but we'd own model download, Core ML encoder conversion, and C-interop. Not worth it while WhisperKit exists. Revisit only if WhisperKit becomes a liability. |
| Apple `SpeechAnalyzer` (macOS 26+) | Fastest cold-start (no download, OS-managed) | Best-in-class on clean speech; ~20 languages | 20 | Excellent **second engine**: zero-download default for users on macOS 26. Gated behind `#available`; our floor stays 14.4. |
| Parakeet (MLX) | Fastest decode (≈2× whisper.cpp) | Beats Whisper on disfluent English | English only | No mature Swift binding; MLX dependency. Future engine candidate, the protocol accommodates it. |

**Decision:** ship `WhisperKitEngine` in P1. Add `AppleSpeechEngine` (SpeechAnalyzer)
as a `#available(macOS 26, *)` option later — the protocol exists precisely so this
is additive. The settings UI exposes engine + model choice the way Superwhisper's
"Voice Models" picker does.

**Model storage:** WhisperKit downloads to its managed directory under
`~/Library/Application Support/Undertone/Models`. Model selection
(tiny/base/small/large-v3-turbo, `.en` variants) is a settings field; `prepare()`
re-resolves it. Recommended default: `base.en` for instant results, with a one-click
upgrade prompt to `large-v3-turbo` for accuracy.

**Silence/hallucination guard:** Whisper hallucinates on near-silent audio
("thank you for watching"). Before transcribing, the session computes RMS energy of
the capture; below threshold, the result is discarded and the session ends quietly.
A VAD pre-pass (WhisperKit ships one) is the P2 upgrade.

---

## 4. Audio capture

### 4.1 Microphone (`AudioRecorder`)

`AVAudioEngine` with a tap on `inputNode`, converted on the fly to 16 kHz mono
Float32 via `AVAudioConverter`, accumulated in memory (dictation is seconds-to-
minutes; 16 kHz mono Float32 is ~3.8 MB/min — no disk spill needed). Exposes:

```swift
func start() throws
func stop() -> [Float]          // returns the full utterance
var levelStream: AsyncStream<Float>   // RMS levels for the recording HUD
```

The level stream drives the small floating recording indicator (waveform/level
meter), which is also the visual confirmation that the hotkey registered.

Input device selection follows the system default; a settings override sets
`kAudioOutputUnitProperty_CurrentDevice` on the engine's input AudioUnit.

### 4.2 System audio for meetings (`SystemAudioTap`)

Three possible mechanisms, one clear winner:

| Mechanism | Verdict |
|---|---|
| **Core Audio process taps** (`CATapDescription` + `AudioHardwareCreateProcessTap` + aggregate device, macOS 14.4+) | **Chosen.** Audio-only, no video entanglement, no driver install. TCC prompt: "wants to record system audio" (`NSAudioCaptureUsageDescription`). Reference implementation: [insidegui/AudioCap](https://github.com/insidegui/AudioCap). |
| ScreenCaptureKit audio capture | Works (12.3+), but drags in Screen Recording permission and screen-capture machinery for an audio-only need. Documented fallback if the tap API misbehaves on a future OS. |
| Virtual audio driver (BlackHole-style) | Requires separate install + audio-device juggling. Violates the single-binary goal. Rejected. |

Meeting mode records **two tracks** — mic (`AudioRecorder`) and system audio
(`SystemAudioTap`) — and transcribes them separately, labeling segments "Me" /
"Others", then interleaves by timestamp. This dual-track approach gives speaker
attribution for free, without diarization models. Tracks are written incrementally
to disk (meetings are long), as CAF files in a temp dir, then chunk-transcribed.

---

## 5. LLM post-processing: pluggable providers (`LLMProvider` + modes)

### Provider abstraction

Like transcription, enhancement hides behind a protocol so the runtime is a
settings choice, not an architectural commitment:

```swift
protocol LLMProvider: AnyObject {
    func isAvailable() async -> Bool
    func enhance(_ transcript: String, systemPrompt: String,
                 model: String?, temperature: Double?) async throws -> String
    func listModels() async throws -> [String]
}
```

| Provider | Ships | Trade-off |
|---|---|---|
| **`LlamaCppProvider`** — embedded llama.cpp, in-process (Metal) | P3, then becomes the **default** | Truly self-contained single app: downloads a small GGUF (default ~4B, e.g. Qwen-class) on first LLM-mode use, same UX as the Whisper model download. We own model files, memory pressure, and load/unload policy (unload after idle timeout). |
| **`OpenAICompatProvider`** — HTTP to `localhost` | P2, the **first working provider** | A ~150-line `URLSession` client; one code path works unmodified against Ollama (`:11434/v1`), LM Studio (`:1234/v1`), and `llama-server` (`:8080/v1`). User brings any model their RAM allows; requires a server installed and running. Also covers "remote-but-private" home-server endpoints for free. |
| **`AppleFMProvider`** — Apple Foundation Models framework | P3+, optional | Zero download, OS-managed ~3B on-device model. Weakest quality of the three and `#available(macOS 26, *)`-gated; our floor stays 14.4. |

**Sequencing rationale:** the HTTP provider is days of work and unblocks the whole
modes feature in P2; the embedded provider is the better *product* (no external
install) and takes over as default in P3 once model management is solid. Provider
choice and per-provider settings (model, base URL) live in settings; modes can
override the model per-mode but not the provider.

**Embedded engine choice:** llama.cpp via its C API behind a small Swift wrapper,
linked as an xcframework built by a pinned-version script (its SwiftPM packaging
has been unstable historically — same reasoning as WhisperKit-over-whisper.spm
in §3, but here no maintained Swift-native equivalent exists). GGUF models stored
next to the Whisper models in App Support.

**Failure UX matters more than the happy path:** if the active provider is
unavailable (server not running, model not downloaded), the session *degrades to
raw transcription* — the text still gets inserted, with a menu-bar warning badge —
never a lost utterance. A settings "Test provider" button and a
`listModels()`-backed model picker handle setup.

### Modes (the product core)

A `Mode` is a SwiftData record:

```
Mode {
  name, icon
  engineModelOverride?         // e.g. force large-v3 for "Email"
  language?
  llmEnabled: Bool
  llmModel?, temperature?      // per-mode model override
  systemPrompt: String         // the user-editable instruction
  appRules: [AppRule]          // bundle IDs that auto-activate this mode (§6.3)
}
```

The enhancement request is always the same shape:

- **system**: the mode's prompt + a fixed guard ("Return only the rewritten text,
  no preamble") + vocabulary hints (§6.7)
- **user**: the raw transcript, optionally preceded by *context* — in Super Mode
  fashion, the focused window's selected text / AX text content can be included so
  the model adapts tone to what's on screen. Context capture is permission-gated
  and off by default.

Built-in starter modes seeded on first run: **Transcript** (no LLM), **Message**
(casual, strip filler), **Email** (formal), **Notes** (bullets), **Prompt** (clean
instruction for coding agents — the Claude Code / Cursor use case).

---

## 6. Feature data flows

### 6.1 Core dictation (P1)

1. Hotkey down (or toggle on) → `DictationSession.begin(mode:)` → `AudioRecorder.start()`, HUD appears.
2. Hotkey up (or toggle off) → `stop()` returns `[Float]`.
3. RMS silence check (§3) → `TranscriptionEngine.transcribe`.
4. Mode has `llmEnabled` → `LLMProvider.enhance(transcript, mode, context)`.
5. `TextInserter.insert(text)` into the frontmost app.
6. `HistoryStore.save(Transcript)` — raw text, enhanced text, mode, app bundle ID, duration, timings.

### 6.2 Hotkeys (`HotkeyManager`)

- **Toggle shortcuts** (start/stop per mode, "repeat last", "change mode"):
  [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
  — gives the recorder UI, persistence, and conflict handling for free, and exposes
  key-down *and* key-up events, which covers hold-to-talk for ordinary key combos.
- **Modifier-only push-to-talk** (hold right-⌘, double-tap fn — Superwhisper's
  signature interaction): not expressible as a Carbon hotkey; requires a
  `CGEventTap` on `flagsChanged`. This is an isolated, removable component:
  `ModifierKeyTap` (P2), which needs Input Monitoring permission only if enabled.

### 6.3 Per-app mode activation (`ActiveAppMonitor`)

Subscribes to `NSWorkspace.didActivateApplicationNotification`; publishes the
frontmost bundle ID. On session start, mode resolution is:
explicit user pick → `AppRule` match for frontmost app → default mode.
(Same model as Superwhisper's "Activate when using" per-mode app list.)

### 6.4 File transcription (P4)

Drag-and-drop onto the menu-bar icon / "Transcribe File…" menu item → `AVAudioFile`
(handles wav/mp3/m4a/mov/mp4 audio tracks) → `AVAudioConverter` to 16 kHz mono →
chunked through the same engine with timestamps → export as text/SRT/VTT from the
history detail view. Long files process in a background task with progress in the
menu.

### 6.5 Meeting recording (P5)

§4.2. Output lands in history as a timestamped, speaker-labeled transcript with an
optional "Summarize" action that runs the meeting through a summary mode.

### 6.6 History (`HistoryStore`)

SwiftData-backed list with search, copy raw/enhanced, re-run enhancement with a
different mode, and a retention setting (default: keep forever; options to
auto-purge). Audio is **not** retained by default (privacy-first); an opt-in keeps
per-utterance audio files for replay.

### 6.7 Vocabulary (`VocabularyEntry`)

Two complementary injection points:

1. **Whisper initial prompt** — entries are joined into the decoder's
   `initialPrompt`, biasing recognition toward names/jargon ("Juspay", "SwiftData",
   coworker names). Cheap and surprisingly effective.
2. **LLM correction** — entries with a `replacement` field ("hyperswitch →
   Hyperswitch") are appended to the mode's system prompt as correction rules; for
   no-LLM modes, exact/fuzzy string replacement runs locally.

### 6.8 Text insertion (`TextInserter`)

| Strategy | How | When |
|---|---|---|
| **`PasteInserter` (primary)** | Save current `NSPasteboard` contents → write text → synthesize ⌘V via `CGEvent` (vKey 9 + `.maskCommand`) → restore clipboard after a short delay | Default. The only approach that works essentially everywhere: Electron apps, terminals, browsers, Java apps. |
| `AXInserter` | `AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute, text)` | Opportunistic upgrade where the focused element supports it — inserts without touching the clipboard at all. Tried first, falls back to paste. |
| Per-character `CGEvent` typing | Synthesize each keystroke | Rejected as default: slow for long text, layout-dependent. Kept as a documented escape hatch for paste-hostile apps (some password fields/VMs). |

Clipboard restore is the classic race (user copies something during the delay).
Mitigations: short restore delay (~150 ms), `NSPasteboard.changeCount` check before
restoring (if the user changed the clipboard meanwhile, don't clobber it), and
marking our write with a custom pasteboard type so clipboard managers can ignore it.

---

## 7. Permissions & privacy model (TCC matrix)

| Permission | Needed for | When prompted | If denied |
|---|---|---|---|
| Microphone (`NSMicrophoneUsageDescription`) | All recording | First dictation | Hard requirement; onboarding blocks with a deep-link to Settings. |
| Accessibility (`AXIsProcessTrusted`) | ⌘V synthesis, AX insertion, focused-element context | Onboarding | Degrade: result is copied to clipboard + notification "press ⌘V". |
| Input Monitoring | `ModifierKeyTap` push-to-talk only | When user enables that trigger | Feature stays off; normal shortcuts unaffected. |
| System Audio Capture (`NSAudioCaptureUsageDescription`) | Meeting recording only | First meeting recording | Meetings record mic-only. |

Privacy invariants: no telemetry, no network beyond `localhost` + explicit model
downloads, audio discarded after transcription unless opted in, history stored
locally in App Support (user-deletable, excluded from backups optionally).

Because TCC identifies apps by bundle ID + code signature, the app must run as a
proper signed `.app` bundle even during development — hence the `Makefile` bundle
step (§8) with a stable bundle ID and at least ad-hoc signing.

---

## 8. Project layout, packaging, dependencies

```
Package.swift                       # SwiftPM; deps: WhisperKit, KeyboardShortcuts
Makefile                            # make app → assembles+signs .app; make run
Resources/Info.plist                # LSUIElement, usage strings, bundle ID
Sources/
  App/
    UndertoneApp.swift      # @main MenuBarExtra
    AppState.swift                  # observable root (session state, settings)
  Core/
    Session/DictationSession.swift  # §2 state machine
    Audio/AudioRecorder.swift       # §4.1
    Audio/SystemAudioTap.swift      # §4.2 (stub until P5)
    Transcription/TranscriptionEngine.swift
    Transcription/WhisperKitEngine.swift
    Enhancement/LLMProvider.swift   # §5 protocol
    Enhancement/OpenAICompatProvider.swift  # P2: Ollama/LM Studio/llama-server
    Enhancement/LlamaCppProvider.swift      # P3 stub: embedded, future default
    Enhancement/AppleFMProvider.swift       # P3+ stub: macOS 26 Foundation Models
    Enhancement/Mode.swift
    Insertion/TextInserter.swift    # §6.8
    Hotkeys/HotkeyManager.swift     # §6.2
    Context/ActiveAppMonitor.swift  # §6.3
    Storage/Transcript.swift
    Storage/VocabularyEntry.swift
    Storage/Persistence.swift       # ModelContainer setup
```

**Why SwiftPM + Makefile instead of a checked-in Xcode project:** no `.xcodeproj`
merge noise, Xcode users can still `open Package.swift`, and CI/Linux can at least
lint. The Makefile produces the real bundle TCC needs (§7): builds the release
binary, lays out `Contents/{MacOS,Resources}`, copies `Info.plist`, ad-hoc
codesigns.

**Dependencies (deliberately few):**
- `argmaxinc/WhisperKit` — transcription (§3)
- `sindresorhus/KeyboardShortcuts` — hotkey recording/persistence (§6.2)
- llama.cpp xcframework (P3, pinned build script — not SwiftPM, see §5) for the
  embedded provider

Everything else is OS frameworks: AVFoundation, CoreAudio, ApplicationServices
(AX), CoreGraphics (CGEvent), SwiftData, SwiftUI.

---

## 9. Phased roadmap (each phase shippable)

| Phase | Delivers | New surface area |
|---|---|---|
| **P1 — Core loop** | Hotkey → record → WhisperKit → paste. Menu-bar UI, model download, mic+AX onboarding, silence guard. | AudioRecorder, WhisperKitEngine, PasteInserter, HotkeyManager (toggle), DictationSession, minimal settings. |
| **P2 — Modes + LLM** | Mode CRUD UI, LLM enhancement via the provider abstraction (HTTP provider first), per-mode prompts/models, provider-test UX, push-to-talk (`ModifierKeyTap`), VAD. | LLMProvider, OpenAICompatProvider, Mode, ModifierKeyTap. |
| **P3 — Memory + embedded LLM** | History UI + search, vocabulary (both injection points), per-app mode rules, context capture (focused-text → prompt). Embedded llama.cpp provider lands and becomes default; Apple FM provider where available. | HistoryStore, VocabularyEntry, AppRule, ActiveAppMonitor, LlamaCppProvider, AppleFMProvider. |
| **P4 — Files** | Drag-drop file transcription, SRT/VTT export, background progress. | FileTranscriber. |
| **P5 — Meetings** | Dual-track system-audio + mic recording, speaker-labeled transcripts, summarize action. | SystemAudioTap, MeetingRecorder. |

---

## 10. Risks & open questions

- **Core Audio process-tap API fragility.** Sparsely documented; behavior has
  shifted across point releases. Mitigation: isolate in `SystemAudioTap`, keep the
  ScreenCaptureKit fallback documented, follow AudioCap.
- **Clipboard restore races** (§6.8). `changeCount` check is good but not airtight;
  ship the AX path early to reduce paste frequency.
- **Whisper hallucination on silence/noise.** RMS guard in P1, VAD in P2; keep raw
  text in history so users can always recover.
- **WhisperKit API drift.** Pin a major version; the engine protocol keeps the
  blast radius to one file.
- **LLM provider unavailable** (Ollama not installed, GGUF not yet downloaded).
  Modes that need it show a setup card; everything else works without it, and the
  pipeline always degrades to raw transcription rather than failing (§5).
- **Embedded llama.cpp ownership costs** (P3): GGUF download/update management,
  memory pressure alongside the Whisper model (mitigate: idle unload, conservative
  default model size), and maintaining a pinned xcframework build.
- **Open:** streaming transcription (decode while recording) — WhisperKit supports
  it; deferred until the batch path is solid since utterances are short.
  Diarization beyond two-track meetings — out of scope until P5 feedback.
