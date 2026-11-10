//// Lustre single-page app: targeted piece location, transcription, review,
//// and per-piece harmony results.

import browser
import gleam/int
import gleam/javascript/promise
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared

const app_version = "2026-11-11.1"

const max_parallel_transcriptions = 3

const max_systems_per_request = 12

// MODEL -----------------------------------------------------------------------

pub type Stage {
  Selecting
  Locating
  Preparing
  Located
  Transcribing
  Analyzing
  Done
  Failed
}

pub type AnalysisMode {
  ByNumber
  WholeDocument
}

pub type TargetStatus {
  Pending
  TargetTranscribing
  Transcribed
  TargetAnalyzing
  TargetDone
  FailedTarget
  Missing
  QuotaExceeded
}

pub type TargetPage {
  TargetPage(page: Int, systems: List(Int), bars: List(Int))
}

pub type Target {
  Target(
    number: String,
    label: String,
    pages: List(TargetPage),
    sections: List(#(Int, String)),
    text: String,
    status: TargetStatus,
    analysis: Option(shared.Analysis),
    error: String,
  )
}

pub type TranscribeJob {
  TranscribeJob(
    number: String,
    page: Int,
    display: String,
    systems: List(Int),
    bars: List(Int),
  )
}

pub type Model {
  Model(
    stage: Stage,
    error: String,
    info: Option(shared.PdfInfo),
    selected: List(Int),
    mode: AnalysisMode,
    target_input: String,
    title_input: String,
    targets: List(Target),
    locate_targets: List(String),
    locate_pages: List(Int),
    locate_results: List(#(Int, shared.LocateResult)),
    locate_active: Option(Int),
    overview_queue: List(Int),
    overview_pages: List(#(Int, Int)),
    overview_total: Int,
    overview_done: Int,
    transcribe_queue: List(TranscribeJob),
    transcribe_running: Int,
    transcribe_total: Int,
    transcribe_done: Int,
    transcribe_active: Option(#(String, Int)),
    analyze_queue: List(String),
    analyze_total: Int,
    analyze_done: Int,
    active_target: Option(String),
    quota: Option(shared.Quota),
  )
}

fn initial_model() -> Model {
  Model(
    stage: Selecting,
    error: "",
    info: None,
    selected: [],
    mode: ByNumber,
    target_input: "",
    title_input: "",
    targets: [],
    locate_targets: [],
    locate_pages: [],
    locate_results: [],
    locate_active: None,
    overview_queue: [],
    overview_pages: [],
    overview_total: 0,
    overview_done: 0,
    transcribe_queue: [],
    transcribe_running: 0,
    transcribe_total: 0,
    transcribe_done: 0,
    transcribe_active: None,
    analyze_queue: [],
    analyze_total: 0,
    analyze_done: 0,
    active_target: None,
    quota: None,
  )
}

// MESSAGES --------------------------------------------------------------------

pub type Msg {
  FileChosen
  PdfLoaded(Result(String, String))
  TogglePage(Int)
  SelectAll
  ClearSelection
  ModeChanged(AnalysisMode)
  TargetInputChanged(String)
  TitleInputChanged(String)
  BeginLocate
  LocatePageFinished(Int, Result(String, String))
  BackToSelecting
  BeginWholeDocument
  OverviewPageFinished(Int, Result(String, String))
  BeginTranscription
  PageTranscribed(String, Int, Result(String, String))
  TargetAnalyzed(String, Result(String, String))
  QuotaReceived(Result(String, String))
  Reset
  Print
}

// UPDATE ----------------------------------------------------------------------

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    FileChosen -> #(model, load_pdf_effect())

    PdfLoaded(result) -> handle_pdf_loaded(model, result)

    TogglePage(page) -> {
      let selected = case list.contains(model.selected, page) {
        True -> list.filter(model.selected, fn(item) { item != page })
        False -> [page, ..model.selected]
      }
      #(Model(..model, selected:), effect.none())
    }

    SelectAll ->
      case model.info {
        Some(info) -> #(
          Model(
            ..model,
            selected: list.map(info.thumbs, fn(thumb) { thumb.page }),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    ClearSelection -> #(Model(..model, selected: []), effect.none())

    ModeChanged(mode) -> #(Model(..model, mode:, error: ""), effect.none())

    TargetInputChanged(value) -> #(
      Model(..model, target_input: value),
      effect.none(),
    )

    TitleInputChanged(value) -> #(
      Model(..model, title_input: value),
      effect.none(),
    )

    BeginLocate -> begin_locate(model)

    LocatePageFinished(page, result) ->
      handle_locate_finished(model, page, result)

    BackToSelecting -> #(
      Model(
        ..model,
        stage: Selecting,
        targets: [],
        locate_results: [],
        error: "",
      ),
      effect.none(),
    )

    BeginWholeDocument -> begin_whole_document(model)

    OverviewPageFinished(page, result) ->
      handle_overview_finished(model, page, result)

    BeginTranscription -> begin_transcription(model)

    PageTranscribed(number, page, result) ->
      handle_page_transcribed(model, number, page, result)

    TargetAnalyzed(number, result) ->
      handle_target_analyzed(model, number, result)

    QuotaReceived(result) -> handle_quota(model, result)

    Reset -> #(initial_model(), reset_effect())

    Print -> #(model, print_effect())
  }
}

fn handle_pdf_loaded(
  model: Model,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(message) -> #(
      Model(..model, stage: Failed, error: message),
      effect.none(),
    )
    Ok(raw) ->
      case json.parse(raw, shared.pdf_info_decoder()) {
        Error(_) -> #(
          Model(..model, stage: Failed, error: "PDF の情報を読めませんでした"),
          effect.none(),
        )
        Ok(info) -> {
          let selected = list.map(info.thumbs, fn(thumb) { thumb.page })
          #(
            Model(
              ..model,
              stage: Selecting,
              info: Some(info),
              selected:,
              targets: [],
              error: "",
            ),
            quota_effect(),
          )
        }
      }
  }
}

// LOCATE ----------------------------------------------------------------------

