// Deploy and explicitly promote the new version to 100%. Cloudflare's
// workers.dev route has occasionally stayed on an older version after
// `wrangler deploy` alone, so always follow up with versions deploy.
// Right after an upload, /versions/latest can still 404 for a few seconds,
// hence the retry loop.

import { spawnSync } from "node:child_process";

const run = (args, options) =>
  spawnSync("npx", args, { cwd: process.cwd(), shell: true, ...options });

const deploy = run(["wrangler", "deploy"], { encoding: "utf8" });
process.stdout.write(deploy.stdout ?? "");
process.stderr.write(deploy.stderr ?? "");
if (deploy.status !== 0) process.exit(deploy.status ?? 1);

const output = `${deploy.stdout ?? ""}\n${deploy.stderr ?? ""}`;
const match = output.match(/Current Version ID:\s*([0-9a-f-]+)/i);
if (!match) {
  console.error("デプロイ後の Version ID を取得できませんでした。");
  process.exit(1);
}
const version = match[1];
console.log(`Promoting ${version} to 100%...`);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

for (let attempt = 1; attempt <= 12; attempt += 1) {
  const promote = run(
    [
      "wrangler",
      "versions",
      "deploy",
      `${version}@100%`,
      "--yes",
      "--message",
      "promote latest",
    ],
    { encoding: "utf8" },
  );
  if (promote.status === 0) {
    process.stdout.write(promote.stdout ?? "");
    process.exit(0);
  }
  if (attempt === 12) {
    process.stdout.write(promote.stdout ?? "");
    process.stderr.write(promote.stderr ?? "");
    process.exit(promote.status ?? 1);
  }
  console.log(`Promotion not ready yet (attempt ${attempt}), retrying...`);
  await sleep(10000);
}
