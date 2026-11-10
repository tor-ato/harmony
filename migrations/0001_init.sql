-- Harmony analysis service: monthly quota and transcription archive.

CREATE TABLE IF NOT EXISTS usage_month (
  month TEXT PRIMARY KEY,
  used INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transcriptions (
  doc_id TEXT NOT NULL,
  page INTEGER NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (doc_id, page)
);

CREATE INDEX IF NOT EXISTS transcriptions_doc_id_idx
  ON transcriptions (doc_id);