fn begin_locate(model: Model) -> #(Model, Effect(Msg)) {
  let targets = parse_targets(model.target_input)

  case model.info, model.selected, targets {
    Some(_), [], _ -> #(
      Model(..model, error: "ページを1つ以上選択してください"),
      effect.none(),
    )
    _, _, [] -> #(Model(..model, error: "分析する曲番号を入力してください"), effect.none())
    Some(_), pages, targets -> {
      let model =
        Model(
          ..model,
          stage: Locating,
          error: "",
          locate_targets: targets,
          locate_pages: pages,
          locate_results: [],
          locate_active: None,
          targets: [],
        )
      locate_next(model)
    }
    None, _, _ -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
  }
}

fn locate_next(model: Model) -> #(Model, Effect(Msg)) {
  case model.info, model.locate_pages {
    Some(info), [page, ..rest] -> #(
      Model(..model, locate_pages: rest, locate_active: Some(page)),
      locate_page_effect(page, info.doc_id, model.locate_targets),
    )
    Some(_), [] -> finish_locate(model)
    None, _ -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
  }
}

fn handle_locate_finished(
  model: Model,
  page: Int,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(message) -> #(
      Model(..model, stage: Failed, error: message, locate_active: None),
      effect.none(),
    )
    Ok(raw) ->
      case shared.parse_api_response(raw) {
        Error(message) -> #(
          Model(..model, stage: Failed, error: message, locate_active: None),
          effect.none(),
        )
        Ok(api) ->
          case api.ok {
            False -> #(
              Model(
                ..model,
                stage: Failed,
                error: api.error,
                locate_active: None,
              ),
              effect.none(),
            )
            True ->
              case json.parse(api.body, shared.locate_result_decoder()) {
                Error(_) -> #(
                  Model(
                    ..model,
                    stage: Failed,
                    error: "ロケート結果を読めませんでした",
                    locate_active: None,
                  ),
                  effect.none(),
                )
                Ok(located) -> {
                  let model =
                    Model(
                      ..model,
                      locate_results: [#(page, located), ..model.locate_results],
                      locate_active: None,
                    )
                  locate_next(model)
                }
              }
          }
      }
  }
}

fn finish_locate(model: Model) -> #(Model, Effect(Msg)) {
  let targets =
    model.locate_targets
    |> list.map(fn(number) {
      let pages =
        model.locate_results
        |> list.filter_map(fn(result) {
          let #(page, located) = result
          case list.find(located.found, fn(found) { found.number == number }) {
            Ok(found) ->
              Ok(TargetPage(
                page:,
                systems: found.systems,
                bars: usable_bars(found),
              ))
            Error(_) -> Error(Nil)
          }
        })
        |> list.sort(fn(a, b) { int.compare(a.page, b.page) })

      let label = "No." <> number
      case pages {
        [] ->
          Target(
            number:,
            label:,
            pages: [],
            sections: [],
            text: "",
            status: Missing,
            analysis: None,
            error: "",
          )
        _ ->
          Target(
            number:,
            label:,
            pages:,
            sections: [],
            text: "",
            status: Pending,
            analysis: None,
            error: "",
          )
      }
    })

  let found =
    list.filter(targets, fn(target) {
      case target.status {
        Missing -> False
        _ -> True
      }
    })

  case list.length(found) {
    0 -> #(
      Model(..model, stage: Failed, targets:, error: "指定した番号が選択ページに見つかりませんでした"),
      effect.none(),
    )
    _ -> #(Model(..model, stage: Located, targets:), effect.none())
  }
}

// TRANSCRIBE ------------------------------------------------------------------

// WHOLE DOCUMENT --------------------------------------------------------------

fn begin_whole_document(model: Model) -> #(Model, Effect(Msg)) {
  case model.info, model.selected {
    Some(_), [] -> #(Model(..model, error: "ページを1つ以上選択してください"), effect.none())
    Some(_), pages -> {
      let pages = list.sort(pages, int.compare)
      let label = model_label(model)
      let model =
        Model(
          ..model,
          stage: Preparing,
          error: "",
          mode: WholeDocument,
          targets: [
            Target(
              number: "ALL",
              label:,
              pages: [],
              sections: [],
              text: "",
              status: Pending,
              analysis: None,
              error: "",
            ),
          ],
          overview_queue: pages,
          overview_pages: [],
          overview_total: list.length(pages),
          overview_done: 0,
          transcribe_queue: [],
          transcribe_running: 0,
          transcribe_total: 0,
          transcribe_done: 0,
          transcribe_active: None,
          analyze_queue: [],
          analyze_total: 0,
          analyze_done: 0,
          active_target: None,
        )
      overview_next(model)
    }
    None, _ -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
  }
}

fn overview_next(model: Model) -> #(Model, Effect(Msg)) {
  case model.info, model.overview_queue {
    Some(info), [page, ..rest] -> #(
      Model(..model, overview_queue: rest),
      overview_page_effect(page, info.doc_id),
    )
    Some(_), [] -> {
      let pages =
        model.overview_pages
        |> list.filter(fn(pair) { pair.1 > 0 })
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
      case pages {
        [] -> #(
          Model(..model, stage: Failed, error: "選択したページから段を検出できませんでした"),
          effect.none(),
        )
        _ -> {
          let targets =
            list.map(model.targets, fn(target) {
              let target_pages =
                list.map(pages, fn(pair) {
                  let #(page, system_count) = pair
                  TargetPage(
                    page:,
                    systems: int_range(1, system_count),
                    bars: [],
                  )
                })
              Target(..target, pages: target_pages)
            })
          begin_transcription(Model(..model, targets:))
        }
      }
    }
    None, _ -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
  }
}

fn handle_overview_finished(
  model: Model,
  page: Int,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(message) -> #(
      Model(..model, stage: Failed, error: message),
      effect.none(),
    )
    Ok(raw) ->
      case json.parse(raw, shared.overview_decoder()) {
        Error(_) -> #(
          Model(..model, stage: Failed, error: "ページ概要を作れませんでした"),
          effect.none(),
        )
        Ok(shared.Overview(system_count:, ..)) -> {
          let model =
            Model(
              ..model,
              overview_pages: [#(page, system_count), ..model.overview_pages],
              overview_done: model.overview_done + 1,
            )
          overview_next(model)
        }
      }
  }
}

