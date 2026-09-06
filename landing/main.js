const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const targets = document.querySelectorAll(".reveal");

if (reduceMotion || !("IntersectionObserver" in window)) {
  for (const el of targets) el.dataset.in = "";
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const siblings = [...entry.target.parentElement.querySelectorAll(":scope > .reveal")];
        const index = Math.max(0, siblings.indexOf(entry.target));
        entry.target.style.transitionDelay = `${index * 40}ms`;
        entry.target.dataset.in = "";
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -10% 0px" },
  );
  for (const el of targets) observer.observe(el);
}
