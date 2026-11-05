import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
  worker: {
    name: "empo-api",
    entrypoint: "./dist/worker.js",
    compatibilityDate: "2026-10-01",
    domains: ["api.empo.mateo.sh"],
    workersDev: false,
    // The callback URL carries the Patreon sign-in code.
    observability: { enabled: true, redactQueryString: true, logs: { enabled: true } },
    env: {
      PATREON_CLIENT_ID: bindings.text("jHgBCgNa35QBdjlUQvWheyZHsl87QdFdkutGjEMTwizv4VeCIDE0NaFIpOmC7Tsw"),
      PATREON_CAMPAIGN_ID: bindings.text("17081057"),
      PATREON_OWNER_USER_ID: bindings.text("23419145"),
      PATREON_CLIENT_SECRET: bindings.secret(),
      // Ed25519 private key, PKCS8, base64.
      PASS_SIGNING_KEY: bindings.secret(),
      SESSIONS: bindings.durableObject({ worker: "empo-api", exportName: "PatreonSession" }),
      MEMBERS: bindings.durableObject({ worker: "empo-api", exportName: "PatreonMember" }),
    },
    exports: {
      PatreonSession: exports.durableObject({ storage: "sqlite" }),
      PatreonMember: exports.durableObject({ storage: "sqlite" }),
    },
  },
});