fn begin_transcription(model: Model) -> #(Model, Effect(Msg)) {
  let queue =
    model.targets
    |> list.filter(fn(target) {
      case target.status {
        Missing -> False
        _ -> True
      }
    })
    |> list.flat_map(fn(target) {
      list.flat_map(target.pages, fn(page) {
        let display = crop_display(model, target, page.page)
        transcribe_jobs(target.number, page, display)
      })
    })

  case queue {
    [] -> #(Model(..model, error: "書き起こす対象がありません"), effect.none())
    _ -> {
      let next_model =
        Model(
          ..model,
          stage: Transcribing,
          error: "",
          targets: list.map(model.targets, fn(target) {
            case target.status {
              Missing -> target
              _ -> Target(..target, status: Pending, text: "")
            }
          }),
          transcribe_queue: queue,
          transcribe_running: 0,
          transcribe_total: list.length(queue),
          transcribe_done: 0,
          transcribe_active: None,
        )
      start_transcription_batch(next_model)
    }
  }
}

fn start_transcription_batch(model: Model) -> #(Model, Effect(Msg)) {
  case model.info {
    None -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
    Some(info) -> {
      let free = max_parallel_transcriptions - model.transcribe_running
      let available = list.length(model.transcribe_queue)
      let count = case free < available {
        True -> free
        False -> available
      }

      case count {
        0 ->
          case model.transcribe_running, model.transcribe_queue {
            0, [] -> {
              let targets =
                list.map(model.targets, fn(target) {
                  case target.status {
                    Missing -> target
                    _ -> Target(..target, status: Transcribed)
                  }
                })
              begin_analysis(Model(..model, transcribe_active: None, targets:))
            }
            _, _ -> #(model, effect.none())
          }
        _ -> {
          let batch = list.take(model.transcribe_queue, count)
          let rest = list.drop(model.transcribe_queue, count)
          let first = case batch {
            [job, ..] -> Some(#(job.number, job.page))
            [] -> None
          }
          let targets =
            list.fold(batch, model.targets, fn(targets, job) {
              update_target(targets, job.number, fn(target) {
                Target(..target, status: TargetTranscribing)
              })
            })
          #(
            Model(
              ..model,
              targets:,
              transcribe_queue: rest,
              transcribe_running: model.transcribe_running + count,
              transcribe_active: first,
            ),
            transcribe_batch_effect(batch, info.doc_id, info.page_count),
          )
        }
      }
    }
  }
}

fn handle_page_transcribed(
  model: Model,
  number: String,
  page: Int,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case model.stage {
    Transcribing -> {
      let running = case model.transcribe_running > 0 {
        True -> model.transcribe_running - 1
        False -> 0
      }
      case result {
        Error(message) -> #(
          Model(
            ..model,
            stage: Failed,
            error: message,
            transcribe_running: running,
            transcribe_active: None,
          ),
          effect.none(),
        )
        Ok(raw) ->
          case shared.parse_api_response(raw) {
            Error(message) -> #(
              Model(
                ..model,
                stage: Failed,
                error: message,
                transcribe_running: running,
                transcribe_active: None,
              ),
              effect.none(),
            )
            Ok(api) ->
              case api.ok {
                False -> #(
                  Model(
                    ..model,
                    stage: Failed,
                    error: api.error,
                    transcribe_running: running,
                    transcribe_active: None,
                  ),
                  effect.none(),
                )
                True ->
                  case json.parse(api.body, shared.page_text_decoder()) {
                    Error(_) -> #(
                      Model(
                        ..model,
                        stage: Failed,
                        error: "書き起こしを読めませんでした",
                        transcribe_running: running,
                        transcribe_active: None,
                      ),
                      effect.none(),
                    )
                    Ok(shared.PageText(text: page_text)) -> {
                      let targets =
                        update_target(model.targets, number, fn(target) {
                          let sections =
                            list.append(target.sections, [#(page, page_text)])
                          Target(
                            ..target,
                            sections:,
                            text: assemble_sections(sections),
                            status: TargetTranscribing,
                          )
                        })

                      let model =
                        Model(
                          ..model,
                          targets:,
                          transcribe_done: model.transcribe_done + 1,
                          transcribe_running: running,
                          transcribe_active: None,
                        )
                      start_transcription_batch(model)
                    }
                  }
              }
          }
      }
    }
    _ -> #(model, effect.none())
  }
}

// ANALYZE ---------------------------------------------------------------------

fn begin_analysis(model: Model) -> #(Model, Effect(Msg)) {
  let queue =
    model.targets
    |> list.filter(fn(target) {
      case target.status {
        Missing -> False
        _ -> !string.is_empty(string.trim(target.text))
      }
    })
    |> list.map(fn(target) { target.number })

  case queue {
    [] -> #(Model(..model, error: "分析できる書き起こしがありません"), effect.none())
    _ -> {
      let model =
        Model(
          ..model,
          stage: Analyzing,
          error: "",
          analyze_queue: queue,
          analyze_total: list.length(queue),
          analyze_done: 0,
          active_target: None,
          targets: list.map(model.targets, fn(target) {
            case list.contains(queue, target.number) {
              True -> Target(..target, status: TargetAnalyzing)
              False -> target
            }
          }),
        )
      analyze_next(model)
    }
  }
}

fn analyze_next(model: Model) -> #(Model, Effect(Msg)) {
  case model.info, model.analyze_queue {
    Some(info), [number, ..rest] -> {
      let text = case target_by_number(model.targets, number) {
        Some(target) -> target.text
        None -> ""
      }
      let title = case number {
        "ALL" -> string.trim(model.title_input)
        _ -> ""
      }
      #(
        Model(..model, analyze_queue: rest, active_target: Some(number)),
        analyze_target_effect(number, info.doc_id, text, title),
      )
    }
    Some(_), [] -> {
      #(Model(..model, stage: Done, active_target: None), quota_effect())
    }
    None, _ -> #(
      Model(..model, stage: Failed, error: "PDF が読み込まれていません"),
      effect.none(),
    )
  }
}

