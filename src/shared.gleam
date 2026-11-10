//// Types and JSON decoders shared by the Worker API and the Lustre client.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type Quota {
  Quota(email: String, limit: Int, used: Int, remaining: Int, month: String)
}

pub type PageText {
  PageText(text: String)
}

pub type Row {
  Row(
    bar: String,
    beat: String,
    chord: String,
    function: String,
    notes: String,
    comment: String,
  )
}

pub type Meta {
  Meta(key: String, meter: String, form: String, confidence: String, mock: Bool)
}

pub type Analysis {
  Analysis(table: List(Row), prose: String, meta: Meta)
}

pub type Thumb {
  Thumb(page: Int, data_url: String)
}

pub type PdfInfo {
  PdfInfo(doc_id: String, name: String, page_count: Int, thumbs: List(Thumb))
}

pub type FoundTarget {
  FoundTarget(number: String, systems: List(Int), bars: List(Int))
}

pub type LocateResult {
  LocateResult(found: List(FoundTarget), missing: List(String))
}

pub type Overview {
  Overview(data_url: String, system_count: Int)
}

pub type RenderResult {
  RenderResult(data_url: String)
}

pub type RenderPart {
  RenderPart(label: String, data_url: String)
}

pub type RenderParts {
  RenderParts(parts: List(RenderPart))
}

pub type ApiResponse {
  ApiResponse(ok: Bool, status: Int, body: String, error: String)
}

// QUOTA -----------------------------------------------------------------------

pub fn quota_decoder() -> decode.Decoder(Quota) {
  use email <- decode.field("email", decode.string)
  use limit <- decode.field("limit", decode.int)
  use used <- decode.field("used", decode.int)
  use remaining <- decode.field("remaining", decode.int)
  use month <- decode.field("month", decode.string)
  decode.success(Quota(email:, limit:, used:, remaining:, month:))
}

pub fn page_text_decoder() -> decode.Decoder(PageText) {
  use text <- decode.field("text", decode.string)
  decode.success(PageText(text:))
}

// ANALYSIS --------------------------------------------------------------------

fn row_decoder() -> decode.Decoder(Row) {
  use bar <- decode.optional_field("bar", "", decode.string)
  use beat <- decode.optional_field("beat", "", decode.string)
  use chord <- decode.optional_field("chord", "", decode.string)
  use function <- decode.optional_field("function", "", decode.string)
  use notes <- decode.optional_field("notes", "", decode.string)
  use comment <- decode.optional_field("comment", "", decode.string)
  decode.success(Row(bar:, beat:, chord:, function:, notes:, comment:))
}

fn meta_decoder() -> decode.Decoder(Meta) {
  use key <- decode.optional_field("key", "", decode.string)
  use meter <- decode.optional_field("meter", "", decode.string)
  use form <- decode.optional_field("form", "", decode.string)
  use confidence <- decode.optional_field("confidence", "", decode.string)
  use mock <- decode.optional_field("mock", False, decode.bool)
  decode.success(Meta(key:, meter:, form:, confidence:, mock:))
}

pub fn analysis_decoder() -> decode.Decoder(Analysis) {
  use table <- decode.optional_field("table", [], decode.list(row_decoder()))
  use prose <- decode.optional_field("prose", "", decode.string)
  use meta <- decode.optional_field(
    "meta",
    Meta(key: "", meter: "", form: "", confidence: "", mock: False),
    meta_decoder(),
  )
  decode.success(Analysis(table:, prose:, meta:))
}

pub fn parse_analysis(text: String) -> Result(Analysis, String) {
  json.parse(strip_code_fence(text), analysis_decoder())
  |> result_map_error("解析結果のJSONを読めませんでした")
}

// PDF -------------------------------------------------------------------------

fn thumb_decoder() -> decode.Decoder(Thumb) {
  use page <- decode.field("page", decode.int)
  use data_url <- decode.field("data_url", decode.string)
  decode.success(Thumb(page:, data_url:))
}

fn flexible_string_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.map(decode.int, fn(value) { int.to_string(value) }),
  ])
}

fn flexible_int_decoder() -> decode.Decoder(Int) {
  decode.one_of(decode.int, [
    decode.map(decode.string, fn(value) {
      case int.parse(value) {
        Ok(number) -> number
        Error(_) -> 0
      }
    }),
  ])
}

