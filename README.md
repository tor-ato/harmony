# Harmony

[![test](https://github.com/tor-ato/harmony/actions/workflows/test.yml/badge.svg)](https://github.com/tor-ato/harmony/actions/workflows/test.yml)

印刷された楽譜の PDF をアップロードし、**曲番号を指定する**か **PDF 全体を 1 曲として指定する**と、**和声表と日本語の分析**を返す friends-only の Web アプリです。

- バックエンド: **Gleam**（Cloudflare Worker）
- フロントエンド: **Gleam + Lustre**（SPA）
- インフラ: **Cloudflare Workers + Static Assets + D1 + Access**
- 書き起こし: **Gemini 4 Argon**（ vision / OpenCode Go）
- 和声分析・日本語文: **DeepSeek V4.1 Flash**
- 固定インフラ費: **¥0**（Cloudflare 無料枠。モデル利用分のみ従量課金）

公開先: <https://harmony.torato.workers.dev>（Cloudflare Access で許可されたアカウントのみ）

## できること

1. 楽譜 PDF を選び、分析したいページを手動で選択
2. 解析モードを選ぶ
   - **曲番号で探す**: `32` / `32,33` / `32-34` など
   - **PDF 全体を 1 曲として**: 曲名は任意（空欄でも可）
3. 各ページの段（system）を自動検出し、高解像度でクロップ
4. 1 ページ分の全段を **1 回のリクエスト**で書き起こし（複数画像をまとめて送信）
5. 書き起こし完了後、自動で和声分析へ
6. **和声表 + 日本語の分析文** を表示（印刷可）

曲番号モードで複数番号を指定した場合は、結果を番号ごとに分けて表示します。見つからなかった番号はエラーにせず警告として扱い、quota も消費しません。

### 2 つの解析モード

| モード | 入力 | 対象 | quota |
| --- | --- | --- | --- |
| 曲番号で探す | `32` / `32,33` / `32-34` | 印刷された番号の曲 | 見つかった番号ごとに 1 |
| PDF 全体を 1 曲として | 曲名（任意） | 選択した全ページ | **1 文書 = 1**（8 ページでも 1） |

入力例:

```text
32                  → No.32 だけを分析
32,33               → No.32 と No.33 を別々に分析
32-34               → No.32〜34 を別々に分析
（PDF全体モード）     → 選んだ全ページを 1 つの作品として分析
（PDF全体モード＋曲名）→ 曲名つきで分析
```

曲番号が印刷されていない楽譜（写真など）は「PDF 全体を 1 曲として」を使います。1 つの PDF に別々の曲が入っている場合は「曲番号で探す」を使ってください。

曲番号モードで番号が見つからない場合は、自動で全体モードに切り替えず、**「PDF 全体を 1 曲として解析する」ボタン**を表示します。押したときだけ全体モードで解析します。

### 小節番号の扱い

- 曲番号モード: ロケートで得た段ごとの小節数から、曲全体の通し番号を振ります。
- PDF 全体モード（1 ページ文書）: 最初の段の 1 小節目を 1 として、段をまたいで通し番号にします。
- PDF 全体モード（複数ページ文書）: 偽の通し番号は作らず、`p3-7`（3 ページの 7 小節目）の形式で参照します。

## 仕組み

```text
ブラウザ
  PDF 選択 → ページ選択（手動）

  [曲番号で探す]
    曲番号を入力 → pdf.js でページ全体を低解像度 JPEG 化
      └─ POST /api/locate
           └─ 段番号付きのページ画像から、各 No. の段を判定
    見つかった番号だけ、対象段を高解像度クロップ
      └─ POST /api/transcribe（番号・ページ単位。1ページの全段を1リクエスト）
           └─ JSON で書き起こし → D1 に保存
    書き起こし完了後、自動で分析
      └─ POST /api/finalize（番号ごとに1回）
           ├─ 月次 quota を原子的に予約
           ├─ DeepSeek にテキストだけを送り、和声 JSON + 日本語文を生成
           └─ 失敗時は quota を戻す
    番号ごとに和声表 + 分析文を表示（結果は保存しない）

  [PDF全体を1曲として]
    曲名（任意）を入力
      └─ 各ページの段をクライアント側で検出
      └─ POST /api/transcribe（ページ単位、最大3ページ並列）
           └─ 1ページの全段を1回のリクエストで書き起こし
      └─ ページ順に結合
      └─ POST /api/finalize（文書全体で1回）
           └─ 1文書 = quota 1
    1つの作品として和声表 + 分析文を表示
```

### 書き起こし

- 段はページのインク量の投影（行方向の隙間）から検出します。五線検出は使いません。
- 対象段は 1 段 = 1 枚で切り出します。ページと同じ 2000px 幅で切り出すため、1 小節あたりの画素数は左右分割と変わりません。分割しないことで、重複した小節の統合やクロップ間の小節番号のズレを避けられます。
- 1 ページ分の全段を **1 回のモデル呼び出し**にまとめて送ります。ページ内の段を同時に見ることで、曲全体の整合性（反復・転調・同じ旋律の再現）を取りやすくなります。
- 曲番号モードのラベルには**全体の小節番号**（例: `小節1-8`）を付けます。PDF 全体モードでは `p3 / 段2` のようにページと段だけを付け、小節番号はモデルに数えさせます。
- 出力は次の JSON に固定します。

  ```json
  {
    "key": "ヘ長調 / F major",
    "meter": "3/4",
    "bars": [
      {
        "bar": "1",
        "beat": "1",
        "chord": "G7/D",
        "notes": "D3-F5",
        "comment": "p、右手に付点四分音符のF5"
      }
    ],
    "melody": "…",
    "rhythm": "…",
    "uncertain": ["…"]
  }
  ```

- 重複した小節は、最終分析でグローバルな小節番号を使って統合します。

### 分析

- 画像は分析モデルに送らず、**書き起こしテキストだけ**を送ります。
- 出力は「和声表（小節・拍・和音・構成音・備考）」と「調性・拍子・形式・和声進行・特徴」の日本語文です。
- モデルの推論（reasoning）は無効化しています。視覚モデルが推論だけでトークンを使い切るのを避けるためです。

## 料金とプライバシー

- Cloudflare の固定費は ¥0（無料枠）。かかるのはモデル利用分だけです。
- 画像はモデルに送るだけで、D1 には保存しません。
- D1 に残るのは **月次利用回数** と **ページ・曲番号ごとの書き起こしテキスト** だけです。PDF・ページ画像・最終結果は保存しません。
- 書き起こしが不要になったら削除できます。

  ```sh
  npx wrangler d1 execute harmony --remote \
    --command "DELETE FROM transcriptions WHERE doc_id = '...';"
  ```

## ローカル開発

必要なもの: **Gleam 1.19+**、**Bun**、**Node.js 20+**。

```sh
bun install
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply harmony --local
npm run build
npm run dev          # http://127.0.0.1:8787
```

`.dev.vars` の `DEV_EMAIL` を設定すると Access をバイパスします（ローカル専用）。`MOCK_LLM=true` ではモデルを呼ばず、決まったモック結果を返します。

```dotenv
ALLOWED_EMAILS=you@example.com,friend@example.com
DEV_EMAIL=you@example.com
MOCK_LLM=true
# 実モデルを使う場合:
# MOCK_LLM=false
# DEEPSEEK_API_KEY=...
```

### ビルド

```sh
npm run build:worker   # gleam build（Worker 用）
npm run build:ui       # Bun で Lustre SPA を dist/ にバンドル + pdf.worker を配置
npm run build          # 上記 2 つ
```

- `dist/` が Worker の Static Assets として配信されます。
- UI の JS は内容ハッシュ付きのファイル名（`app_entry.<hash>.js`）で出力されます。デプロイ後に古いバンドルが配信され続けるのを防ぐためです。
- `src/index.js` は Gleam の `api.mjs` を呼ぶだけの薄い入口です。

### テスト

```sh
gleam test                 # デコーダ・許可リスト・プロンプトなど
gleam format --check src test
```

ブラウザ E2E（要 `npx playwright install chromium`、ローカル D1 + `MOCK_LLM=true`）:

```sh
node scripts/e2e.mjs "/path/to/score.pdf"
```

E2E は実際に 1 回分の quota を消費します。ローカルで戻すには:

```sh
npx wrangler d1 execute harmony --local \
  --command "UPDATE usage_month SET used = 0;"
```

CI（GitHub Actions）では Gleam のテスト・フォーマットチェック・ビルドを実行します。E2E は実行しません。

## Cloudflare へのデプロイ

### 1. D1 を作成

```sh
npx wrangler d1 create harmony
```

表示された `database_id` を `wrangler.jsonc` の `d1_databases[0].database_id` に貼り替え、マイグレーションを適用します。

```sh
npx wrangler d1 migrations apply harmony --remote
```

### 2. デプロイ

```sh
npm run deploy
```

`https://harmony.<your-subdomain>.workers.dev` が払い出されます。

`npm run deploy` は `wrangler deploy` のあと、アップロードしたバージョンを明示的に 100% へ昇格します（`scripts/deploy.mjs`）。Cloudflare 側で `workers.dev` のルートが古いバージョンを向いたままになることがあるためです。昇格が反映待ちで失敗した場合は、5 秒間隔で最大 6 回リトライします。

### 3. Cloudflare Access を設定

Zero Trust ダッシュボード → **Access → Applications → Add an application → Self-hosted**。

- Application domain: `harmony.<your-subdomain>.workers.dev`
- Session duration: 任意（例: 24 hours）
- Policy: **Allow**
  - Include → Emails → 許可したいメールアドレス（複数なら Include ルールを分けて追加）
- Login method: One-time PIN（メール OTP）

Application の **Application Audience (AUD) Tag** と、チームドメイン（例: `yourteam.cloudflareaccess.com`）を控え、`wrangler.jsonc` の vars を更新します。

```jsonc
"POLICY_AUD": "<Application AUD Tag>",
"TEAM_DOMAIN": "yourteam.cloudflareaccess.com"
```

> `TEAM_DOMAIN` はスキームなしのホスト名です。Worker は `https://<TEAM_DOMAIN>/cdn-cgi/access/certs` から JWKS を取得し、`Cf-Access-Jwt-Assertion` の RS256 署名・`aud`・`iss`・`exp` を検証します。許可メールのリストは Secret `ALLOWED_EMAILS`（カンマ区切り）で渡します。

#### 自動で設定する場合

次の権限を付けた Cloudflare API トークンを作成します。

- Account → **Access: Apps and Policies** → Edit
- Account → **Access: Organizations, Identity Providers, and Groups** → Edit

トークンを `.cf-api-token` に保存し、スクリプトを実行します（Zero Trust 組織が無ければ作成し、アプリと許可ポリシーまで作ります）。

```sh
printf '%s' 'YOUR_TOKEN' > .cf-api-token
chmod 600 .cf-api-token
ALLOWED_EMAILS='you@example.com,friend@example.com' npm run setup:access -- --deploy
```

`setup:access` は `ALLOWED_EMAILS` のアドレスで Access の Allow ポリシーを作ります。

### 4. Secret を設定

許可するメールアドレスをカンマ区切りで登録します。ここに含まれないアカウントは、Access を通っても Worker 側で拒否されます。

```sh
printf '%s' 'you@example.com,friend@example.com' | npx wrangler secret put ALLOWED_EMAILS
```

続いて、モデルの API キーを設定します。OpenCode Console（<https://opencode.ai/console>）で API キーを発行します。モデル利用は次のどちらかです。

- **OpenCode Go**（$10/月、月間の含み利用枠あり）
- **プリペイドクレジット**（$10 から、使った分だけ）

Go を使う場合は、Console の **Settings → Privacy → Regions** で **Global** を有効にしてください（DeepSeek V4.1 Flash は既定の Europe/US 制限の対象です）。

```sh
npx wrangler secret put DEEPSEEK_API_KEY
```

### 5. 再デプロイ

```sh
npm run deploy
```

Access のログイン画面が出て、許可したアカウントだけがアプリに入れることを確認してください。

## 設定

`wrangler.jsonc` の vars（または Secrets）で変更できます。

| 設定 | 既定値 | 説明 |
| --- | --- | --- |
| `MONTHLY_LIMIT` | `10` | 月の分析回数の上限（許可ユーザー合計） |
| `TRANSCRIBE_MODEL` | `gemini-4-argon` | 書き起こし（vision）モデル |
| `TRANSCRIBE_BASE_URL` | `https://opencode.ai/inference/go/openai/v1` | 書き起こし API のベース URL |
| `DEEPSEEK_MODEL` | `deepseek-v4.1-flash` | 和声分析モデル |
| `DEEPSEEK_BASE_URL` | `https://opencode.ai/inference/go/openai/v1` | 分析 API のベース URL（従量課金は `/inference/openai/v1`） |
| `MOCK_LLM` | `false` | `true` でモデルを呼ばずモックを返す |
| `DEV_EMAIL` | なし | ローカル専用の認証バイパス。本番では設定しない |
| `ALLOWED_EMAILS` | — | 許可メール（カンマ区切り、Secret 推奨） |
| `POLICY_AUD` | — | Access Application の AUD Tag |
| `TEAM_DOMAIN` | — | Access のチームドメイン |

- **quota**: `usage_month(month PRIMARY KEY, used)` に対する条件付き UPSERT で予約します。JST の月でカウントし、曲番号モードは **番号ごとに 1 回**、PDF 全体モードは **1 文書 = 1 回**消費します。LLM 呼び出しが失敗した場合は同じ月の `used` を 1 戻します。
- **対象曲**: 曲番号モードでは、ユーザーが指定した番号をロケートで探し、見つかった番号だけを書き起こします。見つからない番号は警告として表示し、1 つも見つからない場合は quota を消費せず停止します（全体モードへの切替ボタンを表示）。
- **PDF 全体モード**: ロケートを行わず、選択した各ページの段をクライアント側で検出します。ページ単位の書き起こしを最大 3 ページ並列で実行し、ページ順に結合して 1 回だけ分析します。
- **段クロップ**: ページを横方向のインク量で段に分割し、対象段を高解像度で切り出します（1 段 = 1 枚、ページ幅 2000px のまま）。

### 制限

| 項目 | 上限 |
| --- | --- |
| PDF サイズ | 40MB |
| ロケート画像 | 4,000,000 文字（base64 換算） |
| 1 リクエストの画像合計 | 8,000,000 文字 |
| 1 リクエストのパーツ数 | 12 |
| 対象番号 | 20 |
| finalize の書き起こし | 200,000 文字 |

## API

すべて Cloudflare Access の JWT が必要です（`/api/health` を除く）。

| メソッド | パス | 用途 |
| --- | --- | --- |
| `GET` | `/api/health` | ヘルスチェック（バージョン表示） |
| `GET` | `/api/quota` | 当月の利用回数 |
| `POST` | `/api/locate` | ページ画像から曲番号の段を検出 |
| `POST` | `/api/transcribe` | ページ単位の書き起こし（1 ページの全段をまとめて送信） |
| `POST` | `/api/finalize` | 和声分析（曲番号ごと / 文書ごとに quota を 1 回消費） |

## 構成

```text
src/
  index.js             Worker 入口（Gleam を呼ぶだけ）
  api.gleam            ルーティング・認証・quota・ロケート・検証
  auth.gleam           Access JWT 検証 + メール許可リスト（ALLOWED_EMAILS）
  db.gleam             D1 quota / 書き起こし
  llm.gleam            モデル呼び出し（複数画像の vision + テキスト、並列処理）
  prompts.gleam        ロケート / 書き起こし / 分析プロンプト
  shared.gleam         型・JSON デコーダ
  app.gleam            Lustre SPA（状態機械・画面）
  browser_ffi.mjs      pdf.js / fetch / クロップ / 印刷
  worker_api_ffi.mjs   Workers ランタイム
  auth_ffi.mjs         WebCrypto JWT 検証
  d1_ffi.mjs           D1
  llm_ffi.mjs          HTTP
migrations/
  0001_init.sql
  0002_piece.sql
scripts/
  build-ui.mjs         Bun バンドル + index.html（ハッシュ付きファイル名）
  deploy.mjs           deploy + 最新バージョンの昇格
  e2e.mjs              Playwright スモークテスト
  setup-access.mjs     Access アプリ / OTP ポリシーの自動作成
wrangler.jsonc
```

## 既知の制約

- 1 段を 1 枚で送るため、段の端（最初・最後の小節）は画像の切れ目に近くなります。端で切れた音は「切れ」として扱われ、推定で補いません。
- 書き起こしは完全ではありません。特に小節の端で切れた音、調号・拍子記号がクロップ外になる場合は推定が入ります。
- 分析結果は保存しません。同じ PDF でも再実行には quota が必要です。
- ページ選択は手動です。曲番号からの自動ページ探索はしません。
- PDF 全体モードは「選択したページ＝1 作品」とみなします。複数の曲が入った歌曲集などで使うと、別々の曲が 1 曲として混ざります。
- PDF 全体モード（複数ページ）の小節参照は `p3-7` 形式です。ページをまたいだ通し番号は作りません。
- 1 ページの段数が 12 を超える場合は、書き起こしリクエストを 12 段ずつに分割します（その場合、小節番号がチャンクごとに振り直されることがあります）。
