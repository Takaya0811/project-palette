---
name: run-ai-images
description: 汎用 AI 画像生成。「画像生成」「画像作って」で発動。サムネは wrap-thumbnails、キャラ・背景・説明画像・編集はそれぞれ wrap-ai-image-* を使う。
user-invocable: true
argument-hint: "<prompt> [-n N=4] [-o prefix] [--aspect 16:9|1:1|9:16]"
---

# run-ai-images

任意プロンプトで **AI 画像を並列 N 枚生成** する汎用ツール。codex CLI の `image_gen` ツールを叩く。サムネのように固定テンプレがなく、プロンプト直書きで自由に生成できる。

**デフォルト N=4**（ユーザーが明示しなければ 4 枚並列生成）。`scripts/generate.sh` が CODEX_HOME per-invocation 隔離で並列 race を物理的に排除する実装になっているため、4〜8 並列でも安全。

## 使い分け

| 用途 | 使うスキル |
|---|---|
| YouTube/ブログのサムネ (固定テンプレ付き、複数パターン) | `wrap-thumbnails` |
| YouTube/ブログのサムネ 1 枚だけ (単発 / engine 調整) | `run-thumbnail` |
| 上記以外の画像生成全般 (キャラ、ロゴ素材、ビジュアル、概念図など) | **`run-ai-images`** ← この skill |

## Input / Output

- **Input**: プロンプト文字列、出力 prefix（+ 任意: 枚数 N、サイズ、フォーマット、品質、参照画像）
- **Output**: `<prefix>-01.<ext>`, `<prefix>-02.<ext>`, ..., `<prefix>-NN.<ext>`（repo root 相対）

## 基本使用

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/cat \
  -p "A cute cat wearing a wizard hat, digital art, vibrant colors"
# → output/cat-01.png, cat-02.png, cat-03.png, cat-04.png (default 4 枚)
```

## オプション

| フラグ | デフォルト | 説明 |
|---|---|---|
| `-o, --output-prefix` | **必須** | 出力 prefix。`-NN.<ext>` が自動付加される。相対パスは repo root 相対 |
| `-p, --prompt` | **必須** | 画像生成プロンプト（英語推奨だが日本語も可） |
| `-n, --count` | 4 | 並列生成する枚数 |
| `--aspect` | `1:1` | 王道アスペクト比 (`1:1` / `3:2` / `2:3` / `16:9` / `9:16`)。**image_gen の native 出力をそのまま保存**（resize なし） |
| `--size` | — | ピクセル厳密指定 `WIDTHxHEIGHT`。magick で resize + center-extent する escape hatch（`--aspect` と排他） |
| `--format` | `png` | `png` / `webp` / `jpg` |
| `--quality` | `high` | `high` / `medium` / `low`（image_gen に渡される） |
| `--ref-image` | — | 参照画像パス。キャラ・ロゴなどを忠実再現したいとき |
| `--ref-instruction` | `参照画像のデザイン・キャラクター・ロゴを忠実に再現すること` | 参照画像の使い方指示（上書きしたい時） |

## アスペクト比と解像度の指定

役割を分けた 2 つのフラグで制御する。**既定は `--aspect 1:1`**。

### `--aspect <ratio>` (推奨・default)

image_gen にアスペクト比を指示し、**返ってきた native 出力をそのまま保存**する（magick resize なし = 情報が劣化しない）。ピクセル数は image_gen の内部バジェット (~1.5MP) で丸められる。

| `--aspect` | 実測ピクセル (image_gen native) | 典型用途 |
|---|---|---|
| `1:1` | ~1254×1254 | SNS 正方形、アイコン、汎用 |
| `3:2` | 1536×1024 | 写真系横長、ブログヘッダー |
| `2:3` | 1024×1536 | 縦写真、ポスター |
| `16:9` | ~1672×941 | 動画、PC 壁紙、スライド背景 |
| `9:16` | ~941×1672 | Shorts / Reels / TikTok / Stories |

### `--size <WxH>` (escape hatch)

ピクセル数が厳密に必要なとき用。magick で `WIDTHxHEIGHT` に resize + center-extent する。例: CMS が「1920×1080 でしかアップロードできない」等。image_gen 出力からのスケーリングが入るため `--aspect` より情報量的には劣るが、規格合わせには必須。

```bash
# default = 1:1 native
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/cat -p "a cute cat wearing a wizard hat"

# アスペクトだけ指定 (推奨)
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/hero --aspect 16:9 \
  -p "serene mountain lake at dawn, ultra-detailed, cinematic"

bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/reel --aspect 9:16 \
  -p "neon-lit tokyo street, vertical composition, vibrant"

# ピクセル厳密指定 (escape hatch)
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/cms --size 1920x1080 --format webp \
  -p "abstract tech visualization, glowing neural network, deep blue + gold"
