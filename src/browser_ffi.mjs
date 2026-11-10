// Browser glue: pdf.js rendering and same-origin API calls.
// The application state machine and all rendering live in Gleam/Lustre.

import * as pdfjs from "pdfjs-dist";
import { Result$Ok as Ok, Result$Error as GleamError } from "./gleam.mjs";

pdfjs.GlobalWorkerOptions.workerSrc = "/pdf.worker.min.mjs";

const MAX_FILE_BYTES = 40 * 1024 * 1024;
const THUMB_WIDTH = 150;
const PAGE_WIDTH = 2000;
const OVERVIEW_WIDTH = 1500;

let pdfDocument = null;
let pdfName = "";
let pdfId = "";
let systemCache = { page: null, boxes: [], width: 0, height: 0 };

function failure(error) {
  const message =
    error && error.message ? error.message : String(error ?? "unknown error");
  return GleamError(message);
}

function fileInput() {
  return document.getElementById("pdf-input");
}

async function renderToCanvas(page, targetWidth) {
  const base = page.getViewport({ scale: 1 });
  const scale = Math.max(0.2, Math.min(4, targetWidth / base.width));
  const viewport = page.getViewport({ scale });

  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.floor(viewport.width));
  canvas.height = Math.max(1, Math.floor(viewport.height));

  const context = canvas.getContext("2d", { alpha: false });
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);

  await page.render({ canvasContext: context, canvas, viewport }).promise;
  return canvas;
}

async function renderToDataUrl(page, targetWidth, quality) {
  const canvas = await renderToCanvas(page, targetWidth);
  return canvas.toDataURL("image/jpeg", quality);
}

export async function load_pdf() {
  try {
    const input = fileInput();
    const file = input?.files?.[0];
    if (!file) {
      return failure("PDF ファイルを選択してください");
    }
    if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) {
      return failure("PDF ファイルを選択してください");
    }
    if (file.size > MAX_FILE_BYTES) {
      return failure("PDF が大きすぎます（40MB まで）");
    }

    if (pdfDocument) {
      try {
        await pdfDocument.destroy();
      } catch (_) {
        // ignore
      }
      pdfDocument = null;
    }

    const data = new Uint8Array(await file.arrayBuffer());
    const task = pdfjs.getDocument({
      data,
      isEvalSupported: false,
      useSystemFonts: true,
    });
    pdfDocument = await task.promise;
    pdfId = crypto.randomUUID();
    pdfName = file.name;

    const thumbs = [];
    for (let pageNumber = 1; pageNumber <= pdfDocument.numPages; pageNumber += 1) {
      const page = await pdfDocument.getPage(pageNumber);
      const dataUrl = await renderToDataUrl(page, THUMB_WIDTH, 0.62);
      page.cleanup();
      thumbs.push({ page: pageNumber, data_url: dataUrl });
    }

    return Ok(
      JSON.stringify({
        doc_id: pdfId,
        name: pdfName,
        page_count: pdfDocument.numPages,
        thumbs,
      }),
    );
  } catch (error) {
    return failure(error);
  }
}

export async function render_page(pageNumber) {
  try {
    if (!pdfDocument) {
      return failure("PDF が読み込まれていません");
    }
    const page = await pdfDocument.getPage(pageNumber);
    const dataUrl = await renderToDataUrl(page, PAGE_WIDTH, 0.86);
    page.cleanup();
    return Ok(JSON.stringify({ data_url: dataUrl }));
  } catch (error) {
    return failure(error);
  }
}