fn handle_target_analyzed(
  model: Model,
  number: String,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(message) -> {
      let targets =
        update_target(model.targets, number, fn(target) {
          Target(..target, status: FailedTarget, error: message)
        })
      continue_analysis(Model(..model, targets:), number)
    }
    Ok(raw) ->
      case shared.parse_api_response(raw) {
        Error(message) -> {
          let targets =
            update_target(model.targets, number, fn(target) {
              Target(..target, status: FailedTarget, error: message)
            })
          continue_analysis(Model(..model, targets:), number)
        }
        Ok(api) ->
          case api.ok {
            True ->
              case json.parse(api.body, shared.analysis_decoder()) {
                Error(_) -> {
                  let targets =
                    update_target(model.targets, number, fn(target) {
                      Target(
                        ..target,
                        status: FailedTarget,
                        error: "分析結果を読めませんでした",
                      )
                    })
                  continue_analysis(Model(..model, targets:), number)
                }
                Ok(analysis) -> {
                  let targets =
                    update_target(model.targets, number, fn(target) {
                      Target(
                        ..target,
                        status: TargetDone,
                        analysis: Some(analysis),
                        error: "",
                      )
                    })
                  continue_analysis(Model(..model, targets:), number)
                }
              }
            False ->
              case api.status {
                429 -> {
                  let remaining = model.analyze_queue
                  let targets =
                    model.targets
                    |> update_target(number, fn(target) {
                      Target(..target, status: QuotaExceeded, error: api.error)
                    })
                    |> update_many(remaining, fn(target) {
                      Target(..target, status: QuotaExceeded, error: api.error)
                    })
                  #(
                    Model(
                      ..model,
                      stage: Done,
                      targets:,
                      analyze_queue: [],
                      active_target: None,
                      error: api.error,
                    ),
                    quota_effect(),
                  )
                }
                _ -> {
                  let targets =
                    update_target(model.targets, number, fn(target) {
                      Target(..target, status: FailedTarget, error: api.error)
                    })
                  continue_analysis(Model(..model, targets:), number)
                }
              }
          }
      }
  }
}

fn continue_analysis(model: Model, _number: String) -> #(Model, Effect(Msg)) {
  let done = model.analyze_done + 1
  let model = Model(..model, analyze_done: done, active_target: None)
  analyze_next(model)
}

// HELPERS ---------------------------------------------------------------------

fn parse_targets(input: String) -> List(String) {
  input
  |> string.replace("、", ",")
  |> string.replace(" ", ",")
  |> string.split(",")
  |> list.flat_map(fn(part) {
    let trimmed = string.trim(part)
    case string.split(trimmed, "-") {
      [start, end] -> expand_range(start, end)
      _ -> [trimmed]
    }
  })
  |> list.filter_map(fn(value) {
    case normalize_number(value) {
      Some(number) -> Ok(number)
      None -> Error(Nil)
    }
  })
  |> list.unique
}

fn expand_range(start: String, end: String) -> List(String) {
  case int.parse(string.trim(start)), int.parse(string.trim(end)) {
    Ok(first), Ok(last) ->
      case first > 0 && last >= first && last - first <= 20 {
        True -> range_numbers(first, last)
        False -> []
      }
    _, _ -> []
  }
}

fn range_numbers(first: Int, last: Int) -> List(String) {
  case first > last {
    True -> []
    False -> [int.to_string(first), ..range_numbers(first + 1, last)]
  }
}

fn int_range(first: Int, last: Int) -> List(Int) {
  case first > last {
    True -> []
    False -> [first, ..int_range(first + 1, last)]
  }
}

fn assemble_sections(sections: List(#(Int, String))) -> String {
  sections
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(pair) { "【ページ " <> int.to_string(pair.0) <> "】\n" <> pair.1 })
  |> string.join("\n\n")
}

fn model_label(model: Model) -> String {
  case string.trim(model.title_input) {
    "" -> "PDF全体"
    title -> title
  }
}

fn crop_display(model: Model, target: Target, page: Int) -> String {
  case model.mode {
    ByNumber -> "No." <> target.number
    WholeDocument ->
      case model.info {
        Some(info) ->
          case info.page_count > 1 {
            True -> "p" <> int.to_string(page)
            False -> "PDF全体"
          }
        None -> "PDF全体"
      }
  }
}

fn transcribe_jobs(
  number: String,
  target_page: TargetPage,
  display: String,
) -> List(TranscribeJob) {
  let bars = case
    list.length(target_page.bars) == list.length(target_page.systems)
  {
    True -> target_page.bars
    False -> list.map(target_page.systems, fn(_) { 0 })
  }
  let pairs = list.zip(target_page.systems, bars)
  chunk_jobs(number, target_page.page, display, pairs)
}

fn chunk_jobs(
  number: String,
  page: Int,
  display: String,
  pairs: List(#(Int, Int)),
) -> List(TranscribeJob) {
  case pairs {
    [] -> []
    _ -> {
      let size = case list.length(pairs) > max_systems_per_request {
        True -> max_systems_per_request
        False -> list.length(pairs)
      }
      let head = list.take(pairs, size)
      let rest = list.drop(pairs, size)
      [
        TranscribeJob(
          number:,
          page:,
          display:,
          systems: list.map(head, fn(pair) { pair.0 }),
          bars: list.map(head, fn(pair) { pair.1 }),
        ),
        ..chunk_jobs(number, page, display, rest)
      ]
    }
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
    Ok(number) ->
      case number > 0 {
        True -> Some(int.to_string(number))
        False -> None
      }
    Error(_) -> None
  }
}

fn target_by_number(targets: List(Target), number: String) -> Option(Target) {
  case list.find(targets, fn(target) { target.number == number }) {
    Ok(target) -> Some(target)
    Error(_) -> None
  }
}

fn update_target(
  targets: List(Target),
  number: String,
  update: fn(Target) -> Target,
) -> List(Target) {
  list.map(targets, fn(target) {
    case target.number == number {
      True -> update(target)
      False -> target
    }
  })
}

fn update_many(
  targets: List(Target),
  numbers: List(String),
  update: fn(Target) -> Target,
) -> List(Target) {
  list.map(targets, fn(target) {
    case list.contains(numbers, target.number) {
      True -> update(target)
      False -> target
    }
  })
}

fn usable_bars(found: shared.FoundTarget) -> List(Int) {
  let total = list.fold(found.bars, 0, int.add)
  case total > 0 && list.length(found.bars) == list.length(found.systems) {
    True -> found.bars
    False -> list.map(found.systems, fn(_system) { 8 })
  }
}

fn systems_summary(target: Target) -> String {
  target.pages
  |> list.map(fn(target_page) {
    let labels =
      target_page.systems
      |> list.map(int.to_string)
      |> string.join(",")
    let bars = list.fold(target_page.bars, 0, int.add)
    let range = case bars > 0 {
      True -> " 小節1-" <> int.to_string(bars)
      False -> ""
    }
    "p." <> int.to_string(target_page.page) <> " 段" <> labels <> range
  })
  |> string.join(" / ")
}

fn found_count(targets: List(Target)) -> Int {
  list.filter(targets, fn(target) {
    case target.status {
      Missing -> False
      _ -> True
    }
  })
  |> list.length
}

// EFFECTS ---------------------------------------------------------------------

fn load_pdf_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let _ =
      browser.load_pdf()
      |> promise.map(fn(result) { dispatch(PdfLoaded(result)) })
    Nil
  })
}

