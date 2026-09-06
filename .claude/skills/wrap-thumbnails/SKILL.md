---
name: wrap-thumbnails
base: run-thumbnail
description: サムネイル画像を違う構図で複数パターン並列生成する run-thumbnail の wrap。「サムネ複数」「N パターン」で発動。
user-invocable: true
argument-hint: "<title | topic> [N=4] [prefix] [character-name]"
---

# wrap-thumbnails

run-thumbnail engine を **意図的に異なる構図で N 回並列実行** する wrap。デフォルト `N=4`。

engine 仕様（モード / スロット定義 / プロンプトテンプレート / config.json）はすべて `.claude/skills/run-thumbnail/SKILL.md` が一次情報。この skill は「**N パターンの構図設計 + 並列 fire + 集約**」だけを担当する。

## Input / Output

- **Input**: タイトル / テーマ（+ 任意: キャラ名、参照ロゴ、枚数 N、prefix）
- **Output**: `output/<prefix>-01.png` 〜 `<prefix>-NN.png`（複数枚。拡張子で format 判定、`.webp` / `.jpg` も可）

## 枚数の決定

| ユーザーの指定 | 動作 |
|---|---|
| 明示なし | **N = 4** でこの skill |
| 「3パターン」「5枚」等 | その数で実行 |
| 「1つだけ」「1枚」「シングル」等 | この skill は使わず **run-thumbnail を直接**叩く |

## 構図を「違う」にする = 何を変えるか

**最重要: mode を 4 パターンで 4 種類使う。** 同じ mode を複数回使わない。利用可能 mode は **`bash .claude/skills/run-thumbnail/scripts/generate.sh --list-modes` を実行して最新を取得**（一次情報は run-thumbnail の config.json）。mode 選択時は必ず `-m <mode> --help` で必要パラメータを確認。

### mode の選び方

mode 選択は「候補プールからランダムに 4 つ pick」のイメージ。固定の 4 セットを毎回使うと、同じチャンネル / 同系テーマで構図が単調になる（few-shot anchor）。**前回 / 他テーマで使った組み合わせと重ならないように** 組み直す意識を持つ。

テーマカテゴリ（解説系 / ○選系 / ビフォーアフター系 / ニュース系）ごとの **mode 親和性 (★★★/★★/合わない) 早見表 + Few-shot anchor 回避テクニック + A案 B案の組み立て例** は `references/composition-examples.md` を参照。実案件に入る前に必ず読む。

### さらに重ねる軸

mode を散らした上で、さらに各 mode の **煽りスロット / 結論スロット** を互いに重ねない。スロット名は mode ごとに異なるので、`generate.sh -m <mode> --help` で確認してから言葉を割り振る。詳細な軸の振り方は `references/composition-examples.md` 「さらに重ねる軸」を参照。

## 手順

### Step 1: 参照画像を集める（一度だけ）

`character` / `icon` は **N 枚で共有** するので、画像取得は **Claude 側で 1 回だけ** 走らせる。取得先のルールは `.claude/skills/run-thumbnail/SKILL.md` の Step 2 を参照 (社内 `imgsearch` CLI は本 bundle に未同梱、代替は run-thumbnail Step 2 冒頭の NOTE 参照)。

**ロゴ取得判断は「テーマに固有名詞ブランド/プロダクトが含まれているか」で決める**。タイトルから以下のどれかが抽出できたら **デフォルトで `--icon-image` 用ロゴを取りに行く**（ユーザーが明示しなくても）:

- プロダクト名: `Claude Code`, `ChatGPT`, `Kimi K2.7`, `MCP`, `Cursor`, `Codex`, `Gemini`, `DeepSeek`, `Notion`, `Figma` 等
- 企業名: `Anthropic`, `OpenAI`, `Moonshot`, `Google`, `Microsoft` 等
- サービス・フレームワーク名: `React`, `Next.js`, `Rails`, `Supabase` 等

「XXX 徹底解説」「XXX 登場」「XXX が〜」系のタイトルは **ほぼ全てロゴ対象**。逆にテーマが抽象概念のみ（「生産性10倍」「プロンプト5選」等）ならロゴ不要。

```bash
# 1. imgsearch で公式ロゴ URL を特定
# 2. curl で output/ref-<brand>.png に保存 (拡張子は取得元のフォーマットに合わせる)
curl -sL "<logo-url>" -o output/ref-kimi-logo.png
```

