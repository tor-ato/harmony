import auth
import gleam/json
import gleam/string
import gleeunit
import prompts
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn strip_code_fence_test() {
  let text = "```json\n{\"a\": 1}\n```"
  assert shared.strip_code_fence(text) == "{\"a\": 1}"
}

pub fn strip_code_fence_without_fence_test() {
  assert shared.strip_code_fence("  {\"a\": 1}  ") == "{\"a\": 1}"
}

pub fn quota_decoder_test() {
  let value =
    json.parse(
      "{\"email\":\"a@example.com\",\"limit\":10,\"used\":3,\"remaining\":7,\"month\":\"2026-11\"}",
      shared.quota_decoder(),
    )
  assert Ok(shared.Quota(
      email: "a@example.com",
      limit: 10,
      used: 3,
      remaining: 7,
      month: "2026-11",
    ))
    == value
}

pub fn api_response_decoder_test() {
  let value =
    json.parse(
      "{\"ok\":false,\"status\":429,\"body\":\"\",\"error\":\"上限です\"}",
      shared.api_response_decoder(),
    )
  assert value
    == Ok(shared.ApiResponse(ok: False, status: 429, body: "", error: "上限です"))
}

pub fn analysis_decoder_test() {
  let value =
    json.parse(
      "{\"table\":[{\"bar\":\"1\",\"beat\":\"1\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"F-A-C\",\"comment\":\"\"}],\"prose\":\"分析\",\"meta\":{\"key\":\"F\",\"meter\":\"3/4\",\"form\":\"A\",\"confidence\":\"high\",\"mock\":false}}",
      shared.analysis_decoder(),
    )

  assert Ok(shared.Analysis(
      table: [
        shared.Row(
          bar: "1",
          beat: "1",
          chord: "F",
          function: "T",
          notes: "F-A-C",
          comment: "",
        ),
      ],
      prose: "分析",
      meta: shared.Meta(
        key: "F",
        meter: "3/4",
        form: "A",
        confidence: "high",
        mock: False,
      ),
    ))
    == value
}

pub fn allowlist_test() {
  let allowed = "friend@example.com, Owner@Example.com"
  assert auth.is_allowed("friend@example.com", allowed)
  assert auth.is_allowed("OWNER@example.com", allowed)
  assert !auth.is_allowed("someone@example.com", allowed)
  assert !auth.is_allowed("friend@example.com", "")
}

pub fn prompt_includes_page_test() {
  let prompt = prompts.transcribe_prompt(4, "32", "上段・左", 1, 6)
  assert string.contains(prompt, "4 ページ目")
  assert string.contains(prompt, "上段・左")
}

pub fn analyze_prompt_includes_all_pages_test() {
  let prompt = prompts.analyze_prompt("32", "ページ1の内容\nページ2の内容")
  assert string.contains(prompt, "No.32")
  assert string.contains(prompt, "ページ1の内容")
  assert string.contains(prompt, "ページ2の内容")
}