fn quota_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let _ =
      browser.api_get("/api/quota")
      |> promise.map(fn(result) { dispatch(QuotaReceived(result)) })
    Nil
  })
}

fn reset_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    browser.reset_pdf()
    Nil
  })
}

fn print_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    browser.print_page()
    Nil
  })
}

fn locate_page_effect(
  page: Int,
  doc_id: String,
  targets: List(String),
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let work =
      browser.render_page_overview(page)
      |> promise.await(fn(rendered) {
        case rendered {
          Error(message) -> promise.resolve(Error(message))
          Ok(raw) ->
            case json.parse(raw, shared.overview_decoder()) {
              Error(_) -> promise.resolve(Error("ページ概要を作れませんでした"))
              Ok(shared.Overview(data_url:, system_count:)) -> {
                let body =
                  json.object([
                    #("doc_id", json.string(doc_id)),
                    #("page", json.int(page)),
                    #("image", json.string(data_url)),
                    #("targets", json.array(targets, json.string)),
                    #("system_count", json.int(system_count)),
                  ])
                  |> json.to_string

                browser.api_post("/api/locate", body)
              }
            }
        }
      })

    let _ =
      work
      |> promise.map(fn(result) { dispatch(LocatePageFinished(page, result)) })
    Nil
  })
}

fn overview_page_effect(page: Int, _doc_id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let _ =
      browser.render_page_overview(page)
      |> promise.map(fn(result) { dispatch(OverviewPageFinished(page, result)) })
    Nil
  })
}

fn transcribe_batch_effect(
  jobs: List(TranscribeJob),
  doc_id: String,
  document_pages: Int,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    list.each(jobs, fn(job) {
      let work =
        browser.render_system_crops(
          job.page,
          job.display,
          job.systems,
          job.bars,
        )
        |> promise.await(fn(rendered) {
          case rendered {
            Error(message) -> promise.resolve(Error(message))
            Ok(raw) ->
              case json.parse(raw, shared.render_parts_decoder()) {
                Error(_) -> promise.resolve(Error("ページ画像を作れませんでした"))
                Ok(shared.RenderParts(parts: parts)) -> {
                  let json_parts =
                    list.map(parts, fn(part) {
                      json.object([
                        #("label", json.string(part.label)),
                        #("data_url", json.string(part.data_url)),
                      ])
                    })

                  let body =
                    json.object([
                      #("doc_id", json.string(doc_id)),
                      #("page", json.int(job.page)),
                      #("number", json.string(job.number)),
                      #("document_pages", json.int(document_pages)),
                      #("parts", json.array(json_parts, fn(value) { value })),
                    ])
                    |> json.to_string

                  browser.api_post("/api/transcribe", body)
                }
              }
          }
        })

      let _ =
        work
        |> promise.map(fn(result) {
          dispatch(PageTranscribed(job.number, job.page, result))
        })
      Nil
    })
    Nil
  })
}

fn analyze_target_effect(
  number: String,
  doc_id: String,
  text: String,
  title: String,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let body =
      json.object([
        #("doc_id", json.string(doc_id)),
        #("number", json.string(number)),
        #("title", json.string(title)),
        #("text", json.string(text)),
      ])
      |> json.to_string

    let _ =
      browser.api_post("/api/finalize", body)
      |> promise.map(fn(result) { dispatch(TargetAnalyzed(number, result)) })
    Nil
  })
}

fn handle_quota(
  model: Model,
  result: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case result {
    Ok(raw) ->
      case shared.parse_api_response(raw) {
        Ok(api) ->
          case api.ok {
            True ->
              case json.parse(api.body, shared.quota_decoder()) {
                Ok(quota) -> #(
                  Model(..model, quota: Some(quota)),
                  effect.none(),
                )
                Error(_) -> #(model, effect.none())
              }
            False -> #(model, effect.none())
          }
        Error(_) -> #(model, effect.none())
      }
    Error(_) -> #(model, effect.none())
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], [
    html.header([attribute.class("masthead")], [
      html.div([attribute.class("brand")], [
        html.h1([], [html.text("Harmony")]),
        html.p([attribute.class("tagline")], [
          html.text("楽譜から、和声分析を"),
        ]),
      ]),
      quota_badge(model.quota),
    ]),
    view_error(model),
    view_body(model),
    html.footer([attribute.class("footer")], [
      html.text("Friends beta · 月10回まで · Cloudflare · " <> app_version),
    ]),
  ])
}

fn view_error(model: Model) -> Element(Msg) {
  case model.error {
    "" -> html.div([attribute.class("hidden")], [])
    message ->
      html.div(
        [attribute.class("banner banner-error"), attribute.role("alert")],
        [
          html.strong([], [html.text("エラー: ")]),
          html.span([], [html.text(message)]),
        ],
      )
  }
}