function detectByGaps(canvas) {
  const context = canvas.getContext("2d", { willReadFrequently: true });
  const { width, height } = canvas;
  const data = context.getImageData(0, 0, width, height).data;
  const xStart = Math.floor(width * 0.05);
  const xEnd = Math.ceil(width * 0.95);
  const step = 2;
  const rowInk = new Array(height).fill(0);
  for (let y = 0; y < height; y += 1) {
    let count = 0;
    const offset = y * width * 4;
    for (let x = xStart; x < xEnd; x += step) {
      const index = offset + x * 4;
      const luminance =
        0.299 * data[index] + 0.587 * data[index + 1] + 0.114 * data[index + 2];
      if (luminance < 160) count += 1;
    }
    rowInk[y] = count;
  }
  const smoothed = new Array(height).fill(0);
  for (let y = 0; y < height; y += 1) {
    let sum = 0;
    let n = 0;
    for (let k = -2; k <= 2; k += 1) {
      const yy = y + k;
      if (yy >= 0 && yy < height) {
        sum += rowInk[yy];
        n += 1;
      }
    }
    smoothed[y] = sum / n;
  }

  const sampledWidth = Math.ceil((xEnd - xStart) / step);
  const threshold = Math.max(4, Math.floor(sampledWidth * 0.01));
  const minGap = Math.max(8, Math.floor(height * 0.007));
  const minBand = Math.max(12, Math.floor(height * 0.014));
  const maxBand = Math.floor(height * 0.16);

  let bands = [];
  let start = null;
  let gap = 0;
  for (let y = 0; y < height; y += 1) {
    if (smoothed[y] > threshold) {
      if (start === null) start = y;
      gap = 0;
    } else if (start !== null) {
      gap += 1;
      if (gap >= minGap) {
        const end = y - gap;
        if (end - start >= minBand) bands.push([start, end]);
        start = null;
        gap = 0;
      }
    }
  }
  if (start !== null && height - 1 - start >= minBand) {
    bands.push([start, height - 1]);
  }

  const splitBand = ([top, bottom]) => {
    if (bottom - top <= maxBand) return [[top, bottom]];
    let bestStart = -1;
    let bestLen = 0;
    let currentStart = -1;
    for (let y = top + 5; y < bottom - 5; y += 1) {
      if (smoothed[y] <= threshold) {
        if (currentStart < 0) currentStart = y;
      } else if (currentStart >= 0) {
        const length = y - currentStart;
        if (length > bestLen) {
          bestLen = length;
          bestStart = currentStart;
        }
        currentStart = -1;
      }
    }
    if (bestStart < 0 || bestLen < 4) {
      const middle = Math.floor((top + bottom) / 2);
      return [...splitBand([top, middle]), ...splitBand([middle + 1, bottom])];
    }
    const middle = bestStart + Math.floor(bestLen / 2);
    return [...splitBand([top, middle]), ...splitBand([middle + 1, bottom])];
  };

  bands = bands.flatMap(splitBand);

  const boxes = bands
    .filter(([top, bottom]) => {
      if (top > height * 0.955) return false;
      return bottom - top >= minBand;
    })
    .map(([top, bottom]) => [
      Math.max(0, top - Math.floor(height * 0.012)),
      Math.min(height - 1, bottom + Math.floor(height * 0.015)),
    ])
    .sort((a, b) => a[0] - b[0]);

  // Avoid including the beginning of the next system in a crop.
  for (let index = 0; index + 1 < boxes.length; index += 1) {
    if (boxes[index][1] >= boxes[index + 1][0]) {
      const middle = Math.floor((boxes[index][1] + boxes[index + 1][0]) / 2);
      boxes[index][1] = middle;
      boxes[index + 1][0] = middle + 1;
    }
  }
  return boxes;
}

function detectSystemBoxes(canvas) {
  // Row-ink projection: split the page at horizontal whitespace between
  // systems. This is more robust than 5-line staff detection on scanned PDFs.
  return detectByGaps(canvas);
}

function drawSystemOverlay(canvas, boxes) {
  const context = canvas.getContext("2d");
  context.save();
  context.lineWidth = 3;
  context.strokeStyle = "rgba(47, 93, 80, 0.55)";
  context.fillStyle = "rgba(47, 93, 80, 0.16)";
  context.font = "bold 22px sans-serif";
  context.textBaseline = "top";

  boxes.forEach(([top, bottom], index) => {
    const height = bottom - top;
    context.fillRect(4, top, canvas.width - 8, height);
    context.strokeRect(4, top, canvas.width - 8, height);

    const badge = String(index + 1);
    const badgeWidth = 30;
    const badgeHeight = 28;
    const badgeY = Math.max(2, top + 4);
    context.fillStyle = "#2f5d50";
    context.fillRect(4, badgeY, badgeWidth, badgeHeight);
    context.fillStyle = "#ffffff";
    context.fillText(badge, 12, badgeY + 3);
    context.fillStyle = "rgba(47, 93, 80, 0.16)";
  });
  context.restore();
}

export async function render_page_overview(pageNumber) {
  try {
    if (!pdfDocument) {
      return failure("PDF が読み込まれていません");
    }
    const page = await pdfDocument.getPage(pageNumber);
    const canvas = await renderToCanvas(page, OVERVIEW_WIDTH);
    page.cleanup();

    const boxes = detectSystemBoxes(canvas);
    drawSystemOverlay(canvas, boxes);
    systemCache = {
      page: pageNumber,
      boxes,
      width: canvas.width,
      height: canvas.height,
    };

    return Ok(
      JSON.stringify({
        data_url: canvas.toDataURL("image/jpeg", 0.86),
        system_count: boxes.length,
      }),
    );
  } catch (error) {
    return failure(error);
  }
}

