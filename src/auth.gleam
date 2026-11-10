//// Cloudflare Access authentication.

import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/string
import worker_ffi

/// `allowed` is a comma-separated list of email addresses, supplied through
/// the `ALLOWED_EMAILS` environment variable so that addresses are not stored
/// in the repository.
pub fn is_allowed(email: String, allowed: String) -> Bool {
  allowed
  |> string.split(",")
  |> list.map(string.trim)
  |> list.map(string.lowercase)
  |> list.contains(string.lowercase(email))
}

@external(javascript, "./auth_ffi.mjs", "verify_access_jwt")
fn verify_access_jwt(
  token: String,
  audience: String,
  team_domain: String,
) -> Promise(Result(String, String))

pub fn authenticate(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
) -> Promise(Result(String, String)) {
  let dev_email = worker_ffi.env_get(env, "DEV_EMAIL")
  let allowed = worker_ffi.env_get(env, "ALLOWED_EMAILS")

  case dev_email {
    "" -> authenticate_with_access(request, env)
    email ->
      case is_allowed(email, allowed) {
        True -> promise.resolve(Ok(string.lowercase(email)))
        False -> promise.resolve(Error("このアカウントには利用権限がありません"))
      }
  }
}

fn authenticate_with_access(
  request: worker_ffi.Request,
  env: worker_ffi.Env,
) -> Promise(Result(String, String)) {
  let token = worker_ffi.request_header(request, "cf-access-jwt-assertion")
  let audience = worker_ffi.env_get(env, "POLICY_AUD")
  let team_domain = worker_ffi.env_get(env, "TEAM_DOMAIN")
  let allowed = worker_ffi.env_get(env, "ALLOWED_EMAILS")

  case token {
    "" -> promise.resolve(Error("Access のログインが必要です"))
    _ ->
      verify_access_jwt(token, audience, team_domain)
      |> promise.map(fn(result) {
        case result {
          Ok(body) ->
            case json.parse(body, email_decoder()) {
              Ok(email) ->
                case is_allowed(email, allowed) {
                  True -> Ok(string.lowercase(email))
                  False -> Error("このアカウントには利用権限がありません")
                }
              Error(_) -> Error("ログイン情報を読めませんでした")
            }
          Error(message) -> Error(message)
        }
      })
  }
}

fn email_decoder() -> decode.Decoder(String) {
  use email <- decode.field("email", decode.string)
  decode.success(email)
}
