// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

const stillness = matchMedia("(prefers-reduced-motion: reduce)");
const layers = document.querySelectorAll("[data-depth]");
const tilt = document.querySelector("[data-tilt]");

addEventListener("pointermove", (event) => {
  if (stillness.matches) return;
  const x = event.clientX / innerWidth - 0.5;
  const y = event.clientY / innerHeight - 0.5;
  for (const layer of layers) {
    const depth = Number(layer.dataset.depth);
    layer.style.setProperty("--px", `${x * depth}px`);
    layer.style.setProperty("--py", `${y * depth}px`);
  }
  tilt.style.setProperty("--rx", `${-y * 10}deg`);
  tilt.style.setProperty("--ry", `${x * 12}deg`);
});
