//// HTTP API for the harmony analysis Worker.

import auth
import db
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm
import shared
import worker_ffi

const default_monthly_limit = 10

const max_image_chars = 8_000_000

const max_total_image_chars = 8_000_000

const max_locate_image_chars = 4_000_000

const max_total_text = 200_000

const max_parts_per_request = 12

const max_targets = 20

pub fn handle(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
  _context: worker_ffi.Context,
) -> Promise(Dynamic) {
  let method = worker_ffi.request_method(request)
  let path = worker_ffi.request_path(request)

  case method, path {
    "GET", "/api/health" ->
      promise.resolve(json_response(
        200,
        json.object([
          #("ok", json.bool(True)),
          #("version", json.string("2026-11-10.4")),
        ]),
      ))

    "GET", "/api/quota" ->
      with_auth(request, env, fn(email) { handle_quota(env, email) })

    "POST", "/api/locate" ->
      with_auth(request, env, fn(_email) { handle_locate(request, env) })

    "POST", "/api/transcribe" ->
      with_auth(request, env, fn(_email) { handle_transcribe(request, env) })

    "POST", "/api/finalize" ->
      with_auth(request, env, fn(_email) { handle_finalize(request, env) })

    _, "/api/health" -> promise.resolve(error_response(405, "許可されていないメソッドです"))

    _, "/api/quota" -> promise.resolve(error_response(405, "許可されていないメソッドです"))

    _, "/api/locate" -> promise.resolve(error_response(405, "許可されていないメソッドです"))

    _, "/api/transcribe" ->
      promise.resolve(error_response(405, "許可されていないメソッドです"))

    _, "/api/finalize" -> promise.resolve(error_response(405, "許可されていないメソッドです"))

    _, _ -> promise.resolve(error_response(404, "API が見つかりません"))
  }
}

fn with_auth(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
  next: fn(String) -> Promise(Dynamic),
) -> Promise(Dynamic) {
  auth.authenticate(request, env)
  |> promise.await(fn(result) {
    case result {
      Ok(email) -> next(email)
      Error(message) -> promise.resolve(error_response(401, message))
    }
  })
}

// QUOTA -----------------------------------------------------------------------

fn handle_quota(env: worker_ffi.Env, email: String) -> Promise(Dynamic) {
  case database(env) {
    Error(message) -> promise.resolve(error_response(500, message))
    Ok(database) -> {
      let limit = monthly_limit(env)

      db.get_quota(database, email, limit)
      |> promise.map(fn(result) {
        case result {
          Ok(quota) ->
            json_response(
              200,
              json.object([
                #("email", json.string(quota.email)),
                #("limit", json.int(quota.limit)),
                #("used", json.int(quota.used)),
                #("remaining", json.int(quota.remaining)),
                #("month", json.string(quota.month)),
              ]),
            )
          Error(message) -> error_response(500, message)
        }
      })
    }
  }
}

// LOCATE ----------------------------------------------------------------------

type LocateBody {
  LocateBody(
    doc_id: String,
    page: Int,
    image: String,
    targets: List(String),
    system_count: Int,
  )
}

fn locate_body_decoder() -> decode.Decoder(LocateBody) {
  use doc_id <- decode.field("doc_id", decode.string)
  use page <- decode.field("page", decode.int)
  use image <- decode.field("image", decode.string)
  use targets <- decode.field("targets", decode.list(decode.string))
  use system_count <- decode.field("system_count", decode.int)
  decode.success(LocateBody(doc_id:, page:, image:, targets:, system_count:))
}

type ValidLocate {
  ValidLocate(
    doc_id: String,
    page: Int,
    image: String,
    targets: List(String),
    system_count: Int,
  )
}

fn handle_locate(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
) -> Promise(Dynamic) {
  read_json(request, locate_body_decoder())
  |> promise.await(fn(result) {
    case result {
      Error(message) -> promise.resolve(error_response(400, message))
      Ok(body) ->
        case validate_locate(body) {
          Error(message) -> promise.resolve(error_response(400, message))
          Ok(valid) -> run_locate(env, valid)
        }
    }
  })
}

fn run_locate(env: worker_ffi.Env, valid: ValidLocate) -> Promise(Dynamic) {
  llm.locate(
    env,
    valid.doc_id,
    valid.page,
    valid.targets,
    valid.system_count,
    valid.image,
  )
  |> promise.map(fn(result) {
    case result {
      Error(message) -> error_response(502, message)
      Ok(raw) ->
        case shared.parse_locate_result(raw) {
          Error(message) -> error_response(502, message)
          Ok(located) ->
            json_response(
              200,
              shared.locate_result_to_json(normalize_locate(
                valid.targets,
                valid.system_count,
                located,
              )),
            )
        }
    }
  })
}

