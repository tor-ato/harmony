-- Allow multiple pieces to be transcribed from the same page.
-- The original table was keyed by (doc_id, page); this migration rebuilds it
-- with a piece column and preserves any existing rows.

CREATE TABLE transcriptions_v2 (
  doc_id TEXT NOT NULL,
  page INTEGER NOT NULL,
  piece TEXT NOT NULL DEFAULT '',
  text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (doc_id, page, piece)
);

INSERT INTO transcriptions_v2 (doc_id, page, piece, text, created_at)
  SELECT doc_id, page, '', text, created_at FROM transcriptions;

DROP TABLE transcriptions;

ALTER TABLE transcriptions_v2 RENAME TO transcriptions;

CREATE INDEX IF NOT EXISTS transcriptions_doc_id_idx
  ON transcriptions (doc_id);
