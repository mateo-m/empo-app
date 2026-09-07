const stillness = matchMedia("(prefers-reduced-motion: reduce)");
const layers = document.querySelectorAll("[data-depth]");
const tilt = document.querySelector("[data-tilt]");
const boat = document.querySelector("[data-boat]");

// Whole device pixels. A fractional offset makes Chrome resample a layer
// and draws hairlines at the edges of the pixel art.
function snap(value) {
  return Math.round(value * devicePixelRatio) / devicePixelRatio;
}

function setUnit() {
  const title = Math.min(Math.max(56, innerWidth * 0.2), 168);
  document.documentElement.style.setProperty("--unit", `${snap(title * 0.04)}px`);
}

function parallax(x, y) {
  for (const layer of layers) {
    const depth = Number(layer.dataset.depth);
    layer.style.setProperty("--px", `${snap(x * depth)}px`);
    layer.style.setProperty("--py", `${snap(y * depth)}px`);
  }
  tilt.style.setProperty("--rx", `${-y * 10}deg`);
  tilt.style.setProperty("--ry", `${x * 12}deg`);
}

const touch = matchMedia("(hover: none)");

addEventListener("pointermove", (event) => {
  if (stillness.matches || touch.matches) return;
  parallax(event.clientX / innerWidth - 0.5, event.clientY / innerHeight - 0.5);
});

// On a phone the parallax follows the tilt of the device. The first reading
// is the resting pose, and 30 degrees of tilt moves the layers as much as a
// pointer at the edge of the screen. iOS only reports the sensor after a tap.
let rest = null;
let smoothX = 0;
let smoothY = 0;
function tilted(event) {
  if (event.gamma === null || event.beta === null) return;
  rest ??= { beta: event.beta, gamma: event.gamma };
  let x = event.gamma - rest.gamma;
  let y = event.beta - rest.beta;
  const angle = screen.orientation?.angle ?? 0;
  if (angle === 90) [x, y] = [y, -x];
  else if (angle === 270) [x, y] = [-y, x];
  else if (angle === 180) [x, y] = [-x, -y];
  smoothX += (Math.max(-15, Math.min(15, x)) / 30 - smoothX) * 0.15;
  smoothY += (Math.max(-15, Math.min(15, y)) / 30 - smoothY) * 0.15;
  parallax(smoothX, smoothY);
}
function listenTilt() {
  addEventListener("deviceorientation", tilted);
  screen.orientation?.addEventListener("change", () => {
    rest = null;
  });
}
if (touch.matches && !stillness.matches && "DeviceOrientationEvent" in window) {
  if (typeof DeviceOrientationEvent.requestPermission === "function") {
    addEventListener(
      "pointerdown",
      () => {
        DeviceOrientationEvent.requestPermission()
          .then((state) => state === "granted" && listenTilt())
          .catch(() => {});
      },
      { once: true },
    );
  } else {
    listenTilt();
  }
}

function setWaterline() {
  setUnit();
  const hull = boat.getBoundingClientRect().bottom;
  document.documentElement.style.setProperty("--waterline", `${snap(hull)}px`);
}

function sail() {
  document.body.classList.remove("intro");
}

let landed = false;
function land() {
  if (landed) return;
  landed = true;
  sail();
  document.body.classList.add("afloat");
  boat.classList.remove("sailing");
  for (const name of ["--dx", "--dy", "--s"]) boat.style.removeProperty(name);
}

addEventListener("resize", setWaterline);

setWaterline();
if (stillness.matches) {
  land();
} else {
  const rect = boat.getBoundingClientRect();
  const scale = 1.6;
  boat.style.setProperty("--dx", `${innerWidth / 2 - (rect.left + rect.width / 2)}px`);
  boat.style.setProperty("--dy", `${innerHeight / 2 - (rect.top + rect.height / 2)}px`);
  boat.style.setProperty("--s", String(scale));
  boat.style.visibility = "visible";
  setTimeout(() => {
    boat.classList.add("sailing");
    sail();
    boat.style.setProperty("--dx", "0px");
    boat.style.setProperty("--dy", "0px");
    boat.style.setProperty("--s", "1");
    boat.addEventListener("transitionend", land, { once: true });
    setTimeout(land, 1000);
  }, 300);
}
