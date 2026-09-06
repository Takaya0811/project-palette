---
name: assign-slide-generator
description: スライドJSON構成を設計・修正する内部スキル。run-slide から呼び出される (internal)。
user-invocable: false
context: fork
agent: general-purpose
model: opus
pair: assign-slide-evaluator
---

# assign-slide-generator

source.md からスライドJSONと画像プロンプトを設計する。前回成果物とフィードバックがある場合は既存JSONを修正する。create / fix のモード分岐は契約上持たず、入力 context に `slide_json` と `feedback` が揃っているか否かで内部的に挙動を切り替える。

## コンテキスト (スキル読み込み時に自動展開)

```json
!`cat $ARGUMENTS`
```

上記が空でなければ手順を最後まで実行する。「タスクが無い」と判断して空応答しない。

## 契約

`$ARGUMENTS` = **context JSON ファイルのパス** (単一契約)。

### context JSON スキーマ

```json
{
  "project_dir": "output",
  "name": "{name}",
  "source": "output/{name}-source.md",
  "theme": "kanso",
  "slides": 18,
  "slide_json": "output/{name}-slide.json",
  "images_json": "output/{name}-images.json",
  "feedback": "output/{name}-review-feedback.md",
  "iteration": 2,
  "output_contract": {
    "slide_json": "output/{name}-slide.json",
    "images_json": "output/{name}-images.json"
  }
}
```

| キー | 必須 | 用途 |
|------|------|------|
| `name` | ✓ | 出力ファイル prefix。フォールバックでは `source` から導出 |
| `source` | ✓ | ソースコンテンツ markdown path |
| `theme` | ✓ | テーマ名 (kanso/prisma/abyss/tabula/sumi) |
| `slides` | ✓ | 目標スライド枚数 |
| `slide_json` | — | 修正対象の既存JSON。**存在すれば修正動作**、無ければ新規設計 |
| `images_json` | — | 既存の画像プロンプト一覧。修正動作で参照・更新する |
| `feedback` | — | レビューからの修正指示 markdown。**存在すれば修正動作で読む** |
| `iteration` | — | 現在のループ回数 (情報用) |
| `output_contract.slide_json` | — | 出力先 (省略時は `{project_dir}/{name}-slide.json`) |
| `output_contract.images_json` | — | 出力先 (省略時は `{project_dir}/{name}-images.json`) |

### 動作分岐 (内部)

- `slide_json` ファイルが存在 + `feedback` ファイルが存在 → **修正動作** (フィードバック反映)
- それ以外 → **新規設計動作** (source から create)

呼び出し元はモード切り替えを意識しない。同じ context JSON 形式で 1 周目も N 周目も呼べる。

### フォールバック (JSON 不在時 = 直叩き受け皿)

`$ARGUMENTS` が JSON path として読めない場合は **生テキスト = source ファイルパス** として再解釈する。

- `name` = ファイル名から `-source` を除いた basename
- `theme` = `kanso` (デフォルト)
- `slides` = 12 (デフォルト)
- 出力先 = `output/{name}-slide.json` / `output/{name}-images.json`

---

## 新規設計動作

### 入力
- `source` (必須) — ソースコンテンツ
- `theme` (必須) — テーマ名
- `slides` (必須) — 目標スライド枚数

### 手順

1. source.md を読む
2. コンテキスト分析（対象者/目的/トーン）
3. `image-prompt-guide.md` を読み、テーマ別 stylePrefix を確認
4. `../run-slide/build-slide/schema/slide-schema.json` 準拠でJSON設計
5. 画像プロンプトを同時設計

### スライド密度ルール

**1スライドにサブセクション（h3）は最大2つ。** 3つ以上必要な場合は2ページに分割する。

例: 「Planner / Generator / Evaluator」の3要素を説明するなら:
- NG: 1スライドに h3×3 + text×3 → 詰め込みすぎ
- OK: スライドA「Planner + Generator」＋ スライドB「Evaluator + まとめ」
- OK: 全体像を画像1枚で見せ、テキストは要点のみ

### 出力ファイル
- `output_contract.slide_json` (省略時 `{project_dir}/{name}-slide.json`)
- `output_contract.images_json` (省略時 `{project_dir}/{name}-images.json`)

---

## 修正動作

### 入力
- `slide_json` — 現在のスライドJSON
- `feedback` — レビューからの修正指示 markdown
- `source` — 元ソース (内容追加・補完が必要な場合のみ参照)
- `images_json` — 既存の画像プロンプト一覧 (画像変更時に更新)

### 手順

1. 既存の slide.json を読む
2. feedback を読む
3. source.md を読む（内容の追加・補完が必要な場合のみ参照）
4. フィードバック内の各指摘に対して **最小限の修正** を適用
5. 修正後の slide.json を上書き保存

### 修正の大原則: はみ出したら分割。削除は絶対禁止

