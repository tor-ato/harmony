// Local end-to-end smoke test (mock LLM + local D1).
// Usage: node scripts/e2e.mjs [pdf-path]

import { chromium } from "playwright";
import { readdirSync } from "node:fs";
import { join } from "node:path";

const defaultPdf = (() => {
  const dir = "/home/torato/analyse";
  const match = readdirSync(dir).find((name) => name.toLowerCase().endsWith(".pdf"));
  return match ? join(dir, match) : "";
})();

const pdfPath = process.argv[2] ?? defaultPdf;
const base = process.env.BASE_URL ?? "http://127.0.0.1:8787";

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
page.on("console", (message) => {
  if (message.type() === "error") errors.push(`console: ${message.text()}`);
});

try {
  await page.goto(base, { waitUntil: "networkidle" });
  await page.setInputFiles("#pdf-input", pdfPath);
  await page.waitForSelector(".page-tile", { timeout: 180_000 });
  const pageCount = await page.locator(".page-tile").count();
  console.log(`pages: ${pageCount}`);

  await page.getByRole("button", { name: "選択解除" }).click();
  await page.locator(".page-tile").nth(2).click();
  await page.fill("#targets", "32,33");
  await page.getByRole("button", { name: "対象曲を探す" }).click();

  await page.waitForSelector(".target-row", { timeout: 120_000 });
  const targets = await page.locator(".target-row").count();
  console.log(`located targets: ${targets}`);

  await page.getByRole("button", { name: "書き起こしを開始" }).click();
  await page.waitForSelector(".harmony-table tbody tr", { timeout: 300_000 });
  const results = await page.locator(".target-result").count();
  const rows = await page.locator(".harmony-table tbody tr").count();
  const prose = await page.locator(".prose").first().innerText();
  console.log(`result sections: ${results}, table rows: ${rows}, prose chars: ${prose.length}`);

  await page.screenshot({ path: "/tmp/opencode/app-result.png", fullPage: true });
  console.log("screenshot: /tmp/opencode/app-result.png");

  if (errors.length > 0) {
    console.log("browser errors:");
    for (const error of errors) console.log(`  ${error}`);
    process.exitCode = 1;
  } else {
    console.log("no browser errors");
  }
} finally {
  await browser.close();
}
