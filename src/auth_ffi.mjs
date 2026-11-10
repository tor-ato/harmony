// Cloudflare Access JWT verification with WebCrypto (RS256).
// The JWKS is cached per isolate for an hour.

import { Result$Ok as Ok, Result$Error as GleamError } from "./gleam.mjs";

const CERT_TTL_MS = 60 * 60 * 1000;
let certsCache = null;
let certsFetchedAt = 0;

function failure(error) {
  const message =
    error && error.message ? error.message : String(error ?? "unknown error");
  return GleamError(message);
}

function base64urlToBytes(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJsonPart(part) {
  return JSON.parse(new TextDecoder().decode(base64urlToBytes(part)));
}

async function loadCertificates(teamDomain) {
  const now = Date.now();
  if (certsCache !== null && now - certsFetchedAt < CERT_TTL_MS) {
    return certsCache;
  }

  const url = `https://${teamDomain}/cdn-cgi/access/certs`;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Access 証明書の取得に失敗しました (${response.status})`);
  }

  const body = await response.json();
  if (!body || !Array.isArray(body.keys) || body.keys.length === 0) {
    throw new Error("Access 証明書に鍵がありません");
  }

  certsCache = body.keys;
  certsFetchedAt = now;
  return certsCache;
}

export async function verify_access_jwt(token, audience, teamDomain) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) {
      throw new Error("JWT の形式が不正です");
    }

    const [headerPart, payloadPart, signaturePart] = parts;
    const header = decodeJsonPart(headerPart);
    const payload = decodeJsonPart(payloadPart);

    if (header.alg !== "RS256") {
      throw new Error(`未対応の署名アルゴリズムです: ${header.alg}`);
    }

    const keys = await loadCertificates(teamDomain);
    const jwk =
      keys.find((key) => key.kid === header.kid) ?? (keys.length === 1 ? keys[0] : null);
    if (!jwk) {
      throw new Error("JWT に対応する Access の鍵が見つかりません");
    }

    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );

    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      base64urlToBytes(signaturePart),
      new TextEncoder().encode(`${headerPart}.${payloadPart}`),
    );
    if (!valid) {
      throw new Error("JWT の署名が正しくありません");
    }

    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.exp === "number" && payload.exp + 30 < now) {
      throw new Error("ログインの有効期限が切れています");
    }
    if (typeof payload.nbf === "number" && payload.nbf - 30 > now) {
      throw new Error("JWT はまだ有効ではありません");
    }

    if (audience !== "") {
      const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
      if (!audiences.includes(audience)) {
        throw new Error("JWT の audience が一致しません");
      }
    }

    if (typeof payload.iss === "string" && payload.iss !== `https://${teamDomain}`) {
      throw new Error("JWT の発行者が一致しません");
    }

    if (typeof payload.email !== "string" || payload.email === "") {
      throw new Error("JWT にメールアドレスがありません");
    }

    return Ok(JSON.stringify({ email: payload.email.toLowerCase() }));
  } catch (error) {
    return failure(error);
  }
}