**テキストや要素の削除で溢れを解消してはいけない。** はみ出しの正しい解決策は「器を広げる」こと — 1枚を2枚に分割するか、テキストを画像に変換する。

修正の優先順位（上から順に検討）:

```
1. 分割    — はみ出しているスライドを2枚に分ける。最も確実
2. 画像化  — テキストを説明画像に変換して情報密度を上げる
3. 再配置  — レイアウト調整（position変更、br挿入等）
4. 圧縮    — 最終手段として文言を簡潔にする（意味は絶対に削らない）
```

**自己チェック**: 修正後、blocks を削除していないか確認せよ。修正前後で情報量が減っていたら分割に書き直す。

### 典型的な修正パターン

| 指摘カテゴリ | 修正方法 |
|------------|---------|
| **テキストはみ出し・詰め込みすぎ** | **① 画像化**: テキスト箇条書き → summary/comparison 画像に変換。images.json にプロンプト追加し、テキストblockを image block に置換。**② 分割**: 1枚を2枚に分ける（前半に概要+画像、後半に詳細） |
| 画像はみ出し | `position` の `right:XX%` / `left:XX%` のパーセンテージを縮小 |
| スカスカ | 前後スライドと統合 or コンテンツ追加（source.md から引っ張る） |
| テーブル崩壊 | テーブルを画像化（comparison/summary モード）、またはカラム数削減+ページ分割 |
| 余白不均等 | `br` ブロック挿入/削除 |

### 画像化の具体手順

溢れたテキストを画像に変換する場合:

1. 溢れている blocks の内容を把握
2. `image-prompt-guide.md` のテンプレートに従い画像プロンプトを設計
   - 箇条書き3-5項目 → `summary` モード
   - 2つの比較 → `comparison` モード
   - 手順・フロー → `process` モード
3. slide.json: テキスト blocks を image block に置換
   ```json
   { "type": "image", "src": "./{name}-img-fix-{slide番号}.png", "position": "right:45%" }
   ```
4. images.json: 新しい画像エントリを追加
   ```json
   { "id": "fix-{slide番号}", "slideIndex": {N}, "placement": "inline",
     "mode": "summary", "prompt": "...", "provider": "gemini", "size": "hor",
     "output": "output/{name}-img-fix-{slide番号}.png" }
   ```

### 重要

- **画像の追加・削除を伴う修正の場合**: images.json も必ず更新すること
- **スライド分割・統合の場合**: slideIndex の整合性を images.json と合わせること
- 修正は **指摘された箇所のみ**。問題のないスライドには触らない
- **要素の削除は禁止**。情報が消えるくらいなら1枚増やせ

### 出力
- `output_contract.slide_json`（上書き）
- `output_contract.images_json`（画像変更がある場合のみ上書き）

---

## Gotchas

- **画像パスの座標系が2つある**: slide.json の `src` は MD ファイル（output/内）からの相対パス（`./{name}-img-{id}.png`）、images.json の `output` は CWD からの相対パス（`output/{name}-img-{id}.png`）。slide.json に `./output/` を書くと画像が表示されない
- **スライド分割時の slideIndex ずれ**: 1枚を2枚に分割すると後続の全 slideIndex がずれる。images.json の既存エントリも忘れずに更新する
- **右画像配置時の左テキストはみ出し**: `image position: right:XX%` を使うと左テキスト領域が約半分に制約される。長い箇条書き（1項目20文字超の日本語）は折り返して下にはみ出す。対策: (1) テーブル形式に変換し各セルを短くする (2) 右画像が既に詳細情報を含む場合、左テキストは要約レベルにする
- **h2 直後のコンテンツ重なり防止**: h2 は CSS で `position: absolute` されているため、直後の要素に `h2 + *` ルールで margin が付与される。`br` ブロックはブロックレベルのspacerとしてレンダリングされるので、h2 直後に `{ "type": "br" }` を挟むことで正しくマージンが効く

## JSON設計ルール

### 画像設計ルール

1. **画像は「見ただけで内容がわかる説明図」** — 情報量を多く
2. **具体的に描く** — 抽象的なノード図ではなく実際の画面・UI等
3. **プロンプトは日本語**、構造化テンプレート必須。プロバイダは基本 `gemini` / `hor`
4. **stylePrefix** をテーマカラー込みで冒頭に付与
5. モードを選択: comparison / summary / concept / process / anatomy / before-after / section-divider

### 画像配置

レンダラーが `right:XX%` / `left:XX%` に自動で `contain` を付与するため、position に `contain` は書かなくてよい。
cover が必要な場合のみ `"position": "cover right:40%"` と明示。

## Resources

| リソース | パス | 用途 |
|---------|------|------|
| 画像プロンプトガイド | `../run-slide/image-prompt-guide.md` | 構造化テンプレート・stylePrefix |
| スキーマ | `../run-slide/build-slide/schema/slide-schema.json` | JSON構造定義 |
| テーマプレビュー | `../run-slide/build-slide/preview/{theme}.html` | 色・レイアウト確認 |
