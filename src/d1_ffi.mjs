// D1 access. Every function returns a JSON string inside a Gleam Result.

import { Result$Ok as Ok, Result$Error as GleamError } from "./gleam.mjs";

function failure(error) {
  const message =
    error && error.message ? error.message : String(error ?? "unknown error");
  return GleamError(message);
}

function ok(value) {
  return Ok(JSON.stringify(value));
}

export function as_database(value) {
  return value;
}

export async function get_usage(db, month, limit) {
  try {
    const row = await db
      .prepare("SELECT used FROM usage_month WHERE month = ?1")
      .bind(month)
      .first();
    const used = row && Number.isFinite(row.used) ? row.used : 0;
    return ok({
      month,
      used,
      limit,
      remaining: Math.max(0, limit - used),
    });
  } catch (error) {
    return failure(error);
  }
}

export async function reserve_usage(db, month, limit) {
  try {
    const statement = db
      .prepare(
        `INSERT INTO usage_month (month, used, updated_at)
         VALUES (?1, 1, CURRENT_TIMESTAMP)
         ON CONFLICT(month) DO UPDATE SET
           used = usage_month.used + 1,
           updated_at = CURRENT_TIMESTAMP
         WHERE usage_month.used < ?2`,
      )
      .bind(month, limit);

    const result = await statement.run();
    const changes = result?.meta?.changes ?? 0;
    if (changes < 1) {
      return ok({ reserved: false, used: limit, remaining: 0, month, limit });
    }

    const row = await db
      .prepare("SELECT used FROM usage_month WHERE month = ?1")
      .bind(month)
      .first();
    const used = row && Number.isFinite(row.used) ? row.used : 1;
    return ok({
      reserved: true,
      used,
      remaining: Math.max(0, limit - used),
      month,
      limit,
    });
  } catch (error) {
    return failure(error);
  }
}

export async function release_usage(db, month) {
  try {
    await db
      .prepare(
        `UPDATE usage_month
         SET used = MAX(used - 1, 0), updated_at = CURRENT_TIMESTAMP
         WHERE month = ?1`,
      )
      .bind(month)
      .run();
    return ok({ released: true });
  } catch (error) {
    return failure(error);
  }
}

export async function save_transcription(db, docId, page, piece, text) {
  try {
    await db
      .prepare(
        `INSERT INTO transcriptions (doc_id, page, piece, text, created_at)
         VALUES (?1, ?2, ?3, ?4, CURRENT_TIMESTAMP)
         ON CONFLICT(doc_id, page, piece) DO UPDATE SET
           text = excluded.text,
           created_at = CURRENT_TIMESTAMP`,
      )
      .bind(docId, page, piece, text)
      .run();
    return ok({ saved: true });
  } catch (error) {
    return failure(error);
  }
}
