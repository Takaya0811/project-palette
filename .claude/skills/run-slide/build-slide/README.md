# build-slide

スキーマ準拠のJSONを受け取り、Marp経由でPDFを生成する決定論レンダラー。run-slide / assign-slide-evaluator から Bash 経由で呼ばれる。

LLM 推論を伴わない純粋な変換処理のため skill ではなく script として配置している (`assign-slide-renderer` から降格)。

## Input / Output

- **Input**: `schema/slide-schema.json` に準拠したJSONファイル
- **Output**: PDFファイル (拡張子で `.html` / `.pptx` / `.md` も可)

```
JSON(スキーマ準拠) → build.js → Markdown → PDF
```

## 使い方

```bash
node .claude/skills/run-slide/build-slide/build.js input.json output.pdf
```

## スライド構造

各スライドは `blocks` 配列にブロックを自由に並べる。

```json
{
  "class": "lead",
  "paginate": false,
  "blocks": [
    { "type": "h1", "text": "タイトル" },
    { "type": "text", "text": "サブタイトル" }
  ]
}
```

### ブロックタイプ一覧

| type | 用途 | フィールド |
|------|------|-----------|
| `h1` | 大見出し | text |
| `h2` | スライド見出し | text |
| `h3` | 小見出し | text |
| `text` | 段落テキスト | text |
| `list` | 箇条書き | items[] |
| `olist` | 番号付きリスト | items[] |
| `table` | テーブル | headers[], rows[][] |
| `code` | コードブロック | code, language? |
| `quote` | 引用 | text |
| `image` | 画像 | src, position? (省略時=インライン) |
| `br` | 空行スペーサー | count?(1-3) |

**テキスト系フィールドはインラインMarkdown対応:** `**太字**`, `` `code` ``, `[リンク](url)`

### スライドプロパティ

| プロパティ | 用途 |
|-----------|------|
| `class` | CSSクラス（`lead`, `full-image`） |
| `paginate` | ページ番号表示を上書き（false で非表示） |

## よく使うパターン

### タイトル
```json
{ "class": "lead", "paginate": false, "blocks": [
  { "type": "h1", "text": "タイトル" },
  { "type": "text", "text": "サブタイトル" }
]}
```

### 見出し+箇条書き
```json
{ "blocks": [
  { "type": "h2", "text": "見出し" },
  { "type": "list", "items": ["項目1", "項目2", "項目3"] }
]}
```

### テーブル+補足テキスト
```json
{ "blocks": [
  { "type": "h2", "text": "比較" },
  { "type": "table", "headers": ["A", "B"], "rows": [["1", "2"]] },
  { "type": "list", "items": ["補足1", "補足2"] }
]}
```

### 画像+テキスト（インライン）
```json
{ "blocks": [
  { "type": "h2", "text": "見出し" },
  { "type": "image", "src": "./photo.png" },
  { "type": "list", "items": ["要点1", "要点2"] }
]}
```

### 画像+テキスト（スプリット）
```json
{ "blocks": [
  { "type": "h2", "text": "見出し" },
  { "type": "image", "src": "./photo.png", "position": "right:40%" },
  { "type": "list", "items": ["要点1", "要点2"] }
]}
```

### 演出的な複合見出し
```json
{ "blocks": [
  { "type": "h3", "text": "前振り" },
  { "type": "h3", "text": "ではなく" },
  { "type": "h1", "text": "本当に伝えたいこと" },
  { "type": "list", "items": ["補足1", "補足2"] }
]}
```

### 画像フル
```json
{ "class": "full-image", "paginate": false, "blocks": [
  { "type": "image", "src": "./photo.png" }
]}
```

## テーマ一覧

| テーマ | 特徴 | 推奨用途 |
|--------|------|----------|
| **`kanso`** | 禅の簡素。ウォームクリーム+オレンジ | **デフォルト。** 汎用 |
| `prisma` | 分光の多彩。5色カラーブロック | クリエイティブ |
| `abyss` | 深淵の闇。ダーク+エメラルド | 技術・ダークUI |
| `tabula` | 白紙の純粋。ホワイト+ブルー | ビジネス |
| `sumi` | 墨の静謐。クールグレー+インディゴ | 知的・アカデミック |

プレビュー: `preview/{theme}.html`

## ファイル構成

```
.claude/skills/run-slide/build-slide/
  build.js              ← JSON→PDF ジェネレータ
  schema/
    slide-schema.json   ← JSONスキーマ定義
    example.json        ← サンプル入力
  themes/               ← Marp用CSSテーマ（5種）
  preview/              ← テーマプレビューHTML（5種）
```
