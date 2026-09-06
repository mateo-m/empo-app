import index from "../landing/index.html";
import fan from "../landing/proposals/fan.html";
import split from "../landing/proposals/split.html";
import title from "../landing/proposals/title.html";
import windowPage from "../landing/proposals/window.html";
import wordmark from "../landing/proposals/wordmark.html";

// Bun's dev server answers 403 to any Host header that is not the hostname it
// listens on. Set LANDING_HOST to a tailnet name to reach it through Tailscale.
const server = Bun.serve({
  hostname: process.env.LANDING_HOST ?? "localhost",
  port: 8791,
  routes: {
    "/": index,
    "/split": split,
    "/title": title,
    "/window": windowPage,
    "/wordmark": wordmark,
    "/fan": fan,
  },
  development: { hmr: false },
});

console.log(server.url.href);