export async function render_system_crops(pageNumber, number, indices, bars) {
  try {
    if (!pdfDocument) {
      return failure("PDF が読み込まれていません");
    }
    if (systemCache.page !== pageNumber) {
      const page = await pdfDocument.getPage(pageNumber);
      const overview = await renderToCanvas(page, OVERVIEW_WIDTH);
      page.cleanup();
      systemCache = {
        page: pageNumber,
        boxes: detectSystemBoxes(overview),
        width: overview.width,
        height: overview.height,
      };
    }

    const page = await pdfDocument.getPage(pageNumber);
    const source = await renderToCanvas(page, PAGE_WIDTH);
    page.cleanup();

    const scale = source.height / systemCache.height;
    const parts = [];
    const selected = Array.isArray(indices)
      ? indices
      : indices && typeof indices.toArray === "function"
        ? indices.toArray()
        : [];
    const valid = selected
      .map((value) => Number(value))
      .filter((value) => Number.isInteger(value) && value >= 1 && value <= systemCache.boxes.length);
    const unique = [...new Set(valid)];
    const barCounts = Array.isArray(bars)
      ? bars
      : bars && typeof bars.toArray === "function"
        ? bars.toArray()
        : [];

    let cumulativeBars = 0;
    for (let position = 0; position < unique.length; position += 1) {
      const index = unique[position];
      const barCount = Math.max(0, Number(barCounts[position] ?? 0));
      const [top, bottom] = systemCache.boxes[index - 1];
      const sourceTop = Math.max(0, Math.floor(top * scale));
      const sourceBottom = Math.min(source.height, Math.ceil(bottom * scale));
      const height = Math.max(20, sourceBottom - sourceTop);

      // Send one full system per request. The row is cut from the page at
      // native page resolution, so a single tile keeps the same pixels per bar
      // as a left/right split while avoiding duplicated bars, doubled requests
      // and bar-number drift between overlapping crops.
      let barRange = "";
      if (barCount > 0) {
        const startBar = cumulativeBars + 1;
        const endBar = cumulativeBars + barCount;
        barRange =
          startBar === endBar
            ? `小節${startBar}`
            : `小節${startBar}-${endBar}`;
      }

      const canvas = document.createElement("canvas");
      canvas.width = source.width;
      canvas.height = height;
      const context = canvas.getContext("2d", { alpha: false });
      context.fillStyle = "#ffffff";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.drawImage(
        source,
        0,
        sourceTop,
        source.width,
        height,
        0,
        0,
        source.width,
        height,
      );

      const category = barRange === "" ? `段${index}` : `段${index} / ${barRange}`;
      parts.push({
        label: `No.${number} / ${category}`,
        data_url: canvas.toDataURL("image/jpeg", 0.9),
      });

      cumulativeBars += barCount;
    }

    return Ok(JSON.stringify({ parts }));
  } catch (error) {
    return failure(error);
  }
}

export async function render_page_parts(pageNumber) {
  try {
    if (!pdfDocument) {
      return failure("PDF が読み込まれていません");
    }
    const page = await pdfDocument.getPage(pageNumber);
    const source = await renderToCanvas(page, PAGE_WIDTH);
    page.cleanup();

    // Split the page into overlapping tiles so that each tile keeps enough
    // resolution after the model provider's image downscaling.
    const cols = 2;
    const rows = 3;
    const overlap = 0.05;
    const cellWidth = source.width / cols;
    const cellHeight = source.height / rows;
    const tileWidth = Math.ceil(cellWidth * (1 + overlap));
    const tileHeight = Math.ceil(cellHeight * (1 + overlap));
    const rowLabels = ["上段", "中段", "下段"];
    const colLabels = ["左", "右"];

    const parts = [];
    for (let row = 0; row < rows; row += 1) {
      for (let col = 0; col < cols; col += 1) {
        const offsetX = (tileWidth - cellWidth) / 2;
        const offsetY = (tileHeight - cellHeight) / 2;
        const sx = Math.max(
          0,
          Math.min(source.width - tileWidth, Math.floor(col * cellWidth - offsetX)),
        );
        const sy = Math.max(
          0,
          Math.min(source.height - tileHeight, Math.floor(row * cellHeight - offsetY)),
        );

        const tile = document.createElement("canvas");
        tile.width = tileWidth;
        tile.height = tileHeight;
        const context = tile.getContext("2d", { alpha: false });
        context.fillStyle = "#ffffff";
        context.fillRect(0, 0, tile.width, tile.height);
        context.drawImage(
          source,
          sx,
          sy,
          tileWidth,
          tileHeight,
          0,
          0,
          tileWidth,
          tileHeight,
        );

        parts.push({
          label: `${rowLabels[row]}・${colLabels[col]}`,
          data_url: tile.toDataURL("image/jpeg", 0.9),
        });
      }
    }

    return Ok(JSON.stringify({ parts }));
  } catch (error) {
    return failure(error);
  }
}

export function reset_pdf() {
  try {
    pdfDocument?.destroy();
  } catch (_) {
    // ignore
  }
  pdfDocument = null;
  pdfId = "";
  pdfName = "";
  const input = fileInput();
  if (input) {
    input.value = "";
  }
  return undefined;
}

export function print_page() {
  window.print();
  return undefined;
}

async function requestJson(path, options) {
  try {
    const response = await fetch(path, {
      credentials: "same-origin",
      ...options,
    });
    const body = await response.text();
    let error = "";
    if (!response.ok) {
      try {
        const parsed = JSON.parse(body);
        error = typeof parsed.error === "string" ? parsed.error : "";
      } catch (_) {
        error = body;
      }
      if (error === "") {
        error = `HTTP ${response.status}`;
      }
    }
    return Ok(
      JSON.stringify({
        ok: response.ok,
        status: response.status,
        body: response.ok ? body : "",
        error,
      }),
    );
  } catch (error) {
    return failure(error);
  }
}

export function api_get(path) {
  return requestJson(path, { method: "GET" });
}

export function api_post(path, body) {
  return requestJson(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
}
