---
name: wrap-ai-image-edit
base: run-ai-images
description: 既存画像を保持しつつ指定箇所だけ変える edit (img2img) を行う run-ai-images の wrap。「画像編集」「img2img」で発動。
user-invocable: true
argument-hint: "<source image path> <edit instruction> [--aspect 16:9|1:1|9:16]"
---

# wrap-ai-image-edit

`run-ai-images` engine を **画像編集セマンティクス** で叩く wrap。
「ゼロから描く」生成と「元画像を保持して変更」編集を明確に分けるための skill。

engine 仕様 (CODEX_HOME 隔離 / `--aspect` プリセット / 並列発火 / `--ref-image` の受け渡し) は `.claude/skills/run-ai-images/SKILL.md` が一次情報。この wrap は **edit セマンティクスを徹底させる ref-instruction とプロンプト整形** だけを担当する。

## Input / Output

- **Input**: 元画像のファイルパス (必須) + 編集指示 (自然言語)
- **Output**: `output/<prefix>-01.<ext>` 〜 `<prefix>-04.<ext>` (default 4 枚、元画像のアスペクト比を引き継ぐ)

## いつ使う / 使わない

| 用途 | 使うスキル |
|---|---|
| 既存画像を **編集** する (色替え / 要素追加削除 / 表情・ポーズ変更 / 背景差し替え / スタイル転写) | **`wrap-ai-image-edit`** ← この skill |
| 参照画像を「インスピレーション」として見せつつ新規生成 (忠実再現ではない) | `run-ai-images` + `--ref-image` |
| 参照画像の **キャラ・ロゴを小物として忠実再現** しつつ別の絵を描く | `run-ai-images` + `--ref-image` + `--ref-instruction`（または `wrap-ai-image-chara` の小物モード） |
| 元画像なしの完全新規生成 | `run-ai-images` |
| サムネ (固定テンプレ) | `wrap-thumbnails` / `run-thumbnail` |

**判定基準**: 「元画像の構図・被写体を維持するか？」維持するなら edit、しないなら run-ai-images。

## パラメータ

```yaml
INPUT_IMAGE:    # 必須、編集対象の画像パス (相対パスは repo root 相対)
EDIT:           # 必須、何を変えるかを自然言語で。動詞から始めるのが推奨 (change X to Y / add X / remove X / replace X with Y / convert style to Z)
PRESERVE:       # 省略可、明示的に保持を強調したい要素。未指定は "composition, framing, subject identity, lighting, overall style"
STRENGTH:       # 省略可、"minimal" / "moderate" / "significant" (default: "moderate")
                # minimal = 指示箇所だけ最小変更、周辺は一切触らない
                # moderate = 指示箇所 + 自然に馴染むよう周辺を軽く調整
                # significant = 指示内容を最大限反映（元画像の改変度が大きい）
ASPECT:         # 省略可、元画像と同じアスペクトが推奨。未指定時は入力画像から自動判定（下記 Step 1 参照）
```

## プロンプト組み立て（このまま `-p` に渡す）

```
EDIT TASK — transform the provided reference image according to the instructions below.

APPLY CHANGES: {EDIT}

PRESERVE (do not alter): {PRESERVE}

Edit strength: {STRENGTH}.

This is an EDIT operation, NOT a regeneration. Treat the reference image as the source to be modified. Keep the input composition, framing, subject identity, and pixel-level structure as intact as possible. Change ONLY the elements explicitly specified in APPLY CHANGES. Do not add, remove, or re-interpret any element outside of that scope.

Output a high-quality edited version of the input image.
```

## ref-instruction（`--ref-instruction` に渡す）

```
添付画像は編集対象（source）として扱う。reference/inspiration ではない。編集指示に従って画像を加工し、指示されていない要素（構図・被写体の同一性・画風・ライティング・周辺ディテール）は忠実に保持する。ゼロから描き起こさない。被写体の顔・ポーズ・位置関係は改変指示がない限り固定する。
```

