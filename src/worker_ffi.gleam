//// JavaScript bindings for the Cloudflare Worker platform.

import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}

pub type Request

pub type Env

pub type Context

@external(javascript, "./worker_api_ffi.mjs", "request_path")
pub fn request_path(request: Request) -> String

@external(javascript, "./worker_api_ffi.mjs", "request_method")
pub fn request_method(request: Request) -> String

@external(javascript, "./worker_api_ffi.mjs", "request_header")
pub fn request_header(request: Request, name: String) -> String

@external(javascript, "./worker_api_ffi.mjs", "request_text")
pub fn request_text(request: Request) -> Promise(Result(String, String))

@external(javascript, "./worker_api_ffi.mjs", "env_get")
pub fn env_get(env: Env, name: String) -> String

@external(javascript, "./worker_api_ffi.mjs", "env_binding")
pub fn env_binding(env: Env, name: String) -> Dynamic

@external(javascript, "./worker_api_ffi.mjs", "has_binding")
pub fn has_binding(env: Env, name: String) -> Bool

@external(javascript, "./worker_api_ffi.mjs", "json_response")
pub fn json_response(status: Int, body: String) -> Dynamic

@external(javascript, "./worker_api_ffi.mjs", "jst_month")
pub fn jst_month() -> String

@external(javascript, "./worker_api_ffi.mjs", "random_id")
pub fn random_id() -> String

@external(javascript, "./worker_api_ffi.mjs", "log_error")
pub fn log_error(message: String) -> Nil

@external(javascript, "./worker_api_ffi.mjs", "wait_until")
pub fn wait_until(context: Context, promise: Promise(a)) -> Nil
