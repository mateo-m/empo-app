import { defineConfig } from "blume";

export default defineConfig({
  title: "Empo",
  description: "Run RPG Maker games on iPhone and iPad.",
  logo: "/icon.png",
  banner: "Empo is pre-release. It is not on the App Store.",
  github: {
    owner: "mateo-m",
    repo: "empo-app",
    branch: "main",
  },
  content: {
    root: "docs",
    // README.md is the GitHub view of this folder.
    exclude: ["**/_*", "**/.*", "README.md"],
  },
  theme: {
    accent: "oklch(0.75 0.166 57.9)",
    background: "oklch(0.199 0.059 268.9)",
    radius: "md",
    mode: "dark",
    fonts: {
      display: { name: "Nunito", weights: [700, 900] },
      body: { name: "Nunito", weights: [500, 700, 900] },
    },
  },
  navigation: {
    sidebar: [
      "/introduction",
      {
        label: "Play",
        items: [
          "/requirements",
          "/install",
          "/importing-games",
          "/playing",
          "/saves",
          "/troubleshooting",
          "/faq",
          "/changelog",
          "/community",
        ],
      },
      {
        label: "Ship a game",
        items: ["/controls-format", "/config-format"],
      },
      {
        label: "Contribute",
        items: ["/how-it-works"],
      },
      {
        label: "Legal",
        items: ["/privacy", "/terms"],
      },
    ],
  },
  deployment: {
    output: "static",
    // GitHub Pages serves a project site under the repository name.
    site: "https://mateo-m.github.io",
    base: "/empo-app",
  },
});
