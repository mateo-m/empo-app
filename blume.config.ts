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
    // README.md is the GitHub view of this folder. The site uses index.mdx.
    exclude: ["**/_*", "**/.*", "README.md"],
  },
  theme: {
    accent: "#fa8f29",
    radius: "md",
    mode: "system",
  },
  navigation: {
    sidebar: [
      "/",
      {
        label: "Play",
        items: ["/install", "/importing-games", "/playing", "/troubleshooting"],
      },
      {
        label: "Ship a game",
        items: ["/controls-format", "/config-format"],
      },
      {
        label: "Internals",
        items: [
          "/how-it-works",
          "/multi-ruby",
          "/multi-session",
          "/pause-resume",
          "/import-pipeline",
          "/sheet-design",
        ],
      },
      {
        label: "Legal",
        items: ["/privacy", "/terms"],
      },
      {
        label: "Contributing",
        href: "https://github.com/mateo-m/empo-app/blob/main/CONTRIBUTING.md",
      },
      {
        label: "Discord",
        href: "https://discord.gg/m3YnpXMxrB",
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
