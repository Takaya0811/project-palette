---
name: wrap-ai-image-scenery
base: run-ai-images
description: テキスト合成前提の AI 背景素材 (人物なし) を生成する run-ai-images の wrap。「背景素材」「背景生成」で発動。
user-invocable: true
argument-hint: "<scene | mood | time> [palette] [aspect]"
---

# wrap-ai-image-scenery

`run-ai-images` engine を **背景素材専用メタプロンプト** で叩く wrap。
場面と雰囲気だけパラメータで振る運用。**人物/キャラは描かない**（小物・建物・自然・空のみ）。

engine 仕様 (CODEX_HOME 隔離 / `--aspect` プリセット / `magick` 正規化 / 並列発火) は `.claude/skills/run-ai-images/SKILL.md` が一次情報。この skill は **メタプロンプトの組み立てと既知罠の回避** だけを担当する。

## Input / Output

- **Input**: 場面・時間帯・天候・雰囲気・パレット（自然言語で OK、未指定は **Claude が文脈から推定**）
- **Output**: `output/<prefix>-NN-01.png`（NN=01..04、engine の `-n 1` 出力 suffix が付く / **default `--aspect 16:9`** / **4 つの違う構図** を並列生成）

**重要**: この wrap は同じプロンプトで 4 枚出すのではなく、**意図的に 4 通りの違う SCENE/MOOD/TIME を投げて** 1 枚ずつ生成する（wrap-thumbnails と同方針）。素材として「使えるやつを 1 枚選ぶ」運用前提。

## いつ使う / 使わない

| 用途 | 使うスキル |
|---|---|
| 動画背景 / スライド背景 / SNSバナー / キャラ立ち絵の背景 / 壁紙 | **`wrap-ai-image-scenery`** ← この skill |
| キャラ立ち絵 (mecha musume / 魔法少女 等) | `wrap-ai-image-chara` |
| 任意プロンプトで自由に画像生成 | `run-ai-images` |
| YouTube/ブログサムネ（テキスト合成あり） | `wrap-thumbnails` / `run-thumbnail` |

## オーケストレーター運用（指定なしモード）

ユーザーが「背景作って」「背景素材ちょうだい」など **抽象的に依頼してきた場合**、Claude (orchestrator) が以下の優先順で文脈を拾ってパラメータを決める:

1. **直前の会話に登場したキャラ・テーマ**: 例えば直前で `wrap-ai-image-chara` でオレンジの mecha musume を作っていれば、対応する背景（warm orange dawn city / sci-fi battlefield 等）を選ぶ
2. **直前で扱っていた話題・記事テーマ**: blog 記事のテーマが「AI 開発」なら futuristic terminal room、「自然と暮らす」なら森の朝などを選ぶ
3. **何も文脈が無ければ default 方針 = 「黒ベース × エフェクト系の抽象テクスチャ」** で 4 バリ振る。具象シーン (都市 / 山 / 部屋) にはしない。理由: サムネ/カードのベースとして中央余白が確保されてテキスト・キャラを乗せやすい。色は黒ベース固定、アクセント色は **その時の文脈 / 直前のキャラ色 / ユーザーの好み** で選ぶ (default はピンク系)。エフェクト軸も毎回 Claude が違う 4 つを考える (粒子 / ボケ / 放射 / ライン / グリッド / フラクタル / フォグ / グリッチ etc から選ぶ)。

提案後 **そのまま 4 枚生成** する（合意確認は挟まない、CLAUDE.md の pipeline 完全自律方針に倣う）。気に入らなければユーザーが追指示で再走。

## メタプロンプト（v2 - 簡素版）

`wrap-ai-image-chara` と同じ「vibrant anime cel-shaded」系画風を継承するが、背景は制御点が少ないので **3〜4 句に圧縮**。chara wrap の細かい立体化呪文 (3-tone cel + 3D toon-shader) は風景には過剰なので外す。

### パラメータ

```yaml
SCENE:    # 場面・時間・雰囲気を 1 行で。
          # 例: "futuristic city skyline at dawn, hopeful"
          #     "low-angle neon city street at night, energetic"
          #     "rooftop view of skyline at golden hour, nostalgic"
          #     "misty mountain valley at overcast morning, mysterious"
PALETTE:  # 主色 + アクセント色を 1 行で。
          # 例: "warm sunrise (orange/peach/gold) with cyan accent"
          #     "neon (magenta/cyan/black) with electric blue"
          #     "warm gold with violet sky"
          #     "cool blue-gray with subtle teal"
LAYOUT:   # サムネ用テキスト合成余白の指示。
          # default: "center + lower-third"
          # 他: "wide upper sky" / "left half" / "lower-third pavement"
WEATHER:  # 任意。SCENE に混ぜ込めない時だけ追加。例: "light rain on wet pavement"
```

### 組み立て本文（このまま `-p` に渡す）

