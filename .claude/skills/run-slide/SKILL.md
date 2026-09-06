---
name: run-slide
description: Marpスライドを構成・PDF化する。「スライド作って」「プレゼン作成」「スライド化して」で発動。
user-invocable: true
argument-hint: "[topic | URL | file path]"
---

# Marp Slide Composer

ユーザーのコンテキスト（テキスト、URL、議事録、アイデア等）からスライドを構成・設計し、
`build-slide/build.js` でPDFを生成するオーケストレーター。

**Prerequisites**: `marp` (`npm i -g @marp-team/marp-cli`) と `pdftoppm` (`brew install poppler`) が PATH にあること。

## Input / Output

- **Input**: ユーザーのコンテキスト（テキスト、URL、ファイル、議事録、アイデア等）
- **Output**: `output/{name}-slide.pdf`（最終スライドPDF）+ `output/{name}-slide.json`（スライド定義）

```
Phase 0: コンテキスト収集
Phase 1: 構成設計
  N ≤ 20 → assign-slide-generator 単一 [context:fork]
  N > 20 → セクション分割 → 並列Agent(子) → assign-slide-generator(孫) → 統合
Phase 2: 構成レビュー → subagent
Phase 3: 生成 → レンダリング → レビュー → 修正ループ
```

---

## Phase 0: コンテキスト収集

**→ 詳細手順は `context-collection-guide.md` を読むこと**（URL処理、混合入力の構造化、WebFetch制限等）

ユーザー入力を `output/{name}-source.md` に統合する。

| 入力タイプ | 手順概要 |
|-----------|---------|
| URL | curl で生HTML取得 → 画像抽出・DL → Markdown化（curl 優先、WebFetch は補助のみ） |
| ファイル | Read → source.md にコピー |
| テキスト | そのまま source.md に保存 |
| 混合 | 素材一覧化 → 各取得 → 統合・重複排除 → ギャップ補完 → source.md |

**出力**: `output/{name}-source.md`（Chars は `wc -m` で計測して記載）

---

## Phase 1: 構成設計（assign-slide-generator に委譲）

### 1-1. ソース品質チェック

**→ 詳細チェックリストは `context-collection-guide.md` の「ソース品質チェック」を参照**

- 文字数が妥当か（ブログ3000+、論文10000+）。不足なら Phase 0 やり直し

### 1-2. 枚数見積もり

```bash
node .claude/skills/run-slide/scripts/estimate-slides.js output/{name}-source.md [density]
```

density: compact(×0.7) / standard(×1.0) / detailed(×1.3) / rich(×1.6)
出力は `slides`（推奨値）と `range`（[min, max]）。
**→ density 選択基準・isLow 時の対応は `context-collection-guide.md` の「density 選択ガイド」を参照**

### 1-3. テーマ選択

| テーマ | 場面 |
|--------|------|
| `kanso` | 汎用（デフォルト） |
| `prisma` | クリエイティブ |
| `abyss` | 技術・ダークUI |
| `tabula` | ビジネス |
| `sumi` | 知的・アカデミック |

### 1-4. assign-slide-generator 呼び出し

generator は context JSON path を単一引数で受ける単一契約。枚数 N に応じて設計フローを分岐する。

#### A. N ≤ 20 の場合（単一設計）

**Skill 呼び出し契約（重要）**: `assign-slide-generator` は `context: fork` で別コンテキスト実行されるため、相対パスは cwd 不一致で解決失敗する可能性がある。**args には必ず絶対パスを渡す**こと。`echo "CONTEXT:..."` で context JSON のパスを stdout にリレーする。

context JSON を書き出し、絶対パスを stdout にリレーする:

```bash
cat > output/{name}-gen-ctx.json <<EOF
{
  "project_dir": "output",
  "name": "{name}",
  "source": "output/{name}-source.md",
  "theme": "{theme}",
  "slides": {N},
  "iteration": 1,
  "output_contract": {
    "slide_json": "output/{name}-slide.json",
    "images_json": "output/{name}-images.json"
  }
}
EOF
echo "CONTEXT:$(pwd)/output/{name}-gen-ctx.json"
```

**即座に Skill ツールで起動:**
- **skill**: `assign-slide-generator`
- **args**: bash 出力の `CONTEXT:` 行のパス（絶対パス）

**出力**: `output/{name}-slide.json` + `output/{name}-images.json`

#### B. N > 20 の場合（セクション分割並列設計）

1人の slide-designer が全体を設計すると関心の分離ができないため、セクション単位でサブエージェントに委譲し、各サブエージェントが assign-slide-generator を呼ぶ（孫エージェント構造）。