fn quota_badge(quota: Option(shared.Quota)) -> Element(Msg) {
  case quota {
    None ->
      html.div([attribute.class("quota quota-muted")], [
        html.text("利用回数を確認中"),
      ])
    Some(q) ->
      html.div([attribute.class("quota")], [
        html.span([attribute.class("quota-label")], [html.text("今月の残り")]),
        html.strong([], [
          html.text(
            int.to_string(q.remaining) <> " / " <> int.to_string(q.limit),
          ),
        ]),
        html.span([attribute.class("quota-month")], [html.text(q.month)]),
      ])
  }
}

fn view_body(model: Model) -> Element(Msg) {
  case model.stage {
    Selecting ->
      case model.info {
        Some(info) -> view_select(model, info)
        None -> view_upload()
      }
    Locating -> view_locating(model)
    Preparing -> view_preparing(model)
    Located -> view_located(model)
    Transcribing -> view_transcribing(model)
    Analyzing -> view_analyzing(model)
    Done -> view_done(model)
    Failed -> view_failed(model)
  }
}

fn view_upload() -> Element(Msg) {
  html.section([attribute.class("card upload")], [
    html.h2([], [html.text("PDF を選択")]),
    html.p([], [
      html.text("譜面の PDF を選び、分析したい曲のページを選択してください。"),
    ]),
    html.label([attribute.class("file-drop"), attribute.for("pdf-input")], [
      html.input([
        attribute.type_("file"),
        attribute.id("pdf-input"),
        attribute.accept(["application/pdf"]),
        attribute.class("file-input"),
        event.on_change(fn(_value) { FileChosen }),
      ]),
      html.span([attribute.class("file-drop-label")], [
        html.text("PDF ファイルを選択（40MB まで）"),
      ]),
    ]),
    html.p([attribute.class("muted")], [
      html.text("画像はブラウザ内でページごとに JPEG 化され、モデルに送信されます。元の PDF は保存されません。"),
    ]),
  ])
}

fn view_select(model: Model, info: shared.PdfInfo) -> Element(Msg) {
  let count = list.length(model.selected)

  html.section([attribute.class("card")], [
    html.div([attribute.class("section-head")], [
      html.div([], [
        html.h2([], [html.text("ページと対象曲を選択")]),
        html.p([attribute.class("muted")], [
          html.text(
            info.name <> " · 全 " <> int.to_string(info.page_count) <> " ページ",
          ),
        ]),
      ]),
      html.div([attribute.class("toolbar")], [
        html.button([attribute.type_("button"), event.on_click(SelectAll)], [
          html.text("すべて選択"),
        ]),
        html.button(
          [attribute.type_("button"), event.on_click(ClearSelection)],
          [html.text("選択解除")],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("ghost"),
            event.on_click(Reset),
          ],
          [html.text("別のPDF")],
        ),
      ]),
    ]),
    html.div([attribute.class("mode-switch")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class(case model.mode {
            ByNumber -> "mode-tab active"
            WholeDocument -> "mode-tab"
          }),
          event.on_click(ModeChanged(ByNumber)),
        ],
        [html.text("曲番号で探す")],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class(case model.mode {
            WholeDocument -> "mode-tab active"
            ByNumber -> "mode-tab"
          }),
          event.on_click(ModeChanged(WholeDocument)),
        ],
        [html.text("PDF全体を1曲として")],
      ),
    ]),
    case model.mode {
      ByNumber ->
        html.div([attribute.class("target-input-row")], [
          html.label([attribute.class("target-label")], [
            html.text("分析する曲番号"),
          ]),
          html.input([
            attribute.type_("text"),
            attribute.id("targets"),
            attribute.class("target-input"),
            attribute.placeholder("例: 32 または 32,33,34 / 32-34"),
            attribute.value(model.target_input),
            event.on_input(fn(value) { TargetInputChanged(value) }),
          ]),
          html.span([attribute.class("muted small")], [
            html.text("カンマ区切り・範囲指定（32-34）が使えます。番号ごとに分析します。"),
          ]),
        ])
      WholeDocument ->
        html.div([attribute.class("target-input-row")], [
          html.label([attribute.class("target-label")], [
            html.text("曲名（任意）"),
          ]),
          html.input([
            attribute.type_("text"),
            attribute.id("title-input"),
            attribute.class("target-input"),
            attribute.placeholder("例: ポニョ（空欄でも解析できます）"),
            attribute.value(model.title_input),
            event.on_input(fn(value) { TitleInputChanged(value) }),
          ]),
          html.span([attribute.class("muted small")], [
            html.text("選択したページ全体を1つの作品として分析します（8ページでも1回）。"),
          ]),
        ])
    },
    input_examples(),
    html.div([attribute.class("page-grid")], {
      info.thumbs
      |> list.map(fn(thumb) {
        let selected = list.contains(model.selected, thumb.page)
        html.label(
          [
            attribute.class(case selected {
              True -> "page-tile selected"
              False -> "page-tile"
            }),
          ],
          [
            html.input([
              attribute.type_("checkbox"),
              attribute.checked(selected),
              attribute.class("page-check"),
              event.on_check(fn(_) { TogglePage(thumb.page) }),
            ]),
            html.img([
              attribute.src(thumb.data_url),
              attribute.alt("ページ " <> int.to_string(thumb.page)),
            ]),
            html.span([attribute.class("page-number")], [
              html.text("p. " <> int.to_string(thumb.page)),
            ]),
          ],
        )
      })
    }),
    html.div([attribute.class("sticky-bar")], [
      html.span([], [
        html.text(
          int.to_string(count)
          <> " / "
          <> int.to_string(info.page_count)
          <> " ページ選択中",
        ),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("primary"),
          attribute.disabled(!can_start(model)),
          event.on_click(case model.mode {
            ByNumber -> BeginLocate
            WholeDocument -> BeginWholeDocument
          }),
        ],
        [
          html.text(case model.mode {
            ByNumber -> "対象曲を探す"
            WholeDocument -> "PDF全体を解析する"
          }),
        ],
      ),
    ]),
  ])
}

fn can_start(model: Model) -> Bool {
  case model.mode {
    ByNumber ->
      !list.is_empty(model.selected)
      && !string.is_empty(string.trim(model.target_input))
    WholeDocument -> !list.is_empty(model.selected)
  }
}