```

**`--aspect` と `--size` を両方指定するとエラー**（意図の競合）。

## ユースケース別の例

### 1. キャラクター素材を 4 枚（default）

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/mascot \
  -p "mascot character, friendly lion in blue hoodie, chibi style, clean vector, white background, 1024x1024"
```

### 2. ロゴ案を 8 枚、正方形 512

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/logo \
  -n 8 --size 512x512 --format webp \
  -p "minimal geometric logo for AI startup, circle + triangle, monochrome"
```

### 3. 横長ビジュアル素材 (ブログヘッダーなど)

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/hero \
  --size 1920x1080 --format webp \
  -p "abstract tech visualization, glowing neural network nodes, deep blue + gold, cinematic"
```

## 手順

### Step 1: プロンプトを決める

ユーザーのリクエストから具体的なプロンプトを組む。英語の方が image_gen の再現性が上がるが、日本語でも概ね通る。以下の要素を意識:

- **主題**: 何が / 誰が写っているか（`a cat`, `lion mascot character`）
- **スタイル**: 絵柄（`digital art`, `anime style`, `photorealistic`, `flat vector`）
- **色調**: `vibrant colors`, `monochrome`, `pastel palette`, `neon`
- **構図**: `close-up`, `full body`, `top-down`, `centered`
- **背景**: `white background`, `abstract gradient`, `cityscape at night`
- **解像度/品質ヒント**: `high detail`, `sharp`, `4K`, `cinematic lighting`

### Step 2: N 枚の fire

`generate.sh` 一発で N 枚を並列生成する（Claude 側で手動並列化は不要）:

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh -o <prefix> -n <N> -p "<prompt>"
```

スクリプトは内部で N 個の codex exec を background で同時起動し、`wait` で完了を待つ。

### Step 3: 目視確認 & 再生成

生成後、Read ツールで N 枚を確認。不合格なものがあれば、その **インデックスだけ再生成** する:

```bash
# idx=3 だけ作り直す: -n 1 で 1 枚、出力名を直接指定するのは不可なので
# 一旦別 prefix で 1 枚出して mv するか、prefix ごと作り直す
bash .claude/skills/run-ai-images/scripts/generate.sh -o output/retry -n 1 -p "..."
mv output/retry-01.png output/cat-03.png
```

### Step 4: open / 後工程

最後に `open` で全枚数をまとめて確認:

```bash
open output/<prefix>-*.png
```

後工程（webp 変換、サイズ調整、結合など）は `magick` を Bash から直接叩く。

## 枚数の判断

| ユーザーの指定 | 動作 |
|---|---|
| 明示なし | **N = 4** |
| 「3枚」「5枚」「8パターン」等 | その数 |
| 「1枚だけ」「1つ」 | `-n 1` で 1 枚 |

## Gotchas

- **並列は CODEX_HOME 隔離で安全**: `scripts/generate.sh` が各 worker に固有の `mktemp -d` を CODEX_HOME として割り当て、`~/.codex` 配下のエントリを symlink で複製（`generated_images` のみ固有 dir）。同時 N 起動でも png は物理的に分離される。
- **codex exec の所要時間**: 1 枚あたり 20〜40 秒。4 並列なら合計 40 秒程度で済む。直列だと 2 分超。
- **image_gen のサイズ指定は緩い**: プロンプトに `"1920x1080 resolution"` を埋め込んでいるが、image_gen 側で多少揺らぐことがある。最終的に magick で指定サイズに resize + center-extent する（cropped center-fit）。
- **フォーマット変換**: image_gen は png を出す。`--format webp` / `--format jpg` 指定時は magick が変換。品質劣化は実用上問題ない範囲。
- **参照画像の扱い**: `--ref-image` 1 つまで。複数を結合したい場合は事前に `magick +append` で 1 ファイルにしてから渡す（run-thumbnail の generate.sh と同じ方式）。
- **失敗時の挙動**: どれか 1 worker が失敗しても他の worker の結果は保持される。スクリプトは exit 1 で「部分失敗」を伝えるが、生成済み画像は残る。
- **プロンプトの幻覚**: image_gen は稀にプロンプトと異なる画像を出す（特にテキスト入りを指示した場合）。画質が重要な用途では N を多めに取って良さそうなのを選ぶ運用を推奨（`-n 8` 等）。
- **サムネには使わない**: 固定テンプレ・スロット・ブランド再現性が必要ならこの skill ではなく `wrap-thumbnails` を使う。

## ファイル構成

```
.claude/skills/run-ai-images/
├── SKILL.md
└── scripts/
    └── generate.sh   # Bash 並列 orchestrator + codex exec + magick 変換
```

## 将来の refactor メモ

- `run-thumbnail/scripts/codex-image.sh` と本スクリプトは CODEX_HOME 隔離ロジックが重複している。共通化の余地あり（今は独立）。
- `--variations` オプションで 1 プロンプトから意図的にバリエーションを振る機能（シード変更 / 軽微なプロンプト書き換え）は未実装。必要になったら追加。
