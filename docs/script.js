// Scroll-reveal: stagger elements in as they enter the viewport. initial=false
// equivalent — elements already on screen at load reveal immediately.
const io = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      const delay = Number(entry.target.dataset.delay) || 0;
      setTimeout(() => entry.target.classList.add('in'), delay);
      io.unobserve(entry.target);
    }
  });
}, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });

document.querySelectorAll('.reveal').forEach((el) => {
  // Stagger siblings within the same grid/steps row.
  const stepIndex = el.style.getPropertyValue('--i');
  if (stepIndex) el.dataset.delay = parseFloat(stepIndex) * 110;
  io.observe(el);
});

// Subtle parallax on the ambient glow following the pointer.
const glow = document.querySelector('.glow');
if (glow && matchMedia('(prefers-reduced-motion: no-preference)').matches) {
  addEventListener('pointermove', (e) => {
    const x = (e.clientX / innerWidth - 0.5) * 30;
    glow.style.transform = `translateX(calc(-50% + ${x}px))`;
  }, { passive: true });
}
