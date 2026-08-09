// The lightningcss library, not its CLI (lightningcss-cli): the CLI's
// node_modules/.bin/lightningcss entry is npm's Windows placeholder text
// file until the package's own postinstall script hardlinks the real
// platform binary over it, and fetchBunDeps installs with --ignore-scripts.
// This library resolves its native addon at require time instead, so no
// postinstall is needed -- the concrete case buildBunPackage's lack of
// postinstall support rules out.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { transform } from "lightningcss";

mkdirSync("dist", { recursive: true });

const { code } = transform({
  filename: "src/style.css",
  code: readFileSync("src/style.css"),
  minify: true,
});

writeFileSync("dist/style.css", code);
