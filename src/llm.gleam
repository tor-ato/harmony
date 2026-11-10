//// DeepSeek chat-completions client (OpenAI-compatible).

import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/string
import prompts
import shared
import worker_ffi

const default_model = "deepseek-v4.1-flash"

const default_base_url = "https://opencode.ai/inference/go/openai/v1"

@external(javascript, "./llm_ffi.mjs", "chat_completion")
fn chat_completion(
  api_key: String,
  base_url: String,
  body: String,
  session_id: String,
) -> Promise(Result(String, String))

type HttpResult {
  HttpResult(status: Int, body: String)
}

fn http_decoder() -> decode.Decoder(HttpResult) {
  use status <- decode.field("status", decode.int)
  use body <- decode.field("body", decode.string)
  decode.success(HttpResult(status:, body:))
}

fn chat_decoder() -> decode.Decoder(String) {
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  case choices {
    [content, ..] -> decode.success(content)
    [] -> decode.failure("", "choices が空です")
  }
}

fn choice_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", message_decoder())
  decode.success(message)
}

fn message_decoder() -> decode.Decoder(String) {
  use content <- decode.field("content", decode.string)
  decode.success(content)
}

fn api_error_decoder() -> decode.Decoder(String) {
  use error <- decode.field("error", error_object_decoder())
  decode.success(error)
}

fn error_object_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

pub fn mock_enabled(env: worker_ffi.Env) -> Bool {
  worker_ffi.env_get(env, "MOCK_LLM") == "true"
}

fn model(env: worker_ffi.Env) -> String {
  case worker_ffi.env_get(env, "DEEPSEEK_MODEL") {
    "" -> default_model
    value -> value
  }
}

fn base_url(env: worker_ffi.Env) -> String {
  case worker_ffi.env_get(env, "DEEPSEEK_BASE_URL") {
    "" -> default_base_url
    value -> value
  }
}

fn transcribe_model(env: worker_ffi.Env) -> String {
  case worker_ffi.env_get(env, "TRANSCRIBE_MODEL") {
    "" -> model(env)
    value -> value
  }
}

fn transcribe_base_url(env: worker_ffi.Env) -> String {
  case worker_ffi.env_get(env, "TRANSCRIBE_BASE_URL") {
    "" -> base_url(env)
    value -> value
  }
}

fn text_message(role: String, content: String) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #("content", json.string(content)),
  ])
}

fn vision_message(prompt: String, data_url: String) -> json.Json {
  json.object([
    #("role", json.string("user")),
    #(
      "content",
      json.array(
        [
          json.object([
            #("type", json.string("text")),
            #("text", json.string(prompt)),
          ]),
          json.object([
            #("type", json.string("image_url")),
            #("image_url", json.object([#("url", json.string(data_url))])),
          ]),
        ],
        fn(value) { value },
      ),
    ),
  ])
}