fn found_target_decoder() -> decode.Decoder(FoundTarget) {
  use number <- decode.field("number", flexible_string_decoder())
  use systems <- decode.optional_field(
    "systems",
    [],
    decode.list(flexible_int_decoder()),
  )
  use bars <- decode.optional_field(
    "bars",
    [],
    decode.list(flexible_int_decoder()),
  )
  decode.success(FoundTarget(number:, systems:, bars:))
}

pub fn locate_result_decoder() -> decode.Decoder(LocateResult) {
  use found <- decode.optional_field(
    "found",
    [],
    decode.list(found_target_decoder()),
  )
  use missing <- decode.optional_field(
    "missing",
    [],
    decode.list(decode.string),
  )
  decode.success(LocateResult(found:, missing:))
}

pub fn parse_locate_result(text: String) -> Result(LocateResult, String) {
  json.parse(strip_code_fence(text), locate_result_decoder())
  |> result_map_error("ロケート結果を読めませんでした")
}

pub fn locate_result_to_json(result: LocateResult) -> json.Json {
  json.object([
    #(
      "found",
      json.array(result.found, fn(found) {
        json.object([
          #("number", json.string(found.number)),
          #("systems", json.array(found.systems, json.int)),
        ])
      }),
    ),
    #("missing", json.array(result.missing, json.string)),
  ])
}

pub fn pdf_info_decoder() -> decode.Decoder(PdfInfo) {
  use doc_id <- decode.field("doc_id", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use page_count <- decode.field("page_count", decode.int)
  use thumbs <- decode.field("thumbs", decode.list(thumb_decoder()))
  decode.success(PdfInfo(doc_id:, name:, page_count:, thumbs:))
}

pub fn overview_decoder() -> decode.Decoder(Overview) {
  use data_url <- decode.field("data_url", decode.string)
  use system_count <- decode.field("system_count", decode.int)
  decode.success(Overview(data_url:, system_count:))
}

pub fn render_result_decoder() -> decode.Decoder(RenderResult) {
  use data_url <- decode.field("data_url", decode.string)
  decode.success(RenderResult(data_url:))
}

fn render_part_decoder() -> decode.Decoder(RenderPart) {
  use label <- decode.optional_field("label", "", decode.string)
  use data_url <- decode.field("data_url", decode.string)
  decode.success(RenderPart(label:, data_url:))
}

pub fn render_parts_decoder() -> decode.Decoder(RenderParts) {
  use parts <- decode.field("parts", decode.list(render_part_decoder()))
  decode.success(RenderParts(parts:))
}

// ENVELOPES -------------------------------------------------------------------

pub fn api_response_decoder() -> decode.Decoder(ApiResponse) {
  use ok <- decode.field("ok", decode.bool)
  use status <- decode.field("status", decode.int)
  use body <- decode.optional_field("body", "", decode.string)
  use error <- decode.optional_field("error", "", decode.string)
  decode.success(ApiResponse(ok:, status:, body:, error:))
}

pub fn parse_api_response(text: String) -> Result(ApiResponse, String) {
  json.parse(text, api_response_decoder())
  |> result_map_error("APIレスポンスを読めませんでした")
}

// HELPERS ---------------------------------------------------------------------

pub fn strip_code_fence(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    True -> {
      let lines = string.split(trimmed, "\n")
      let without_first = list.drop(lines, 1)
      let without_last = case list.reverse(without_first) {
        [last, ..rest] ->
          case string.starts_with(string.trim(last), "```") {
            True -> list.reverse(rest)
            False -> without_first
          }
        [] -> []
      }
      string.join(without_last, "\n") |> string.trim
    }
    False -> trimmed
  }
}

pub fn row_to_json(row: Row) -> json.Json {
  json.object([
    #("bar", json.string(row.bar)),
    #("beat", json.string(row.beat)),
    #("chord", json.string(row.chord)),
    #("function", json.string(row.function)),
    #("notes", json.string(row.notes)),
    #("comment", json.string(row.comment)),
  ])
}

pub fn analysis_to_json(analysis: Analysis) -> json.Json {
  json.object([
    #("table", json.array(analysis.table, row_to_json)),
    #("prose", json.string(analysis.prose)),
    #(
      "meta",
      json.object([
        #("key", json.string(analysis.meta.key)),
        #("meter", json.string(analysis.meta.meter)),
        #("form", json.string(analysis.meta.form)),
        #("confidence", json.string(analysis.meta.confidence)),
        #("mock", json.bool(analysis.meta.mock)),
      ]),
    ),
  ])
}

fn result_map_error(
  result: Result(a, b),
  message: String,
) -> Result(a, String) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(message)
  }
}
