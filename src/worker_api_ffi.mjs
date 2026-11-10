// Thin JavaScript glue for the Cloudflare Worker runtime.
// Everything else (routing, validation, prompts, quotas) lives in Gleam.

import { Result$Ok as Ok, Result$Error as GleamError } from "./gleam.mjs";

export function request_path(request) {
  try {
    return new URL(request.url).pathname;
  } catch (_) {
    return "/";
  }
}

export function request_method(request) {
  return request.method;
}

export function request_header(request, name) {
  const value = request.headers.get(name);
  return value === null ? "" : value;
}

export async function request_text(request) {
  try {
    return Ok(await request.text());
  } catch (error) {
    return GleamError(String(error));
  }
}

export function env_get(env, name) {
  const value = env?.[name];
  return value === undefined || value === null ? "" : String(value);
}

export function env_binding(env, name) {
  return env?.[name] ?? null;
}

export function has_binding(env, name) {
  return Boolean(env && env[name]);
}

export function json_response(status, body) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export function now_ms() {
  return Date.now();
}

export function jst_month() {
  // Japan has no daylight saving time, so a fixed +09:00 offset is exact.
  return new Date(Date.now() + 9 * 60 * 60 * 1000).toISOString().slice(0, 7);
}

export function random_id() {
  return crypto.randomUUID();
}

export function log_error(message) {
  console.error(message);
}

export function wait_until(context, promise) {
  try {
    context?.waitUntil?.(promise);
  } catch (_) {
    // ignore
  }
}