fn normalize_locate(
  requested: List(String),
  system_count: Int,
  located: shared.LocateResult,
) -> shared.LocateResult {
  let found =
    located.found
    |> list.filter_map(fn(item) {
      case normalize_number(item.number) {
        Some(number) ->
          case list.contains(requested, number) {
            True -> {
              let pairs = case
                list.length(item.systems) == list.length(item.bars)
              {
                True -> list.zip(item.systems, item.bars)
                False -> list.map(item.systems, fn(system) { #(system, 0) })
              }
              let pairs =
                pairs
                |> list.filter(fn(pair) {
                  pair.0 >= 1 && pair.0 <= system_count
                })
                |> list.sort(fn(a, b) { int.compare(a.0, b.0) })

              let systems = list.map(pairs, fn(pair) { pair.0 })
              let bars = list.map(pairs, fn(pair) { pair.1 })

              case systems {
                [] -> Error(Nil)
                _ -> Ok(shared.FoundTarget(number:, systems:, bars:))
              }
            }
            False -> Error(Nil)
          }
        None -> Error(Nil)
      }
    })
    |> list.unique

  let missing =
    requested
    |> list.filter(fn(number) {
      !list.any(found, fn(item) { item.number == number })
    })

  shared.LocateResult(found:, missing:)
}

fn validate_locate(body: LocateBody) -> Result(ValidLocate, String) {
  use _ <- result.try(validate_doc_id(body.doc_id))
  use _ <- result.try(validate_page(body.page))
  use _ <- result.try(case string.starts_with(body.image, "data:image/") {
    True -> Ok(Nil)
    False -> Error("ページ画像の形式が不正です")
  })
  use _ <- result.try(case string.length(body.image) <= max_locate_image_chars {
    True -> Ok(Nil)
    False -> Error("ページ画像が大きすぎます")
  })
  use _ <- result.try(case body.system_count >= 1 && body.system_count <= 80 {
    True -> Ok(Nil)
    False -> Error("段数が不正です")
  })
  let targets =
    body.targets
    |> list.filter_map(fn(value) {
      case normalize_number(value) {
        Some(number) -> Ok(number)
        None -> Error(Nil)
      }
    })
    |> list.unique

  use _ <- result.try({
    let count = list.length(targets)
    case count == 0 {
      True -> Error("分析する曲番号を入力してください")
      False ->
        case count > max_targets {
          True -> Error("曲番号が多すぎます")
          False -> Ok(Nil)
        }
    }
  })

  Ok(ValidLocate(
    doc_id: body.doc_id,
    page: body.page,
    image: body.image,
    targets:,
    system_count: body.system_count,
  ))
}

// TRANSCRIBE ------------------------------------------------------------------

type TranscribePart {
  TranscribePart(label: String, data_url: String)
}

type TranscribeBody {
  TranscribeBody(
    doc_id: String,
    page: Int,
    number: String,
    parts: List(TranscribePart),
  )
}

fn transcribe_part_decoder() -> decode.Decoder(TranscribePart) {
  use label <- decode.optional_field("label", "", decode.string)
  use data_url <- decode.field("data_url", decode.string)
  decode.success(TranscribePart(label:, data_url:))
}

fn transcribe_body_decoder() -> decode.Decoder(TranscribeBody) {
  use doc_id <- decode.field("doc_id", decode.string)
  use page <- decode.field("page", decode.int)
  use number <- decode.field("number", decode.string)
  use parts <- decode.field("parts", decode.list(transcribe_part_decoder()))
  decode.success(TranscribeBody(doc_id:, page:, number:, parts:))
}

type ValidTranscribe {
  ValidTranscribe(
    doc_id: String,
    page: Int,
    number: String,
    parts: List(#(String, String)),
  )
}

fn handle_transcribe(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
) -> Promise(Dynamic) {
  read_json(request, transcribe_body_decoder())
  |> promise.await(fn(result) {
    case result {
      Error(message) -> promise.resolve(error_response(400, message))
      Ok(body) ->
        case validate_transcribe(body) {
          Error(message) -> promise.resolve(error_response(400, message))
          Ok(valid) -> run_transcribe(env, valid)
        }
    }
  })
}

fn run_transcribe(
  env: worker_ffi.Env,
  valid: ValidTranscribe,
) -> Promise(Dynamic) {
  let total = list.length(valid.parts)

  let labelled_promises =
    valid.parts
    |> list.index_map(fn(part, index) {
      let #(label, data_url) = part
      #(
        label,
        llm.transcribe(
          env,
          valid.doc_id,
          valid.page,
          valid.number,
          label,
          index + 1,
          total,
          data_url,
        ),
      )
    })

  labelled_promises
  |> list.map(fn(pair) { pair.1 })
  |> promise.await_list
  |> promise.map(fn(results) {
    list.zip(labelled_promises, results)
    |> list.map(fn(pair) {
      let #(#(label, _promise), result) = pair
      case result {
        Ok(text) -> Ok("【" <> label <> "】\n" <> text)
        Error(message) -> Error(message)
      }
    })
    |> list.fold(Ok(""), fn(accumulated, item) {
      case accumulated, item {
        Ok(text), Ok(section) ->
          Ok(case text {
            "" -> section
            _ -> text <> "\n\n" <> section
          })
        Error(message), _ -> Error(message)
        _, Error(message) -> Error(message)
      }
    })
  })
  |> promise.await(fn(result) {
    case result {
      Error(message) -> promise.resolve(error_response(502, message))
      Ok(text) -> {
        let body =
          json.object([
            #("page", json.int(valid.page)),
            #("number", json.string(valid.number)),
            #("text", json.string(text)),
          ])

        case database(env) {
          Error(_) -> promise.resolve(json_response(200, body))
          Ok(database) ->
            db.save_transcription(
              database,
              valid.doc_id,
              valid.page,
              valid.number,
              text,
            )
            |> promise.map(fn(saved) {
              case saved {
                Error(message) -> {
                  worker_ffi.log_error("transcription save failed: " <> message)
                  json_response(200, body)
                }
                Ok(_) -> json_response(200, body)
              }
            })
        }
      }
    }
  })
}

fn validate_transcribe(
  body: TranscribeBody,
) -> Result(ValidTranscribe, String) {
  use _ <- result.try(validate_doc_id(body.doc_id))
  use _ <- result.try(validate_page(body.page))
  use number <- result.try(case normalize_number(body.number) {
    Some(number) -> Ok(number)
    None -> Error("曲番号が不正です")
  })
  use _ <- result.try({
    let count = list.length(body.parts)
    case count == 0 {
      True -> Error("画像パーツがありません")
      False ->
        case count > max_parts_per_request {
          True -> Error("画像パーツが多すぎます")
          False -> Ok(Nil)
        }
    }
  })
  use parts <- result.try(
    body.parts
    |> list.try_map(fn(part) {
      use _ <- result.try(validate_part(part))
      Ok(part)
    }),
  )
  use _ <- result.try({
    let total =
      list.fold(body.parts, 0, fn(total, part) {
        total + string.length(part.data_url)
      })
    case total <= max_total_image_chars {
      True -> Ok(Nil)
      False -> Error("画像が大きすぎます。ページ数を減らしてください")
    }
  })

  Ok(ValidTranscribe(
    doc_id: body.doc_id,
    page: body.page,
    number:,
    parts: list.index_map(parts, fn(part, index) {
      let label = case string.trim(part.label) {
        "" -> "部分" <> int.to_string(index + 1)
        label -> label
      }
      #(label, part.data_url)
    }),
  ))
}

fn validate_part(part: TranscribePart) -> Result(Nil, String) {
  use _ <- result.try(case string.length(part.label) <= 50 {
    True -> Ok(Nil)
    False -> Error("パーツ名が長すぎます")
  })
  use _ <- result.try(case string.starts_with(part.data_url, "data:image/") {
    True -> Ok(Nil)
    False -> Error("画像データの形式が不正です")
  })
  case string.length(part.data_url) <= max_image_chars {
    True -> Ok(Nil)
    False -> Error("画像が大きすぎます。ページ数を減らしてください")
  }
}

// FINALIZE --------------------------------------------------------------------

type FinalizeBody {
  FinalizeBody(doc_id: String, number: String, text: String)
}

fn finalize_body_decoder() -> decode.Decoder(FinalizeBody) {
  use doc_id <- decode.field("doc_id", decode.string)
  use number <- decode.field("number", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(FinalizeBody(doc_id:, number:, text:))
}

type ValidFinalize {
  ValidFinalize(doc_id: String, number: String, text: String)
}

fn handle_finalize(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
) -> Promise(Dynamic) {
  read_json(request, finalize_body_decoder())
  |> promise.await(fn(result) {
    case result {
      Error(message) -> promise.resolve(error_response(400, message))
      Ok(body) ->
        case validate_finalize(body) {
          Error(message) -> promise.resolve(error_response(400, message))
          Ok(valid) -> run_finalize(env, valid)
        }
    }
  })
}

fn run_finalize(env: worker_ffi.Env, valid: ValidFinalize) -> Promise(Dynamic) {
  case database(env) {
    Error(message) -> promise.resolve(error_response(500, message))
    Ok(database) -> {
      let limit = monthly_limit(env)

      db.reserve_usage(database, limit)
      |> promise.await(fn(result) {
        case result {
          Error(message) -> promise.resolve(error_response(500, message))
          Ok(reservation) ->
            case reservation.reserved {
              False ->
                promise.resolve(error_response(
                  429,
                  "今月の分析回数上限（"
                    <> int.to_string(limit)
                    <> "回）に達しました。来月またお試しください。",
                ))
              True ->
                llm.analyze(env, valid.doc_id, valid.number, valid.text)
                |> promise.await(fn(analysis_result) {
                  case analysis_result {
                    Error(message) ->
                      release_then(database, reservation.month, 502, message)
                    Ok(raw) ->
                      case shared.parse_analysis(raw) {
                        Error(message) ->
                          release_then(
                            database,
                            reservation.month,
                            502,
                            message,
                          )
                        Ok(analysis) ->
                          promise.resolve(json_response(
                            200,
                            shared.analysis_to_json(analysis),
                          ))
                      }
                  }
                })
            }
        }
      })
    }
  }
}

fn validate_finalize(body: FinalizeBody) -> Result(ValidFinalize, String) {
  use _ <- result.try(validate_doc_id(body.doc_id))
  use number <- result.try(case normalize_number(body.number) {
    Some(number) -> Ok(number)
    None -> Error("曲番号が不正です")
  })
  use _ <- result.try(case string.length(string.trim(body.text)) {
    0 -> Error("書き起こしが空です")
    _ -> Ok(Nil)
  })
  use _ <- result.try(case string.length(body.text) <= max_total_text {
    True -> Ok(Nil)
    False -> Error("書き起こしが長すぎます")
  })

  Ok(ValidFinalize(doc_id: body.doc_id, number:, text: body.text))
}

fn release_then(
  database: db.Database,
  month: String,
  status: Int,
  message: String,
) -> Promise(Dynamic) {
  db.release_usage(database, month)
  |> promise.map(fn(released) {
    case released {
      Error(release_message) ->
        worker_ffi.log_error("quota release failed: " <> release_message)
      Ok(_) -> Nil
    }
    error_response(status, message)
  })
}

// HELPERS ---------------------------------------------------------------------

fn monthly_limit(env: worker_ffi.Env) -> Int {
  worker_ffi.env_get(env, "MONTHLY_LIMIT")
  |> int.parse
  |> result.unwrap(default_monthly_limit)
}

fn database(env: worker_ffi.Env) -> Result(db.Database, String) {
  case worker_ffi.has_binding(env, "DB") {
    True -> Ok(db.as_database(worker_ffi.env_binding(env, "DB")))
    False -> Error("D1 データベースが設定されていません")
  }
}

fn validate_doc_id(doc_id: String) -> Result(Nil, String) {
  let length = string.length(doc_id)
  case length >= 8 && length <= 100 {
    True -> Ok(Nil)
    False -> Error("doc_id が不正です")
  }
}

fn validate_page(page: Int) -> Result(Nil, String) {
  case page >= 1 && page <= 2000 {
    True -> Ok(Nil)
    False -> Error("ページ番号が不正です")
  }
}

fn normalize_number(value: String) -> Option(String) {
  let cleaned =
    value
    |> string.trim
    |> string.replace("No.", "")
    |> string.replace("no.", "")
    |> string.replace("#", "")
    |> string.trim

  case int.parse(cleaned) {
    Ok(number) if number > 0 -> Some(int.to_string(number))
    _ -> None
  }
}

fn read_json(
  request: worker_ffi.Request,
  decoder: decode.Decoder(a),
) -> Promise(Result(a, String)) {
  worker_ffi.request_text(request)
  |> promise.map(fn(result) {
    case result {
      Error(_) -> Error("リクエストを読めませんでした")
      Ok(raw) ->
        case string.length(raw) > 9_000_000 {
          True -> Error("リクエストが大きすぎます")
          False ->
            case json.parse(raw, decoder) {
              Ok(value) -> Ok(value)
              Error(_) -> Error("リクエストの形式が不正です")
            }
        }
    }
  })
}

fn json_response(status: Int, body: json.Json) -> Dynamic {
  worker_ffi.json_response(status, json.to_string(body))
}

fn error_response(status: Int, message: String) -> Dynamic {
  json_response(status, json.object([#("error", json.string(message))]))
}