fn request_body(
  model_name: String,
  messages: List(json.Json),
  max_tokens: Int,
  json_mode: Bool,
) -> String {
  let base = [
    #("model", json.string(model_name)),
    #("messages", json.array(messages, fn(value) { value })),
    #("temperature", json.float(0.2)),
    #("max_tokens", json.int(max_tokens)),
    #("stream", json.bool(False)),
  ]
  let base = case string.starts_with(model_name, "deepseek") {
    True -> [
      #("thinking", json.object([#("type", json.string("disabled"))])),
      ..base
    ]
    False -> [#("reasoning_effort", json.string("none")), ..base]
  }

  let entries = case json_mode {
    True -> [
      #("response_format", json.object([#("type", json.string("json_object"))])),
      ..base
    ]
    False -> base
  }

  json.object(entries) |> json.to_string
}

fn call(
  env: worker_ffi.Env,
  model_name: String,
  endpoint: String,
  messages: List(json.Json),
  max_tokens: Int,
  json_mode: Bool,
  session_id: String,
) -> Promise(Result(String, String)) {
  let api_key = worker_ffi.env_get(env, "DEEPSEEK_API_KEY")

  case api_key {
    "" -> promise.resolve(Error("モデル API キーが設定されていません"))
    _ -> {
      let body = request_body(model_name, messages, max_tokens, json_mode)

      chat_completion(api_key, endpoint, body, session_id)
      |> promise.map(fn(result) {
        case result {
          Error(message) -> Error(message)
          Ok(raw) ->
            case json.parse(raw, http_decoder()) {
              Error(_) -> Error("DeepSeek の応答を読めませんでした")
              Ok(http) ->
                case http.status {
                  200 ->
                    case json.parse(http.body, chat_decoder()) {
                      Ok(content) ->
                        case string.trim(content) {
                          "" -> {
                            worker_ffi.log_error(
                              "empty model content: "
                              <> truncate(http.body, 2000),
                            )
                            Ok(content)
                          }
                          _ -> Ok(content)
                        }
                      Error(_) -> Error("DeepSeek の応答形式が想定外です")
                    }
                  status -> Error(api_error(status, http.body))
                }
            }
        }
      })
    }
  }
}

fn api_error(status: Int, body: String) -> String {
  case status {
    402 -> "OpenCode Console の残高が不足しています。Settings → Billing からクレジットを追加してください。"
    401 -> "モデル API キーが無効です。DEEPSEEK_API_KEY の設定を確認してください。"
    429 -> "モデル API のレート制限に達しました。少し待ってから再試行してください。"
    _ -> {
      let detail = case json.parse(body, api_error_decoder()) {
        Ok(message) -> message
        Error(_) -> truncate(body, 300)
      }
      "DeepSeek API エラー (" <> int.to_string(status) <> "): " <> detail
    }
  }
}

fn truncate(text: String, limit: Int) -> String {
  case string.length(text) <= limit {
    True -> text
    False -> string.slice(text, 0, limit) <> "…"
  }
}

pub fn transcribe(
  env: worker_ffi.Env,
  session_id: String,
  page: Int,
  number: String,
  label: String,
  index: Int,
  total: Int,
  data_url: String,
) -> Promise(Result(String, String)) {
  case mock_enabled(env) {
    True -> promise.resolve(Ok(mock_transcription(page)))
    False -> {
      let messages = [
        text_message("system", "あなたは正確な楽譜の読み取りを得意とする音楽理論の専門家です。"),
        vision_message(
          prompts.transcribe_prompt(page, number, label, index, total),
          data_url,
        ),
      ]

      call(
        env,
        transcribe_model(env),
        transcribe_base_url(env),
        messages,
        8000,
        False,
        session_id,
      )
      |> promise.map(fn(result) {
        case result {
          Ok(content) -> {
            let text = shared.strip_code_fence(content)
            case string.trim(text) {
              "" -> Error("モデルから書き起こしが返りませんでした。もう一度お試しください。")
              _ -> Ok(text)
            }
          }
          Error(message) -> Error(message)
        }
      })
    }
  }
}

pub fn analyze(
  env: worker_ffi.Env,
  session_id: String,
  number: String,
  text: String,
) -> Promise(Result(String, String)) {
  case mock_enabled(env) {
    True -> promise.resolve(Ok(mock_analysis()))
    False -> {
      let messages = [
        text_message(
          "system",
          "あなたはプロの音楽理論家です。与えられた譜面の書き起こしだけを根拠に、正確で簡潔な和声分析を日本語で作ります。",
        ),
        text_message("user", prompts.analyze_prompt(number, text)),
      ]

      call(env, model(env), base_url(env), messages, 8000, True, session_id)
      |> promise.map(fn(result) {
        case result {
          Ok(content) -> Ok(shared.strip_code_fence(content))
          Error(message) -> Error(message)
        }
      })
    }
  }
}

pub fn locate(
  env: worker_ffi.Env,
  session_id: String,
  _page: Int,
  targets: List(String),
  system_count: Int,
  data_url: String,
) -> Promise(Result(String, String)) {
  case mock_enabled(env) {
    True -> promise.resolve(Ok(mock_locate(targets)))
    False -> {
      let messages = [
        text_message("system", "あなたは印刷楽譜の曲番号と段の位置を正確に読み取る専門家です。"),
        vision_message(prompts.locate_prompt(targets, system_count), data_url),
      ]

      call(env, model(env), base_url(env), messages, 1500, True, session_id)
      |> promise.map(fn(result) {
        case result {
          Ok(content) -> Ok(shared.strip_code_fence(content))
          Error(message) -> Error(message)
        }
      })
    }
  }
}

// MOCK ------------------------------------------------------------------------

fn mock_locate(targets: List(String)) -> String {
  let found =
    targets
    |> list.map(fn(number) {
      "{\"number\":\"" <> number <> "\",\"systems\":[1,2,3],\"bars\":[8,8,8]}"
    })
    |> string.join(",")
  "{\"found\":[" <> found <> "],\"missing\":[]}"
}

fn mock_transcription(page: Int) -> String {
  let number = int.to_string(page)
  "【モック書き起こし: ページ " <> number <> "】
作品情報: Franz Schubert, 舞曲集（モックデータ）
記譜情報: 調号はフラット1つ（ヘ長調）、拍子は3/4、反復記号あり。
段と小節: 3段、各段8小節。印刷された小節番号は 1〜24。
和音: 1小節目 F、2小節目 C/E、3小節目 F、4小節目 B♭、5小節目 F/C、6小節目 C7、7小節目 F、8小節目 F。
声部とリズム: 右手は歌謡的な旋律、左手は3拍子の伴奏。8小節目で A セクションを反復。
判読メモ: モックモードのため実際の画像は解析していません。"
}

fn mock_analysis() -> String {
  "{\"meta\":{\"key\":\"ヘ長調 / F major\",\"meter\":\"3/4\",\"form\":\"A(1-8) B(9-16) A'(17-24)\",\"confidence\":\"medium\",\"mock\":true},\"table\":[{\"bar\":\"1\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"F-A-C\",\"comment\":\"主和音で開始\"},{\"bar\":\"2\",\"beat\":\"1-3\",\"chord\":\"C/E\",\"function\":\"D\",\"notes\":\"E-G-C、第一転回\"},{\"bar\":\"3\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"F-A-C\"},{\"bar\":\"4\",\"beat\":\"1-3\",\"chord\":\"B♭\",\"function\":\"SD\",\"notes\":\"B♭-D-F\"},{\"bar\":\"5\",\"beat\":\"1-3\",\"chord\":\"F/C\",\"function\":\"T\",\"notes\":\"C-F-A、第二転回\"},{\"bar\":\"6\",\"beat\":\"1-3\",\"chord\":\"C7\",\"function\":\"D\",\"notes\":\"C-E-G-B♭\"},{\"bar\":\"7\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"F-A-C\"},{\"bar\":\"8\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"反復前の終止\"},{\"bar\":\"9\",\"beat\":\"1-3\",\"chord\":\"D♭\",\"function\":\"♭VI\",\"notes\":\"Bセクション冒頭の借用和音\"},{\"bar\":\"10\",\"beat\":\"1-3\",\"chord\":\"A♭/C\",\"function\":\"SD\",\"notes\":\"D♭圏の色彩\"},{\"bar\":\"11\",\"beat\":\"1-3\",\"chord\":\"D♭\",\"function\":\"♭VI\",\"notes\":\"\"},{\"bar\":\"12\",\"beat\":\"1-3\",\"chord\":\"C7\",\"function\":\"D\",\"notes\":\"主調へ復帰\"},{\"bar\":\"13\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"\"},{\"bar\":\"14\",\"beat\":\"1-3\",\"chord\":\"B♭\",\"function\":\"SD\",\"notes\":\"\"},{\"bar\":\"15\",\"beat\":\"1-3\",\"chord\":\"C7\",\"function\":\"D\",\"notes\":\"\"},{\"bar\":\"16\",\"beat\":\"1-3\",\"chord\":\"C7\",\"function\":\"D\",\"notes\":\"Bセクションの終止\"},{\"bar\":\"17\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"A' の再現\"},{\"bar\":\"18\",\"beat\":\"1-3\",\"chord\":\"C/E\",\"function\":\"D\",\"notes\":\"\"},{\"bar\":\"19\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"\"},{\"bar\":\"20\",\"beat\":\"1-3\",\"chord\":\"B♭\",\"function\":\"SD\",\"notes\":\"\"},{\"bar\":\"21\",\"beat\":\"1-3\",\"chord\":\"F/C\",\"function\":\"T\",\"notes\":\"\"},{\"bar\":\"22\",\"beat\":\"1-3\",\"chord\":\"C7\",\"function\":\"D\",\"notes\":\"\"},{\"bar\":\"23\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"\"},{\"bar\":\"24\",\"beat\":\"1-3\",\"chord\":\"F\",\"function\":\"T\",\"notes\":\"最終終止\"}],\"prose\":\"これはモックモードの分析例です。実際の DeepSeek API キーを設定すると、選択したページの書き起こしに基づく和声表と日本語の分析文が生成されます。\\n\\n曲はヘ長調、3/4拍子で、A・B・A′ の三部形式を取ります。A セクションは主和音と属和音を中心にした明快な進行で、B セクションでは♭VI（D♭）を軸にした借用和音が現れ、短いながら色彩的な対比を作っています。A′ では冒頭の進行が回帰し、最後は主和音で確定的に閉じられます。\\n\\n譜面から読み取れる範囲では、転回形の使用と低音の動きが伴奏の流れを支えています。ただし本モックでは画像を実際に解析していないため、細かい非和声音や声部進行は不明です。\"}"
}
