// Builds the Lustre SPA with Bun (no Erlang required) and writes index.html.

import {
  copyFileSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const dist = join(root, "dist");
const assets = join(root, "assets");

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const build = spawnSync(
  "bun",
  ["build", "src/app_entry.mjs", "--outdir", "dist", "--minify", "--target", "browser"],
  { cwd: root, stdio: "inherit" },
);
if (build.status !== 0) {
  process.exit(build.status ?? 1);
}

const bundlePath = join(dist, "app_entry.js");
const bundle = readFileSync(bundlePath);
const hash = createHash("sha256").update(bundle).digest("hex").slice(0, 10);
const scriptName = `app_entry.${hash}.js`;
renameSync(bundlePath, join(dist, scriptName));

function copyDirectory(source, target) {
  for (const entry of readdirSync(source)) {
    const from = join(source, entry);
    const to = join(target, entry);
    if (statSync(from).isDirectory()) {
      mkdirSync(to, { recursive: true });
      copyDirectory(from, to);
    } else {
      copyFileSync(from, to);
    }
  }
}
copyDirectory(assets, dist);
copyFileSync(
  join(root, "node_modules", "pdfjs-dist", "build", "pdf.worker.min.mjs"),
  join(dist, "pdf.worker.min.mjs"),
);

const html = `<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta
      name="description"
      content="印刷楽譜をアップロードして、和声表と日本語の分析を得る friends-only ツール。"
    />
    <title>Harmony</title>
    <link rel="stylesheet" href="/styles.css" />
    <script type="module" src="/${scriptName}"></script>
  </head>
  <body>
    <div id="app"></div>
    <noscript>このアプリには JavaScript が必要です。</noscript>
  </body>
</html>
`;

writeFileSync(join(dist, "index.html"), html);
console.log("wrote dist/index.html");