## 手順

### Step 1: 入力画像のアスペクト検出

ユーザーが `--aspect` を明示しない限り、元画像からアスペクト比を取得して近い `--aspect` プリセットを選ぶ（engine の native 出力と入力のアスペクトがズレると、編集結果が元画像と重ねにくくなる）。

```bash
# 元画像の WxH を取得
dims=$(magick identify -format "%w %h" "<INPUT_IMAGE>")
w=$(echo "$dims" | awk '{print $1}')
h=$(echo "$dims" | awk '{print $2}')
ratio=$(awk -v w="$w" -v h="$h" 'BEGIN{printf "%.3f", w/h}')
```

近接プリセット判定（おおよその目安）:

| `ratio` (w/h) | 推奨 `--aspect` |
|---|---|
| ≥ 1.6 | `16:9` |
| 1.35 ～ 1.6 | `3:2` |
| 0.85 ～ 1.35 | `1:1` |
| 0.58 ～ 0.85 | `2:3` |
| ≤ 0.58 | `9:16` |

どうしても元画像のピクセルに厳密合わせしたいときだけ `--size <元画像と同じ WxH>` を使う（escape hatch）。ただし magick resize が入るので画質劣化に注意。

`magick` が入っていない環境では、このアスペクト判定ステップはスキップして `--aspect 1:1` 既定で fire する。結果が明らかにズレていたら、ユーザーにアスペクトを聞いてから `--aspect` を明示して再実行する。

### Step 2: パラメータを埋める

ユーザーの自然言語入力から `EDIT` を抽出。曖昧な保持要件は既定値でよい。

| パラメータ | デフォルト |
|---|---|
| PRESERVE | "composition, framing, subject identity, lighting, overall style" |
| STRENGTH | "moderate" |

**EDIT の書き方**:
- 良い例: `"change the hoodie color from blue to red"`, `"remove the text in the top-right corner"`, `"add a small star badge on the chest"`, `"replace the background with a sunset sky"`, `"convert the style to watercolor"`
- 悪い例: `"make it better"`, `"cooler"`, `"more dynamic"` — 何を変えるかが不明 → prompt 上は無視されて元画像コピーに近い出力になるか、モデルが勝手に解釈して意図しない改変が起きる。

**STRENGTH の使い分け**:
- ロゴ・看板テキストなど細部の差し替え → `minimal`
- 表情・ポーズ変更、色替え → `moderate`
- 背景差し替え、スタイル転写 (photo → anime 等) → `significant`

### Step 3: prefix を決める

ユーザーが指定してこなければ、元画像のベース名 + edit 内容の短縮を kebab-case で:
- `mascot.png` + "change hoodie to red" → `mascot-red-hoodie`
- `hero.png` + "remove text" → `hero-notext`

### Step 4: run-ai-images を呼ぶ

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/<prefix> \
  --aspect <Step 1 で判定> \
  --ref-image "<INPUT_IMAGE>" \
  --ref-instruction "<上記 ref-instruction 本文>" \
  -p "<組み立てたプロンプト本文>"