fn input_examples() -> Element(Msg) {
  html.div([attribute.class("input-examples")], [
    html.p([attribute.class("examples-title")], [html.text("入力例")]),
    html.ul([], [
      html.li([], [html.text("32 … No.32 だけを分析")]),
      html.li([], [html.text("32,33 … No.32 と No.33 を別々に分析")]),
      html.li([], [html.text("32-34 … No.32〜34 を別々に分析")]),
      html.li([], [
        html.text("「PDF全体を1曲として」… 選んだ全ページを1つの作品として分析"),
      ]),
      html.li([], [
        html.text("「PDF全体を1曲として」＋曲名 … 曲名つきで分析"),
      ]),
    ]),
    html.p([attribute.class("muted small")], [
      html.text(
        "曲番号が印刷されていない楽譜（写真など）は「PDF全体を1曲として」を使います。"
        <> "1つのPDFに別々の曲が入っている場合は「曲番号で探す」を使ってください。",
      ),
    ]),
  ])
}

fn view_locating(model: Model) -> Element(Msg) {
  html.section([attribute.class("card centered")], [
    html.div([attribute.class("spinner"), attribute.aria_busy(True)], []),
    html.h2([], [html.text("対象曲を探しています")]),
    case model.locate_active {
      Some(page) ->
        html.p([attribute.class("muted")], [
          html.text("ページ " <> int.to_string(page) <> " を確認中…"),
        ])
      None -> html.p([attribute.class("muted")], [html.text("準備中…")])
    },
    html.p([attribute.class("muted small")], [
      html.text("ページ全体の低解像度画像から、曲番号の位置だけを判定します。"),
    ]),
  ])
}

fn view_preparing(model: Model) -> Element(Msg) {
  html.section([attribute.class("card centered")], [
    html.div([attribute.class("spinner"), attribute.aria_busy(True)], []),
    html.h2([], [html.text("ページの段を検出しています")]),
    html.p([attribute.class("progress-text")], [
      html.text(
        int.to_string(model.overview_done)
        <> " / "
        <> int.to_string(model.overview_total)
        <> " ページ完了",
      ),
    ]),
    html.p([attribute.class("muted small")], [
      html.text("選択したページを上から順に確認し、PDF全体を1曲として読み取ります。"),
    ]),
  ])
}

fn view_located(model: Model) -> Element(Msg) {
  let found = found_count(model.targets)
  let has_missing =
    list.any(model.targets, fn(target) {
      case target.status {
        Missing -> True
        _ -> False
      }
    })

  html.section([attribute.class("card")], [
    html.h2([], [html.text("対象曲の位置")]),
    html.p([attribute.class("muted")], [
      html.text("見つかった段だけを高解像度で書き起こします。"),
    ]),
    html.div([attribute.class("target-list")], {
      model.targets
      |> list.map(fn(target) {
        let is_missing = case target.status {
          Missing -> True
          _ -> False
        }
        html.div(
          [
            attribute.class(case is_missing {
              True -> "target-row missing"
              False -> "target-row"
            }),
          ],
          [
            html.strong([], [html.text("No." <> target.number)]),
            html.span([attribute.class("muted")], [
              html.text(case is_missing {
                True -> "このページには見つかりませんでした"
                False -> systems_summary(target)
              }),
            ]),
          ],
        )
      })
    }),
    case has_missing {
      True ->
        html.div([attribute.class("banner banner-warn")], [
          html.p([], [
            html.text("指定した番号の一部が見つかりませんでした。" <> "そのPDFが1つの作品なら、全体をまとめて解析できます。"),
          ]),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("primary"),
              event.on_click(BeginWholeDocument),
            ],
            [html.text("PDF全体を1曲として解析する")],
          ),
        ])
      False -> html.div([attribute.class("hidden")], [])
    },
    html.div([attribute.class("sticky-bar")], [
      html.span([], [
        html.text(int.to_string(found) <> " 曲を書き起こします"),
      ]),
      html.div([attribute.class("button-row")], [
        html.button(
          [attribute.type_("button"), event.on_click(BackToSelecting)],
          [html.text("選択に戻る")],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("primary"),
            attribute.disabled(found == 0),
            event.on_click(BeginTranscription),
          ],
          [html.text("書き起こしを開始")],
        ),
      ]),
    ]),
  ])
}

fn view_transcribing(model: Model) -> Element(Msg) {
  html.section([attribute.class("card centered")], [
    html.div([attribute.class("spinner"), attribute.aria_busy(True)], []),
    html.h2([], [html.text("譜面を書き起こしています")]),
    html.p([attribute.class("progress-text")], [
      html.text(
        int.to_string(model.transcribe_done)
        <> " / "
        <> int.to_string(model.transcribe_total)
        <> " ページ完了",
      ),
    ]),
    case model.transcribe_active {
      Some(pair) -> {
        let #(number, page) = pair
        let subject = case number {
          "ALL" -> "PDF全体"
          _ -> "No." <> number
        }
        html.p([attribute.class("muted")], [
          html.text(subject <> " / ページ " <> int.to_string(page) <> " を解析中…"),
        ])
      }
      None -> html.p([attribute.class("muted")], [html.text("準備中…")])
    },
    html.div([attribute.class("progress")], [
      html.div(
        [
          attribute.class("progress-fill"),
          attribute.style(
            "width",
            progress_percent(model.transcribe_done, model.transcribe_total),
          ),
        ],
        [],
      ),
    ]),
    html.p([attribute.class("muted small")], [
      html.text("対象曲の段ごとに画像を作って送信します。1ページあたり数十秒かかることがあります。"),
    ]),
  ])
}

fn progress_percent(done: Int, total: Int) -> String {
  case total {
    0 -> "0%"
    _ -> int.to_string(done * 100 / total) <> "%"
  }
}

