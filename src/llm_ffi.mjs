// DeepSeek HTTP client glue.

import { Result$Ok as Ok, Result$Error as GleamError } from "./gleam.mjs";

function failure(error) {
  const message =
    error && error.message ? error.message : String(error ?? "unknown error");
  return GleamError(message);
}

export async function chat_completion(apiKey, baseUrl, bodyJson, sessionId) {
  try {
    const base = (baseUrl || "https://opencode.ai/inference/go/openai/v1").replace(/\/+$/, "");
    const headers = {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
      "user-agent": "harmony-lens/1.0",
    };
    if (sessionId) {
      headers["x-opencode-session"] = sessionId;
    }
    const response = await fetch(`${base}/chat/completions`, {
      method: "POST",
      headers,
      body: bodyJson,
    });

    const body = await response.text();
    return Ok(JSON.stringify({ status: response.status, body }));
  } catch (error) {
    return failure(error);
  }
}