```

`-n` は指定しない = engine 既定の 4 枚並列。4 パターン出るのは「同じ編集指示に対する確率的な解釈違い」なので、当たりを選ぶ運用。

### Step 5: 目視 + 部分リトライ

`Read` で 4 枚確認 → `open output/<prefix>-*.png`。

不合格枚がある場合:
- 全部ダメ → `EDIT` 文を書き直して再走（動詞を強めに、保持箇所を明示化）
- 1〜2 枚だけダメ → `-n 2` 等で部分再生成 → `mv` で差し替え
- 全部「元画像とほぼ同じ（編集されない）」→ `STRENGTH: significant` に上げるか、`EDIT` 文に "**clearly visible change**" と追記

## 使用例

### 例 1: 色替え

ユーザー: 「`output/mascot-01.png` のパーカーを青から赤に変えて」

→ パラメータ展開:
```yaml
INPUT_IMAGE:  "output/mascot-01.png"
EDIT:         "change the hoodie color from blue to red, keep the exact same design details and logo"
PRESERVE:     "character pose, facial expression, background, lighting, art style"
STRENGTH:     "minimal"
```

→ アスペクト検出して 4 枚 fire、色替えだけ適用されたバリエーションが出る。

### 例 2: 要素削除

ユーザー: 「`hero.png` の右上のテキストを消して」

→ パラメータ展開:
```yaml
INPUT_IMAGE:  "hero.png"
EDIT:         "remove the text in the top-right corner, fill the area naturally with the surrounding background"
PRESERVE:     "composition, subject, lighting, remaining text and graphic elements"
STRENGTH:     "minimal"
```

### 例 3: 背景差し替え

ユーザー: 「このキャラ画像の背景を夕焼け空に差し替えて」

→ パラメータ展開:
```yaml
INPUT_IMAGE:  "output/char.png"
EDIT:         "replace the plain white background with a vibrant sunset sky (orange-pink gradient with soft clouds)"
PRESERVE:     "character pose, character design, character lighting and shading style"
STRENGTH:     "significant"
```

→ 背景差し替えは改変度が大きいので `significant`。キャラ側の lighting が背景と馴染むよう自然に調整されるのを期待する。

### 例 4: スタイル転写

ユーザー: 「写真を水彩画風に変換して」

→ パラメータ展開:
```yaml
INPUT_IMAGE:  "photo.jpg"
EDIT:         "convert the overall rendering style to traditional watercolor painting (soft edges, visible paper texture, muted pigment bleeds)"
PRESERVE:     "composition, subject identity, framing, color palette"
STRENGTH:     "significant"
```

## Gotchas

- **image_gen の edit は厳密な pixel-level edit ではない**: image_gen は元画像を参考に再合成する。文字・小さなロゴ・細部のディテールは 4 枚とも微妙に変わる可能性が高い。厳密な pixel edit が必要なら image_gen ではなく ImageMagick や専用ツールを使う。
- **「ほぼ変わらない」結果が出る時**: `STRENGTH: minimal` + 曖昧な `EDIT` 文だと、モデルが安全側に倒れて元画像コピー近似を返すことがある。`EDIT` 文を動詞ベースで具体化 (`"change X to Y"`) し、`STRENGTH` を上げる。
- **「変わりすぎる」結果が出る時**: 特に `significant` + 被写体周辺の変更指示で、被写体の同一性まで崩れることがある。`PRESERVE` に `"subject identity, facial features, pose"` を強めに書き、`STRENGTH` を下げる。
- **アスペクト比ずれ**: Step 1 のアスペクト自動判定を省略すると engine 既定 1:1 で出るため、横長画像を編集指示すると左右が切れる / 余白が足される。必ず元画像からアスペクトを拾う。
- **4 枚とも使えない時の対処**: image_gen は稀にプロンプトを完全無視する。この時は `EDIT` 文頭に `"[EDITING TASK — the user wants the following change applied to the reference image]"` のような meta 指示を足すと拾われやすくなる。
- **複数の編集を同時に依頼しない**: `EDIT` 文に 3 つ以上の独立変更を詰めると、どれかが反映されない / 衝突する。1 回の fire で 1 編集を原則とし、連鎖編集したい場合は出力を次の `INPUT_IMAGE` に使って多段で回す。
- **engine 落とし穴は run-ai-images SKILL.md 参照**: CODEX_HOME 隔離、`--aspect` プリセット、image_gen の 1.5MP 内部丸めなどは engine 一次情報を信頼する。

## ファイル構成

```
.claude/skills/wrap-ai-image-edit/
└── SKILL.md          # このファイル (engine は持たない / wrap のみ)
```

engine は `.claude/skills/run-ai-images/scripts/generate.sh`。この skill は engine を直接叩く。