fn view_analyzing(model: Model) -> Element(Msg) {
  html.section([attribute.class("card centered")], [
    html.div([attribute.class("spinner"), attribute.aria_busy(True)], []),
    html.h2([], [html.text("和声を分析しています")]),
    html.p([attribute.class("progress-text")], [
      html.text(
        int.to_string(model.analyze_done)
        <> " / "
        <> int.to_string(model.analyze_total)
        <> " 曲完了",
      ),
    ]),
    case model.active_target {
      Some(number) ->
        html.p([attribute.class("muted")], [
          html.text("No." <> number <> " を分析中…"),
        ])
      None -> html.p([attribute.class("muted")], [html.text("準備中…")])
    },
    html.div([attribute.class("progress")], [
      html.div(
        [
          attribute.class("progress-fill"),
          attribute.style(
            "width",
            progress_percent(model.analyze_done, model.analyze_total),
          ),
        ],
        [],
      ),
    ]),
    html.p([attribute.class("muted small")], [
      html.text(case model.mode {
        ByNumber -> "1曲ごとに quota を1回消費します。失敗した場合は自動で戻ります。"
        WholeDocument -> "1文書で quota を1回消費します。失敗した場合は自動で戻ります。"
      }),
    ]),
  ])
}

fn view_done(model: Model) -> Element(Msg) {
  html.section([attribute.class("result")], [
    html.div([attribute.class("result-head")], [
      html.div([], [
        html.h2([], [html.text("和声分析")]),
        html.p([attribute.class("muted")], [
          html.text(case model.mode {
            ByNumber -> "番号ごとに結果を表示しています。"
            WholeDocument -> "選択したページ全体を1つの作品として分析しています。"
          }),
        ]),
      ]),
      html.div([attribute.class("button-row")], [
        html.button([attribute.type_("button"), event.on_click(Print)], [
          html.text("印刷"),
        ]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("primary"),
            event.on_click(Reset),
          ],
          [html.text("別のPDFを分析")],
        ),
      ]),
    ]),
    ..list.map(model.targets, fn(target) { view_target_result(target) })
  ])
}

fn view_target_result(target: Target) -> Element(Msg) {
  case target.status {
    Missing ->
      html.div([attribute.class("target-warning")], [
        html.strong([], [html.text(target.label)]),
        html.span([], [html.text(" は見つかりませんでした。")]),
      ])
    FailedTarget ->
      html.div([attribute.class("target-warning")], [
        html.strong([], [html.text(target.label)]),
        html.span([], [html.text(" の分析に失敗しました: " <> target.error)]),
      ])
    QuotaExceeded ->
      html.div([attribute.class("target-warning")], [
        html.strong([], [html.text(target.label)]),
        html.span([], [html.text(" は quota 不足のため未分析です。")]),
      ])
    TargetDone ->
      case target.analysis {
        Some(analysis) ->
          html.div([attribute.class("target-result")], [
            html.h2([], [html.text(target.label)]),
            view_analysis(analysis),
          ])
        None -> html.div([], [])
      }
    _ -> html.div([], [])
  }
}

fn view_analysis(analysis: shared.Analysis) -> Element(Msg) {
  html.div([attribute.class("analysis-body")], [
    case analysis.meta.mock {
      True ->
        html.div([attribute.class("banner banner-mock")], [
          html.text("モックモードの結果です。モデル API キーを設定すると実際の解析に切り替わります。"),
        ])
      False -> html.div([attribute.class("hidden")], [])
    },
    html.div([attribute.class("meta-grid")], [
      meta_card("調性", analysis.meta.key),
      meta_card("拍子", analysis.meta.meter),
      meta_card("形式", analysis.meta.form),
      meta_card("自信度", analysis.meta.confidence),
    ]),
    html.div([attribute.class("table-wrap")], [
      html.table([attribute.class("harmony-table")], [
        html.thead([], [
          html.tr([], [
            th("小節"),
            th("拍"),
            th("和音"),
            th("機能"),
            th("構成音"),
            th("メモ"),
          ]),
        ]),
        html.tbody([], {
          analysis.table
          |> list.map(fn(row) {
            html.tr([], [
              td(row.bar),
              td(row.beat),
              td(row.chord),
              td(row.function),
              td(row.notes),
              td(row.comment),
            ])
          })
        }),
      ]),
    ]),
    html.article([attribute.class("prose")], [
      html.h3([], [html.text("分析")]),
      ..prose_paragraphs(analysis.prose)
    ]),
  ])
}

fn meta_card(label: String, value: String) -> Element(Msg) {
  let shown = case value {
    "" -> "—"
    _ -> value
  }
  html.div([attribute.class("meta-card")], [
    html.span([attribute.class("meta-label")], [html.text(label)]),
    html.strong([], [html.text(shown)]),
  ])
}

fn th(label: String) -> Element(Msg) {
  html.th([attribute.scope("col")], [html.text(label)])
}

fn td(value: String) -> Element(Msg) {
  html.td([], [html.text(value)])
}

fn prose_paragraphs(prose: String) -> List(Element(Msg)) {
  prose
  |> string.split("\n")
  |> list.filter(fn(line) { !string.is_empty(string.trim(line)) })
  |> list.map(fn(line) { html.p([], [html.text(string.trim(line))]) })
}

fn view_failed(model: Model) -> Element(Msg) {
  html.section([attribute.class("card centered")], [
    html.h2([], [html.text("処理を続けられませんでした")]),
    html.p([attribute.class("muted")], [
      html.text(case model.error {
        "" -> "不明なエラーが発生しました。"
        message -> message
      }),
    ]),
    case model.info, model.selected {
      Some(_), [_page, ..] ->
        html.div([attribute.class("button-row center")], [
          html.button([attribute.type_("button"), event.on_click(Reset)], [
            html.text("最初からやり直す"),
          ]),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("primary"),
              event.on_click(BeginWholeDocument),
            ],
            [html.text("PDF全体を1曲として解析する")],
          ),
        ])
      _, _ ->
        html.div([attribute.class("button-row center")], [
          html.button([attribute.type_("button"), event.on_click(Reset)], [
            html.text("最初からやり直す"),
          ]),
        ])
    },
  ])
}

// APP -------------------------------------------------------------------------

pub fn main() {
  let app =
    lustre.application(
      init: fn(_) { #(initial_model(), effect.none()) },
      update:,
      view:,
    )

  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
