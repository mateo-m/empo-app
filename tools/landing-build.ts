import tailwind from "bun-plugin-tailwind";

const result = await Bun.build({
  entrypoints: ["landing/index.html"],
  outdir: "landing/dist",
  minify: true,
  plugins: [tailwind],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
