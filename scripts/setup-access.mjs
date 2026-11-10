// Creates the Cloudflare Access application for the deployed Worker.
// Auth: a Cloudflare API token in .cf-api-token or CF_ACCESS_API_TOKEN with
//   Account > Access: Apps and Policies: Edit
//   Account > Access: Organizations, Identity Providers, and Groups: Edit

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID ?? "f03996a847942f4992b4621701564e1f";
const host = process.env.HARMONY_HOST ?? "harmony.torato.workers.dev";
const appName = "Harmony";
const allowedEmails = (process.env.ALLOWED_EMAILS ?? "")
  .split(",")
  .map((email) => email.trim())
  .filter(Boolean);
if (allowedEmails.length === 0) {
  console.error(
    "ALLOWED_EMAILS に許可するメールアドレスをカンマ区切りで設定してください。",
  );
  process.exit(1);
}

function readToken() {
  if (process.env.CF_ACCESS_API_TOKEN) return process.env.CF_ACCESS_API_TOKEN.trim();
  const path = join(root, ".cf-api-token");
  if (!existsSync(path)) {
    console.error(
      "API トークンがありません。.cf-api-token に保存するか CF_ACCESS_API_TOKEN を設定してください。",
    );
    process.exit(1);
  }
  return readFileSync(path, "utf8").trim();
}

const token = readToken();
const base = "https://api.cloudflare.com/client/v4";

async function api(method, path, body) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let payload = null;
  try {
    payload = JSON.parse(text);
  } catch (_) {
    payload = { success: false, errors: [{ message: text }] };
  }
  return { status: response.status, ok: response.ok, payload };
}

function explainErrors(result) {
  return (result.payload?.errors ?? [])
    .map((error) => `${error.code ?? ""} ${error.message ?? ""}`.trim())
    .join(" / ");
}

function fail(label, result) {
  console.error(`${label} に失敗しました (HTTP ${result.status}): ${explainErrors(result)}`);
  process.exit(1);
}

// 1. Organization -------------------------------------------------------------

let orgResult = await api("GET", `/accounts/${accountId}/access/organizations`);
let organization;
if (orgResult.ok && orgResult.payload.success) {
  organization = orgResult.payload.result;
  console.log("Zero Trust 組織は既に有効です。");
} else {
  console.log("Zero Trust 組織を作成します…");
  const created = await api("POST", `/accounts/${accountId}/access/organizations`, {
    name: appName,
  });
  if (!created.ok || !created.payload.success) fail("Zero Trust 組織の作成", created);
  organization = created.payload.result;
  console.log("Zero Trust 組織を作成しました。");
}

const rawDomain = organization.auth_domain;
if (!rawDomain) {
  console.error("組織の auth_domain を取得できませんでした。");
  process.exit(1);
}
const teamDomain = rawDomain.endsWith(".cloudflareaccess.com")
  ? rawDomain
  : `${rawDomain}.cloudflareaccess.com`;

// 2. One-time PIN identity provider -----------------------------------------

const idpList = await api(
  "GET",
  `/accounts/${accountId}/access/identity_providers?per_page=100`,
);
if (!idpList.ok || !idpList.payload.success) fail("ID プロバイダ一覧の取得", idpList);

let oneTimePin = (idpList.payload.result ?? []).find(
  (idp) => idp.type === "onetimepin",
);
if (!oneTimePin) {
  console.log("One-time PIN ログインを作成します…");
  const created = await api(
    "POST",
    `/accounts/${accountId}/access/identity_providers`,
    { name: "One-time PIN", type: "onetimepin", config: {} },
  );
  if (!created.ok || !created.payload.success) fail("One-time PIN の作成", created);
  oneTimePin = created.payload.result;
  console.log("One-time PIN ログインを作成しました。");
} else {
  console.log("One-time PIN ログインは既にあります。");
}

// 3. Application --------------------------------------------------------------

const apps = await api("GET", `/accounts/${accountId}/access/apps?per_page=100`);
if (!apps.ok || !apps.payload.success) fail("Access アプリ一覧の取得", apps);

const existing = (apps.payload.result ?? []).find(
  (app) =>
    app.domain === host ||
    app.name === appName ||
    (Array.isArray(app.destinations) &&
      app.destinations.some((destination) => destination.uri === host)),
);

let application = existing;
const appBody = {
  name: appName,
  domain: host,
  self_hosted_domains: [host],
  destinations: [{ type: "public", uri: host }],
  type: "self_hosted",
  session_duration: "24h",
  app_launcher_visible: false,
  auto_redirect_to_identity: true,
  allowed_idps: [oneTimePin.id],
};
if (!application) {
  console.log(`Access アプリを作成します: ${host}`);
  const created = await api("POST", `/accounts/${accountId}/access/apps`, {
    ...appBody,
    policies: [
      {
        name: "Friends beta",
        decision: "allow",
        precedence: 1,
        include: allowedEmails.map((email) => ({ email: { email } })),
      },
    ],
  });
  if (!created.ok || !created.payload.success) fail("Access アプリの作成", created);
  application = created.payload.result;
  console.log("Access アプリを作成しました。");
} else {
  console.log("既存の Access アプリのログイン方法を更新します。");
  const updated = await api(
    "PUT",
    `/accounts/${accountId}/access/apps/${application.id}`,
    appBody,
  );
  if (!updated.ok || !updated.payload.success) fail("Access アプリの更新", updated);
  application = updated.payload.result;
}

if (!application.aud) {
  console.error("Access アプリの AUD を取得できませんでした。");
  process.exit(1);
}

// 3. wrangler.jsonc -----------------------------------------------------------

const configPath = join(root, "wrangler.jsonc");
let config = readFileSync(configPath, "utf8");
config = config.replace(/"POLICY_AUD":\s*"[^"]*"/, `"POLICY_AUD": "${application.aud}"`);
config = config.replace(/"TEAM_DOMAIN":\s*"[^"]*"/, `"TEAM_DOMAIN": "${teamDomain}"`);
writeFileSync(configPath, config);

writeFileSync(
  join(root, ".access-setup.json"),
  `${JSON.stringify(
    {
      application_id: application.id,
      application_name: application.name,
      host,
      aud: application.aud,
      team_domain: teamDomain,
      allowed_emails: allowedEmails,
    },
    null,
    2,
  )}\n`,
);

console.log("");
console.log("設定を wrangler.jsonc に書き込みました。");
console.log(`  POLICY_AUD  = ${application.aud}`);
console.log(`  TEAM_DOMAIN = ${teamDomain}`);
console.log("");
console.log("次のコマンドで再デプロイしてください: npm run deploy");
console.log("（またはこのスクリプトに --deploy を付けて実行）");

if (process.argv.includes("--deploy")) {
  const { spawnSync } = await import("node:child_process");
  const result = spawnSync("npm", ["run", "deploy"], {
    cwd: root,
    stdio: "inherit",
    shell: true,
  });
  if (result.status !== 0) process.exit(result.status ?? 1);

  console.log("\nAccess の反映を待っています…");
  let location = "";
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    const check = await fetch(`https://${host}/`, { redirect: "manual" });
    location = check.headers.get("location") ?? "";
    if (location.includes("cloudflareaccess.com")) {
      console.log(`Access チェック: HTTP ${check.status} ${location}`);
      console.log("Access のログイン画面を確認しました。");
      process.exit(0);
    }
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  console.error("Access のログイン画面へリダイレクトされませんでした。");
  process.exit(1);
}
