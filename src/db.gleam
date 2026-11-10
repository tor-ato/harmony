//// D1-backed quota and transcription storage.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import shared
import worker_ffi

pub type Database

@external(javascript, "./d1_ffi.mjs", "get_usage")
fn ffi_get_usage(
  db: Database,
  month: String,
  limit: Int,
) -> Promise(Result(String, String))

@external(javascript, "./d1_ffi.mjs", "reserve_usage")
fn ffi_reserve_usage(
  db: Database,
  month: String,
  limit: Int,
) -> Promise(Result(String, String))

@external(javascript, "./d1_ffi.mjs", "release_usage")
fn ffi_release_usage(
  db: Database,
  month: String,
) -> Promise(Result(String, String))

@external(javascript, "./d1_ffi.mjs", "save_transcription")
fn ffi_save_transcription(
  db: Database,
  doc_id: String,
  page: Int,
  piece: String,
  text: String,
) -> Promise(Result(String, String))

@external(javascript, "./d1_ffi.mjs", "as_database")
pub fn as_database(value: Dynamic) -> Database

pub fn get_quota(
  db: Database,
  email: String,
  limit: Int,
) -> Promise(Result(shared.Quota, String)) {
  let month = worker_ffi.jst_month()

  ffi_get_usage(db, month, limit)
  |> promise.map(fn(result) {
    case result {
      Ok(body) ->
        case json.parse(body, usage_decoder()) {
          Ok(usage) ->
            Ok(shared.Quota(
              email:,
              limit:,
              used: usage.used,
              remaining: usage.remaining,
              month: usage.month,
            ))
          Error(_) -> Error("利用回数を読めませんでした")
        }
      Error(message) -> Error(message)
    }
  })
}

pub type ReserveResult {
  ReserveResult(reserved: Bool, month: String, used: Int, remaining: Int)
}

pub fn reserve_usage(
  db: Database,
  limit: Int,
) -> Promise(Result(ReserveResult, String)) {
  let month = worker_ffi.jst_month()

  ffi_reserve_usage(db, month, limit)
  |> promise.map(fn(result) {
    case result {
      Ok(body) ->
        case json.parse(body, reserve_decoder()) {
          Ok(value) ->
            Ok(ReserveResult(
              reserved: value.reserved,
              month: value.month,
              used: value.used,
              remaining: value.remaining,
            ))
          Error(_) -> Error("利用回数を更新できませんでした")
        }
      Error(message) -> Error(message)
    }
  })
}

pub fn release_usage(
  db: Database,
  month: String,
) -> Promise(Result(Nil, String)) {
  ffi_release_usage(db, month)
  |> promise.map(fn(result) {
    case result {
      Ok(_) -> Ok(Nil)
      Error(message) -> Error(message)
    }
  })
}

pub fn save_transcription(
  db: Database,
  doc_id: String,
  page: Int,
  piece: String,
  text: String,
) -> Promise(Result(Nil, String)) {
  ffi_save_transcription(db, doc_id, page, piece, text)
  |> promise.map(fn(result) {
    case result {
      Ok(_) -> Ok(Nil)
      Error(message) -> Error(message)
    }
  })
}

type Usage {
  Usage(month: String, used: Int, remaining: Int)
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use month <- decode.field("month", decode.string)
  use used <- decode.field("used", decode.int)
  use remaining <- decode.field("remaining", decode.int)
  decode.success(Usage(month:, used:, remaining:))
}

type Reserve {
  Reserve(reserved: Bool, month: String, used: Int, remaining: Int)
}

fn reserve_decoder() -> decode.Decoder(Reserve) {
  use reserved <- decode.field("reserved", decode.bool)
  use month <- decode.field("month", decode.string)
  use used <- decode.field("used", decode.int)
  use remaining <- decode.field("remaining", decode.int)
  decode.success(Reserve(reserved:, month:, used:, remaining:))
}