**→ 詳細手順（Step 1 セクション分割計画 / Step 2 セクション別 source 生成 / Step 3 並列 Agent prompt / Step 4 統合）は `section-split-guide.md` を読むこと**

**出力**: `output/{name}-slide.json` + `output/{name}-images.json`（統合済み）

---

## Phase 2: 構成レビュー

Agent(opus) subagent に以下を渡してレビュー:
- `review-checklist.md` + `image-prompt-guide.md`（レビュー観点）
- `output/{name}-source.md`（元コンテキスト）
- `output/{name}-slide.json` + `output/{name}-images.json`

レビュー観点:
- 構成・論理の問題
- **わかりにくい日本語**（冗長な表現、主語と述語のねじれ、曖昧な指示語など）があれば修正を指摘する

問題があれば `slide.json` / `images.json` を直接修正させる。ただし**レビューsubagentが修正する場合もvalidate-fix.jsで検証すること**（修正前のバックアップを取り、修正後に `node scripts/validate-fix.js before.json after.json` を実行）。

---

## Phase 3: 生成 → レンダリング → レビュー → 修正ループ

**目標の再注入**: Phase 3 は最大3回ループする。各ステップで `output/{name}-source.md`（元コンテキスト）を参照し、目標からのドリフトを防ぐ。fix で情報が削られていないか、review で元コンテンツとの整合性が保たれているかを常に確認する。

### 3-1. 画像生成（subagent 並列・n=2 best-of-2）

各画像エントリ (`images.json`) を **subagent で並列生成**。1 画像あたり `run-ai-images` engine を `-n 2` で叩き、**生成 2 枚を Read で目視確認 → 文字崩れ・ラベル化け・無意味記号化が無い方を選定 → images.json の `output` パスへコピー** する。

```bash
# 各画像エントリ {id} ごと (subagent 1 体が 1 画像担当)
PREFIX="output/{name}-img-{id}-cand"
ASPECT={16:9 or 1:1 or 9:16}   # images.json の size を換算 (hor→16:9 / square→1:1 / vert→9:16)

bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o "$PREFIX" --aspect "$ASPECT" -n 2 \
  -p "{prompt}"

# ↑ 出力: ${PREFIX}-01.png, ${PREFIX}-02.png
# Read で 2 枚目視 → 文字崩れない方を選定 → 最終出力先へコピー
cp "${PREFIX}-{選定番号}.png" "{images.json の output パス}"
rm -f "${PREFIX}"-*.png  # 候補は掃除
```

**選定基準** (must):
- 日本語ラベル / 見出し / アイコン中の文字が**崩れていない** (文字化け / 欠落 / 重なり / 無意味記号化が無い)
- 両方崩れている場合は同プロンプトで 1 回だけ再生成。それでも駄目なら run-diagram (SVG ベース) へフォールバックを検討

### 3-2. 画像バリデーション（レンダリング前ゲート）

```bash
node .claude/skills/run-slide/scripts/validate-images.js output/{name}-slide.json
```

失敗時はパス修正 or 再生成で対応する。レンダリング前ゲートとして置く理由は、画像不在のままビルドすると PDF に空コマが混入し、review フェーズに到達してから初めて気付くと再ビルドコストが嵩むため。

### 3-3. レイアウトバリデーション（レンダリング前ゲート）

```bash
node .claude/skills/run-slide/scripts/validate-layout.js output/{name}-slide.json
```

テーマCSSの制約（padding、h2 margin、font-size等）とブロック構成から、各スライドの推定コンテンツ高さを計算し、利用可能領域を超過するスライドを検出する。**推論的レビュー（C-3脆弱）では見逃すオーバーフローを決定論的に捕捉する計算的センサー。**

失敗時は超過スライドを分割してから再実行する。レンダリング後に視認でオーバーフローを検出してもPDF再ビルドが発生するため、ここで先回りして弾くことで loop の総コストが下がる。

### 3-4. レンダリング

```bash
node .claude/skills/run-slide/build-slide/build.js output/{name}-slide.json output/{name}-slide.pdf
```

### 3-5. レビュー＆修正ループ

**design → render → review のサイクルを回す。** 各責務を分離したsubagentが担当する。

```
┌─────────────────────────────────────────────────┐
│ Loop (max 3 iterations):                        │
│                                                 │
│  1. slide-review (並列)  → スコア + feedback.md │
│        ↓                                        │
│  2. 全スライド 90点以上？ → Yes → 完了          │
│        ↓ No                                     │
│  3. assign-slide-generator (feedback 渡し) → 修正        │
│        ↓                                        │
│  4. 再レンダリング (build.js)                    │
│        ↓                                        │
│  5. 古い画像・PDF削除 → ループ先頭へ             │
└─────────────────────────────────────────────────┘
```

