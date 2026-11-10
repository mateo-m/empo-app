import { aot } from "elysia/plugin/aot/bun";

const result = await Bun.build({
  entrypoints: ["src/worker.ts"],
  outdir: "dist",
  target: "browser",
  // Workers provide the node: modules with the nodejs_compat flag.
  external: ["node:*"],
  plugins: [aot("src/worker.ts", { target: "workerd" })],
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
process.exit(0);