```
"vibrant anime cel-shaded scenery,
{SCENE},
{PALETTE} palette,
wide cinematic composition for thumbnail background — {LAYOUT} kept as negative space for title overlay,
no people, no text in image,
NOT photorealistic, NOT oil-paint"
```

**たったこれだけ**。SCENE / PALETTE / LAYOUT の 3 句で意図を表現する。

### 入れない語（短縮版）

```
NEVER:
  - "character" / "person" / "figure" / "people"   ← 人物トリガー
  - "centered subject" / "main character"          ← 中央集中構図
  - "close-up" / "macro shot"                       ← 引き〜中距離が本分
  - "text" / "logo" / "title"                       ← 文字は合成側で
  - "photorealistic" / "oil painting"               ← 画風ズレ
```

### v1 を捨てた理由

v1 は chara wrap の骨格を機械的にコピーしていたため `DEPTH` `WEATHER` `LIGHTING` `ACCENT` `DETAIL_LEVEL` `3-tone cel` 等を細切れに渡していた。実検証 (output/bg-cyber-*) で出力に問題は無かったが、**プロンプトを冗長にしても結果は同じ** = 必要なかったと判明。SCENE 文に時間・雰囲気・天候を自然言語でまとめた方が AI 解釈も滑らかになる。chara wrap が細かいのは「立体キャラ顔」という制御点が多いため。

## 手順

### Step 1: 4 通りの構図表を作る

**この wrap の核心**。run-thumbnails と同じく **意図的に 4 通り違う SCENE/MOOD/TIME/PALETTE** を考える。同じ案を量産しない（4 枚同じプロンプトなら `run-ai-images` を直接 `-n 4` で叩いた方が早い）。

軸の振り方の例（ユーザーがテーマだけ指定 = 「未来都市」のとき）:

| # | SCENE 派生 | TIME | MOOD | COLOR_PALETTE | 狙い |
|---|---|---|---|---|---|
| 01 | aerial shot of futuristic city | dawn | hopeful | warm sunrise (orange/peach/gold) + cyan accent | 王道、明るい使い回し |
| 02 | low angle neon city street | night | energetic | neon night (magenta/cyan/black) + electric blue | 派手、サムネ向きインパクト |
| 03 | rooftop view of futuristic skyline | golden hour | nostalgic | warm gold + violet sky | 落ち着き、長尺動画背景 |
| 04 | misty futuristic skyline | overcast morning | mysterious | cool blue-gray + subtle teal | クール系、知的テーマ向き |

**指定なし = orchestrator が決める** モード:

- テーマ指定あり (例: 「未来都市」) → 上の表のように 4 通り違う SCENE/MOOD/TIME を振る
- **テーマ指定なし** → 「default 方針」(オーケストレーター運用節) に従う。**黒ベース × エフェクト系抽象テクスチャ** で 4 軸振る。具象シーン (mountain valley 等) を default にしない (テキスト合成のベースには向かない)

### Step 2: prefix を決める

ユーザーが指定してこなければ、テーマを kebab-case で:
- 「未来都市」 → `bg-cyber-city`
- 「自然 / 朝」 → `bg-nature-morning`
- 文脈なし → `bg-default`

prefix-01..04 が 4 通り別構図になる前提（同じ prefix で別バリエーションを並べる）。

### Step 3: アスペクト比を決める

| 用途ヒント | --aspect |
|---|---|
| **YouTube サムネ / 動画背景 / スライド / ブログヘッダー** | **`16:9`** ← default |
| キャラ立ち絵の背景に重ねる | `1:1` (chara wrap と揃える) |
| Shorts / Reels / 縦動画背景 / スマホ壁紙 | `9:16` |
| ポスター / SNS 縦長カード | `2:3` |
| 写真風横長 (3:2 系) | `3:2` |

明示なし = `16:9`。

### Step 4: 4 個並列 fire

各バリエーションを **個別の `generate.sh -n 1`** として **Bash の background で同時起動**。CODEX_HOME 隔離で並列衝突しない。

```bash
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-01 --aspect 16:9 -n 1 \
    -p "<本文 with 構図 01 のパラメータ>" > /tmp/bg01.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-02 --aspect 16:9 -n 1 \
    -p "<本文 with 構図 02 のパラメータ>" > /tmp/bg02.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-03 --aspect 16:9 -n 1 \
    -p "<本文 with 構図 03 のパラメータ>" > /tmp/bg03.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-04 --aspect 16:9 -n 1 \
    -p "<本文 with 構図 04 のパラメータ>" > /tmp/bg04.log 2>&1 ) &
wait
```

**注意**: 各 worker の出力は `<prefix>-NN-01.png` 形式 (`-n 1` でも engine の suffix 付与は変わらない)。気になるなら fire 後に `mv output/<prefix>-XX-01.png output/<prefix>-XX.png` で正規化する、もしくは prefix を `<theme>-01` `<theme>-02` 等にして `-01.png` suffix を許容する運用でも可。

