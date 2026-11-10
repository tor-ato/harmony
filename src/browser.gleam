//// Bindings for the browser-only helpers (pdf.js, fetch, print).

import gleam/javascript/promise.{type Promise}

@external(javascript, "./browser_ffi.mjs", "load_pdf")
pub fn load_pdf() -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "render_page")
pub fn render_page(page: Int) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "render_page_parts")
pub fn render_page_parts(page: Int) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "render_page_overview")
pub fn render_page_overview(page: Int) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "render_system_crops")
pub fn render_system_crops(
  page: Int,
  number: String,
  systems: List(Int),
  bars: List(Int),
) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "api_get")
pub fn api_get(path: String) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "api_post")
pub fn api_post(path: String, body: String) -> Promise(Result(String, String))

@external(javascript, "./browser_ffi.mjs", "reset_pdf")
pub fn reset_pdf() -> Nil

@external(javascript, "./browser_ffi.mjs", "print_page")
pub fn print_page() -> Nil