#### 手順

**Step 1: レビュー（並列subagent）**

7枚ずつ分割して並列subagentでレビューする。

1. スライド総数を取得し、チャンク数を事前算出する
   ```
   TOTAL = slide.json の slides 配列の長さ
   CHUNK_COUNT = ceil(TOTAL / 7)
   チャンク一覧を列挙する（例: 19枚 → 3チャンク: `1-7`, `8-14`, `15-19`）
   ```
2. PDF・スライド画像を事前生成（1回だけ）
3. **全チャンクの Agent を必ず1つのメッセージで同時に起動する**（1つずつ順番に起動しない）。CHUNK_COUNT 個の Agent ツール呼び出しを1つのレスポンスに含めること:
   ```
   prompt: "assign-slide-evaluator スキル(.claude/skills/assign-slide-evaluator/SKILL.md)の手順に従い、以下をレビューしてください: output/{name}-slide.json --range {start}-{end}
   元コンテキスト output/{name}-source.md も参照し、スライド内容が元の目的・メッセージからドリフトしていないか確認すること。"
   ```
4. 全subagentの結果を集約

**Step 2: 品質ゲート判定**

- 全スライド 90点以上 → **ループ終了**
- 90点未満のスライドあり → Step 3 へ

各subagentが出力した `output/{name}-review-feedback.md` を統合する。
複数チャンクからのフィードバックがある場合は1つのファイルにマージ。

**Step 3: 修正（assign-slide-generator にフィードバック反映を依頼）**

```bash
# fix前のJSONをバックアップ（validate-fix用）
cp output/{name}-slide.json output/{name}-slide.before-fix.json

# context JSON を書く（slide_json と feedback がある = generator は内部で修正動作になる）
cat > output/{name}-gen-ctx.json <<EOF
{
  "project_dir": "output",
  "name": "{name}",
  "source": "output/{name}-source.md",
  "theme": "{theme}",
  "slides": {N},
  "slide_json": "output/{name}-slide.json",
  "images_json": "output/{name}-images.json",
  "feedback": "output/{name}-review-feedback.md",
  "iteration": {iteration},
  "output_contract": {
    "slide_json": "output/{name}-slide.json",
    "images_json": "output/{name}-images.json"
  }
}
EOF
echo "CONTEXT:$(pwd)/output/{name}-gen-ctx.json"
```

**即座に Skill ツールで起動（Phase 1-4A と同じ呼び出し契約・絶対パス必須）:**
- **skill**: `assign-slide-generator`
- **args**: bash 出力の `CONTEXT:` 行のパス（絶対パス）

generator は `slide_json` + `feedback` の存在から修正動作を選択し、slide.json を修正する。source.md は内容追加・補完が必要な場合に参照される。
N > 20 の場合も修正は統合済み slide.json に対して単一実行する（修正はフィードバック対象のスライドのみ更新するターゲット型のため、セクション分割不要）。

**Step 4: fix検証ゲート（決定論的）**

```bash
node .claude/skills/run-slide/scripts/validate-fix.js output/{name}-slide.before-fix.json output/{name}-slide.json
```

| 結果 | 対応 |
|------|------|
| OK (exit 0) | Step 4 へ進む |
| REJECTED (exit 1) | fix前のJSONに戻し（`cp output/{name}-slide.before-fix.json output/{name}-slide.json`）、フィードバックに「分割で対応せよ。情報の削除は禁止」を追記して Step 3 を再実行 |

このゲートは「designer が情報を削って体裁だけ整える」修正を機械的に検出するためにある。スキップすると不正な fix が loop を通過し、最終 PDF で内容が痩せたまま完了判定されてしまう。

**Step 5: 再レンダリング**

```bash
# バックアップとスライド画像を削除
rm -f output/{name}-slide.before-fix.json output/{name}-slide.0*.png
# 再ビルド
node .claude/skills/run-slide/build-slide/build.js output/{name}-slide.json output/{name}-slide.pdf
```

**Step 6: 再レビュー範囲の判定**

fix の修正内容に応じて再レビュー範囲が変わる:

| 修正内容 | 再レビュー範囲 | 理由 |
|---------|-------------|------|
| **再構成**（画像追加・ページ分割・ページ統合） | **全スライド** | スライド番号がずれる。追加画像の品質確認も必要。全体の流れ・統一感が変わる |
| **軽微な修正**（position調整・br挿入・文言圧縮） | **不合格チャンクのみ** | 他のスライドに影響しない |