### Step 5: 目視 + open

`Read` で全 4 枚確認 → `open output/<prefix>-*.png`。

### Step 6: 部分リトライ

不合格があれば、そのバリエーションだけ再 fire（プロンプトは固定、シードを変えるため再投入）。**メタプロンプト本文（テキスト合成スペース確保系）は再走時も変えない**（用途適合が崩れる）。

## 使用例

### 例 1: ユーザー指定あり

ユーザー: 「夜の未来都市、ネオン強めで背景作って」

→ v2 パラメータ展開:
```yaml
SCENE:    "low-angle neon cyberpunk city street at night with light rain on wet pavement, energetic"
PALETTE:  "neon night (magenta/cyan/black) with electric blue accent"
LAYOUT:   "center + lower-third"
prefix:   "bg-cyber-night"
```

→ 4 並列 fire (`--aspect 16:9` / 4 枚、SCENE を「夜」「黄昏」「俯瞰」「ロー」等で 4 通り振る)

### 例 2: 指定なし（オーケストレーター判断）

ユーザー: 「背景素材ちょうだい」（前後文脈なし）

→ default 方針 = 「黒ベース × エフェクト系抽象テクスチャ」で 4 軸違うのを Claude が選ぶ。例えば:

```
01: particles  — 黒地にピンク粒子散布
02: bokeh      — 黒地にピンクボケ + フレア
03: radial     — 中心からピンクラディアル放射
04: neon-lines — 黒地にピンクネオンライン波 + グリッド
```

prefix: `bg-default` 等。色は default ピンク、文脈次第で青/緑/黄等に振り替え可。エフェクト 4 軸も Claude が毎回選び直す（粒子 / ボケ / 放射 / ライン / グリッド / フォグ / グリッチ etc から）。

### 例 3: 直前で chara wrap を使った後

ユーザー: 「↑ のキャラに合う背景も」

→ Claude が直前のキャラ（例: orange mecha musume）と統一感のある背景を提案:
```yaml
SCENE:    "warm-tone sci-fi city skyline at dawn"
PALETTE:  "warm orange (orange/peach/gold) with subtle cyan accent"
LAYOUT:   "wide upper sky"
prefix:   "bg-mecha-orange-dawn"
```

→ orange chara と合成しても色味が破綻しない背景を生成 (PALETTE 主色を chara `THEME_COLOR` に揃えるのが鉄則)

## Gotchas

- **メタプロンプト本文は弄らない**: 「もっと幻想的に」「もっとドラマチックに」等の追加指示は SCENE / PALETTE 側で吸収する。本文の `no people` `no text` `NOT photorealistic` を消すと用途適合性が崩れる。
- **人を入れない**: NEVER 句で `character / person / figure` を排除しているが、`SCENE` に「a lone traveler」「villager」等の人物トリガーを含めると AI が人を入れる。**SCENE は風景/物のみで構成する**。
- **中央集中構図は避ける**: 背景素材は **テキスト/キャラを上に乗せる** ことが前提。AI が中央にメインオブジェクトを置くと使い勝手が落ちる。LAYOUT で余白位置を明示し、`SCENE` 側でも「single hero tree」等の中央集中ヒントは避ける。
- **chara wrap との色味統一**: 同じ案件でキャラと背景を作るなら **`PALETTE` の主色を chara の `THEME_COLOR` と揃える** + アクセントを補色で添える、が安定。
- **default 色 (ピンク) からの振り替えトリガー**: ① 直前で chara wrap を使った → chara 主色に合わせる ② ユーザーが色を明示 → それに従う ③ 記事/動画テーマが「自然/環境」→ 緑系、「金融/テック」→ 青系、「警告/緊急」→ 赤系、「夏/エネルギー」→ 黄系。それ以外は default ピンク維持。
- **`--aspect 16:9` がデフォルトな理由**: 動画/スライド/SNSバナー/壁紙の最大公約数。1:1 や 9:16 が必要なら明示指定。
- **engine 落とし穴は run-ai-images SKILL.md 参照**: `--aspect` フラグ仕様、CODEX_HOME 隔離、image_gen の 1.5MP 内部丸めなどは engine 一次情報を信頼する。

## ファイル構成

```
.claude/skills/wrap-ai-image-scenery/
└── SKILL.md          # このファイル (engine は持たない / wrap のみ)
```

engine は `.claude/skills/run-ai-images/scripts/generate.sh`。この skill は engine を直接叩く。

## メタプロンプトの根拠

`wrap-ai-image-chara` v1 で実証された「vibrant anime + 3-tone cel + subtle 3D toon-shader feel + NOT monochrome」骨格を背景用に転用。chara との統一画風を担保するため意図的に同じ語彙を使う。

背景固有の追加・除外（人を排除 / 中央集中構図を避ける / 奥行きレイヤー明示 / 文字を入れない）は、汎用「素材」としての使い回し性を高めるためのチューニング。