icon-image を受け取れる mode と受け取れない mode がある。一覧は `references/composition-examples.md` 「mode ごとの icon-image 対応」または config.json の `accepts_icon` を参照。非対応 mode にはロゴを渡せないが、4 枚の 1〜3 枚だけでもロゴ付きで統一感は出る。

### Step 2: N パターンの構図表を作る

`references/composition-examples.md` の ★ 分類で候補を絞り、Few-shot anchor 回避を意識して 4 mode を選ぶ。**作成後に軸ごとに重複チェック** → 重複があれば言い換えで散らす。

### Step 3: 並列 fire

N 個の `generate.sh` を **`run_in_background: true` で同時発火**。run-thumbnail の codex-image.sh は **CODEX_HOME を per-invocation で隔離**しているため、並列で走らせても画像衝突は発生しない（詳細は run-thumbnail SKILL.md Gotchas）。

**mode ごとにスロット（`--flag`）が違う** ため、パターンごとにコマンドが別形になる。以下はあくまで構造例:

```bash
# Pattern 01: right-layout
bash .claude/skills/run-thumbnail/scripts/generate.sh \
  -o output/<prefix>-01.png -m right-layout \
  --line1 "..." --line2 "..." --line3 "..." --line4 "..." \
  --character-image output/ref-char.png --icon-image output/ref-logo.png

# Pattern 02: face-closeup (別スロット: hook-text / bottom-text)
bash .claude/skills/run-thumbnail/scripts/generate.sh \
  -o output/<prefix>-02.png -m face-closeup \
  --hook-text "..." --bottom-text "..." \
  --character-image output/ref-char.png

# Pattern 03 / 04: それぞれ `generate.sh -m <mode> --help` で必須スロットを確認してから組む
```

Claude の Bash ツール側では「複数の独立した Bash 呼び出しを 1 メッセージ内で発行」すれば自動で並列に回る。`run_in_background=true` で fire し、全 TaskOutput を block=true で待ってから次へ。

### Step 4: 目視確認 & 部分リトライ

全 N 枚を `Read` で確認。**失敗したインデックスだけ再実行**（同じコマンドで十分なことが多い）。上限 3 リトライ / 枚。

### Step 5: open

最後に N 枚をまとめて `open` する:

```bash
open output/<prefix>-01.png output/<prefix>-02.png output/<prefix>-03.png output/<prefix>-04.png
```

## Prefix / ファイル名

ユーザーが指定してこなければ、テーマを kebab-case に落として prefix にする:
- 「Claude Code 徹底解説」 → `claude-code-tettei`
- 「ChatGPT プロンプトテクニック」 → `chatgpt-prompt-tech`

衝突を避けたければタイムスタンプ or 5 桁サフィックスを付ける。

## Gotchas

- **単発は run-thumbnail へ**: ユーザーが「1 枚だけ」と明示した場合、この skill を使わず run-thumbnail を直接呼ぶ。ラップのオーバーヘッド（構図表作成）がもったいない。
- **一次情報は run-thumbnail SKILL.md + config.json**: モード仕様・プロンプトテンプレート・共有リソースはそちらに従う。このスキルで独自に再定義しない。`--list-modes` / `-m <mode> --help` を信じる。
- **軸の重複チェックを怠らない**: 4 パターン作って結論フレーズが全部「徹底解説」では wrap の意味がない。表を作ったら軸ごとに `uniq` する感覚で重複を潰す。
- **並列は CODEX_HOME 隔離で安全**: generate.sh を同時に N 個 fire しても race しない。codex exec は 20〜40 秒／枚で、4 並列なら総時間は約 40 秒（直列なら 2 分強）。
- **参照画像は共有**: キャラ / ロゴは N 枚で同一のものを使う。各 pattern で別々に imgsearch するのは無駄。

## ファイル構成

```
.claude/skills/wrap-thumbnails/
├── SKILL.md                            # このファイル (engine は持たない / wrap のみ)
└── references/
    └── composition-examples.md         # mode 親和性 / Few-shot anchor / A案B案 / icon 対応
```

engine は `.claude/skills/run-thumbnail/` にあり、この skill は engine の scripts を直接叩く。