判定方法: fix 後の slide.json のスライド総数が変わった、または images.json に新規エントリが追加された → **再構成** と判断。

**再構成時:**
1. 修正後の slide.json からスライド総数を再取得
2. 全スライドを7枚ずつ再分割
3. **全チャンクに対して** Agent を並列起動
4. 新規追加された画像があれば、再レビュー前に **3-1 の手順 (`run-ai-images` -n 2 → 文字崩れ無しを選定)** で生成

**軽微修正時:**
1. 修正後の slide.json からスライド総数を再取得
2. 不合格チャンクの range を再計算（分割で枚数が増えた分を反映）
3. 該当チャンクのみ Agent を起動

最大3回ループ。

**ループ上限到達時（3回で90点未達）:**
1. 最終スコアと不合格スライド一覧をユーザーに報告する
2. 「以下のスライドが基準未達です。手動修正が必要な場合があります」と警告する
3. 現状のPDFはそのまま出力する（途中で止めない）

---

## Architecture: 責務分離

### N ≤ 20（単一設計）
```
run-slide (orchestrator)
│  責務: フェーズ管理、ファイル受け渡し、ループ制御
│
├── assign-slide-generator [Skill]
│   責務: JSON設計（create）/ JSON修正（fix）
│
├── slide-review [Agent 並列]
│   責務: 目視スコアリング + フィードバック出力
│
└── build-slide [Bash script]
    責務: JSON → PDF 変換 (build-slide/build.js)
```

### N > 20（セクション分割並列設計）
```
run-slide (親: orchestrator)
│  責務: フェーズ管理、セクション分割、統合、ループ制御
│
├── section-agent #1 [Agent] (子: セクションオーケストレータ)
│   ├── assign-slide-generator [Skill] (孫: JSON設計)
│   └── → output/{name}-s1-slide.json + s1-images.json
│
├── section-agent #2 [Agent] (子)
│   ├── assign-slide-generator [Skill] (孫)
│   └── → output/{name}-s2-slide.json + s2-images.json
│
├── ... (並列)
│
├── merge-sections.js [Bash] → 統合 slide.json + images.json
│
├── slide-review [Agent 並列]（レビューは統合後の全体に対して実行）
│
├── assign-slide-generator [Skill] (feedback 渡しで修正、統合JSONに単一実行)
│
└── build-slide [Bash script]
```

**呼び出し方法の使い分け:**
- **Skill ツール**: 単発実行（assign-slide-generator）。assign-slide-generator 側が frontmatter で `context: fork` を宣言しており、その実行はフォークされたコンテキストで行われる（run-slide 自身は親コンテキストのまま）
- **Agent ツール**: 並列実行（section-agent, slide-review）。general-purpose エージェントに手順を実行させる
- **Bash**: 決定論的処理（build.js, validate-images.js, merge-sections.js）

**インターフェース**: すべてファイルベース。subagent同士は直接やり取りしない。

---

## Gotchas

- **はみ出し修正は構造変換で**: 情報を削るのではなくテーブル化・短縮で同じ情報をコンパクトに再構成する
- **転用画像リストが入力バイアスになる** (#1.2): 「4フェーズ」と本文に均等記述があっても、転用画像が Phase 2-4 にしかないと Phase 1 が概要テーブルに吸収された。画像の有無ではなく本文の項目数でスライド数を決定し、画像がない項目は汎用画像か画像なしで作る

---

## Resources

| リソース | パス | 参照タイミング |
|---------|------|--------------|
| コンテキスト収集ガイド | `context-collection-guide.md` | Phase 0, 1-1, 1-2 |
| セクション分割ガイド | `section-split-guide.md` | Phase 1-4B (N > 20 のみ) |
| 画像プロンプトガイド | `image-prompt-guide.md` | Phase 2 |
| レビューチェックリスト | `review-checklist.md` | Phase 2 |
| スキーマ | `build-slide/schema/slide-schema.json` | Phase 1-4 |
| テーマプレビュー | `build-slide/preview/{theme}.html` | Phase 1-3 |
| 枚数見積もり | `scripts/estimate-slides.js` | Phase 1-2 |
| 画像バリデーション | `scripts/validate-images.js` | Phase 3-2 |
| レイアウトバリデーション | `scripts/validate-layout.js` | Phase 3-3 |
| fix検証ゲート | `scripts/validate-fix.js` | Phase 3-5 Step 4 |
| セクション統合 | `scripts/merge-sections.js` | Phase 1-4B Step 4 |
| レンダラー | `build-slide/build.js` | Phase 3-4, 3-5 |
