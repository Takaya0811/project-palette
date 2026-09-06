---
name: wrap-ai-image-detail-illustration
base: run-ai-images
description: 記事・動画用の説明画像 (比較図・グラレコ・概念図・フロー図) を生成する run-ai-images の wrap。「説明画像」「比較図」で発動。
user-invocable: true
argument-hint: "<concept | topic> [mode: comparison|summary|process|...]"
---

# wrap-ai-image-detail-illustration

`run-ai-images` engine を **説明画像専用メタプロンプト** で叩く wrap。
抽象概念をメタファーで視覚化した「理解を助ける図解」を **default 4 枚並列** で生成する。

engine 仕様 (CODEX_HOME 隔離 / `--aspect` プリセット / `magick` 正規化 / 並列発火) は `.claude/skills/run-ai-images/SKILL.md` が一次情報。この skill は **説明画像に特化したメタプロンプトの組み立てと既知罠の回避** だけを担当する。

## Input / Output

- **Input**: テーマ・説明したい概念・モード（未指定なら Claude が文脈から推定）
- **Output**: `output/<prefix>-01.png` 〜 `<prefix>-04.png`（**default `--aspect 16:9`** / **4 通り違うメタファー or モード** を並列生成）

**重要**: この wrap は同じプロンプトで 4 枚出すのではなく、**意図的に 4 通り違うメタファー/切り口** を投げて 1 枚ずつ生成する（scenery / chara wrap と同方針）。図解は「複数案出して一番伝わるやつを選ぶ」運用前提。

## いつ使う / 使わない

| 用途 | 使うスキル |
|---|---|
| 記事・動画の説明画像 / 比較図 / グラレコ / 概念図 / フロー図 | **`wrap-ai-image-detail-illustration`** ← この skill |
| キャラ立ち絵 | `wrap-ai-image-chara` |
| テキスト合成前提の背景素材 | `wrap-ai-image-scenery` |
| YouTube/ブログサムネ | `wrap-thumbnails` / `run-thumbnail` |
| 任意プロンプトで自由に画像生成 | `run-ai-images` |

## オーケストレーター運用（指定なしモード）

ユーザーが「比較図作って」「この話の図解ちょうだい」など抽象的に依頼してきた場合、Claude (orchestrator) が以下の優先順で文脈を拾ってパラメータを決める:

1. **直前の会話で議論していた概念 A vs B**: そのまま comparison モードで 4 つのメタファー違いを投げる
2. **直前で扱っていた記事/動画テーマ**: テーマに合うモード（summary / concept / process 等）を選ぶ
3. **何も文脈が無ければ** ユーザーに短く確認する（モードが決まらないと意味のある 4 案が作れない）

提案後 **そのまま 4 枚生成**（合意確認は挟まない、pipeline 完全自律方針）。

## モード

| モード | 用途 | 軸の振り方（4 パターン） |
|-------|------|-------------------------|
| `comparison` ★推奨 | 概念 A vs B の対比、メリデメ整理 | メタファー違い × 4 |
| `summary` | 複数ポイントをまとめた俯瞰図 | レイアウト違い（放射/円環/マトリクス/タイムライン） |
| `concept` | 抽象概念をメタファーで具体化 | メタファー違い × 4 |
| `process` | 手順・フロー | 方向違い（水平/垂直/循環/分岐） |
| `anatomy` | 分解図・内部構造 | 切断面違い（レイヤー/断面/爆発図/透視） |
| `before-after` | 変化・改善の対比 | コントラスト軸違い（状態/感情/効率/スケール） |
| `custom` | 上記に当てはまらない | テーマごとに自由設計 |

詳細テンプレートとプロンプト例は `examples.md` を参照。

## メタプロンプト骨格

**必ず日本語**（説明画像のラベル・タイトルを日本語で出すため、プロンプトも日本語の方が一致率が高い）。情報量多めを基本方針とする（シンプル過ぎる画像は情報価値ゼロ）。

### パラメータ

```yaml
MODE:      # comparison / summary / concept / process / anatomy / before-after / custom
THEME:     # 何を説明するか。1 行で。
           # 例: "MCP vs スキルの違い"
           #     "AIエージェントの内部構造"
METAPHOR:  # 抽象概念を何に置き換えるか。1 バリアントに 1 つ。
           # 例: "ハイテクキッチン vs レシピブック"
           #     "執事（目・脳・手）"
LAYOUT:    # 配置の指示。
           # 例: "左右2分割、中央に対比ポイント"
           #     "中央テーマから放射状に 5 ポイント"
STYLE:     # 画風。未指定時は preset カタログから選ぶ（下表参照）。
           # 単発 default: S1 グラレコ手描きマーカー。
           # 4 並列で画風を振る default: S1 / S2 / S3 / S4（解説用途でハズレにくい 4 系統）。
           # ユーザーが画風を明示指定した場合は必ずそれに従う（preset に無くても OK）。
```

### 画風 preset カタログ

STYLE 未指定時はここから選ぶ。検証済み 10 種。★ が **4 並列 default 振り分け**（S1〜S4）。各プロンプト本文は `【スタイル】` 節にそのまま差し込む:

| ID | 名称 | プロンプト本文 | 向き / 用途 |
|---|---|---|---|
| **S1** ★ | グラレコ手描きマーカー | `グラレコ風手描きマーカータッチ、温かみのある配色、和紙のような背景、手書き線画` | 記事・ブログ・ノート記事の標準。親しみやすさ最優先 |
| **S2** ★ | ノート手描き | `方眼ノートに青ボールペンと蛍光マーカー (黄・ピンク)、付箋・矢印・丸囲み・下線、勉強ノート風レイアウト、紙の質感` | 学習ノート・ハウツー・勉強系解説 |
| **S3** ★ | ホワイトボード | `ホワイトボードに黒・赤・青のマーカーで手描き、会議室のホワイトボード風、カラー付箋とマグネット、ビジネスミーティング調` | ビジネス資料・SaaS・社内勉強会・技術解説 |
| **S4** ★ | シルクスクリーンポスター | `シルクスクリーンポスター調、2〜3色限定パレット (蛍光ピンク・水色・黒)、フラット塗り、太めの黒アウトライン、陰影はハーフトーンドットのみ、版ずれやインクかすれは無し、可読性重視のクリーンな印刷物` | おしゃれ・デザイン記事・限定色レトロポップで情報量も担保したい時 |
| S5 | 水彩 | `水彩画タッチ、にじみとぼかし、柔らかい色調、紙の質感` | エッセイ / 情緒系 / 手紙のようなトーン |
| S6 | フラットベクター | `フラットベクターイラスト、パステルカラー、角丸、クリーンな塗り、影なし` | スライド・企業資料・UI 系ブログ |
| S7 | テクニカルインフォグラフィック | `テクニカルインフォグラフィック、クリーンな幾何、青白グレー系、シャープな線、企業資料風` | 技術ブログ・IR / 金融 / 企業資料 |
| S8 | アメコミ・ポップアート | `アメコミ風ポップアート、ハーフトーンドット、太い黒縁、原色カラー、吹き出し` | YouTube サムネ・派手め・インパクト重視 |
| S9 | クレヨン絵本 | `クレヨン・色鉛筆タッチ、ざらついた塗り、子どもの絵本風、温かい` | 教育コンテンツ・子ども向け・柔らかい |
| S10 | ピクセルアート | `ピクセルアート・ドット絵、16 bit 風、レトロゲーム調、くっきりしたドット` | レトロ・ゲーム文脈・エモいネタ系 |

default 4 種（S1〜S4）は「解説用途でハズレにくい」方向性で振ってある（グラレコ温かみ / 学習ノート / ビジネス会議 / シルクスクリーンポスター）。S5〜S10 は用途特化の選択肢として残置（ユーザー明示時のみ使う）。

### 組み立て本文（このまま `-p` に渡す）

```
説明画像、16:9、{STYLE}。

【テーマ】{THEME}

【構成/レイアウト】{LAYOUT}

【メタファー】{METAPHOR}

【必須要素】
- タイトル（日本語、大きめ）
- サブタイトル or キャッチコピー（日本語）
- 各要素にアイコン・絵文字を添える（👍 👎 ✅ ⚠️ 💡 ⚙️ 🚀 📚 等）
- メリット/デメリット/ポイントは箇条書きで 3 点ずつ

【スタイル】
- 手描き風、温かみ、情報量多め
- 日本語ラベル・テキストを読みやすいサイズで
- 視線誘導（矢印・天秤・番号など）

【禁止】抽象的な幾何模様だけで終わらせない、英語ラベルにしない、情報スカスカにしない
```

### 入れない語

```
NEVER:
  - "minimal" / "abstract only" / "sparse"         ← 情報量が落ちる
  - "English labels" / "text in English"           ← ラベル英語化
  - "photorealistic" / "3D render"                 ← 説明画像の画風から外れる
  - "single icon" / "one symbol"                   ← 要素数不足
```

## 手順

### Step 1: MODE と 4 バリアントの軸を決める

**この wrap の核心**。同じモード内で **4 通り違う METAPHOR / LAYOUT** を考える。同じ案の量産なら `run-ai-images` を `-n 4` で直接叩けばいい。

軸の振り方の例（テーマ = 「MCP vs スキル」、MODE = comparison）:

| # | METAPHOR | 狙い |
|---|---|---|
| 01 | ハイテクキッチン vs レシピブック | 王道、道具 vs 知恵 |
| 02 | 自動販売機 vs 料理教室 | 結果重視 vs 学習重視 |
| 03 | 電車の路線 vs 登山地図 | 固定ルート vs 自由設計 |
| 04 | コンビニ弁当 vs 手作り料理 | 手軽さ vs カスタマイズ性 |

summary モードなら 4 つのレイアウト違い（放射 / 円環 / マトリクス / タイムライン）を 4 バリアントとして投げる。

### Step 2: prefix を決める

テーマを kebab-case で:
- 「MCP vs スキル」 → `diag-mcp-vs-skill`
- 「AIエージェントの仕組み」 → `diag-agent-anatomy`
- 「開発プロセス」 → `diag-dev-process`

### Step 3: アスペクト比を決める

| 用途ヒント | --aspect |
|---|---|
| **ブログ記事内図解 / 動画内挿絵 / スライド** | **`16:9`** ← default |
| SNS 投稿（Twitter/Threads カード） | `1:1` |
| 縦動画内の図解 | `9:16` |

### Step 4: 4 個並列 fire

各バリアントを **個別の `generate.sh -n 1`** として Bash の background で同時起動。CODEX_HOME 隔離で並列衝突しない。

```bash
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-01 --aspect 16:9 -n 1 \
    -p "<本文 with バリアント 01 のメタファー>" > /tmp/diag01.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-02 --aspect 16:9 -n 1 \
    -p "<本文 with バリアント 02 のメタファー>" > /tmp/diag02.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-03 --aspect 16:9 -n 1 \
    -p "<本文 with バリアント 03 のメタファー>" > /tmp/diag03.log 2>&1 ) &
( bash .claude/skills/run-ai-images/scripts/generate.sh \
    -o output/<prefix>-04 --aspect 16:9 -n 1 \
    -p "<本文 with バリアント 04 のメタファー>" > /tmp/diag04.log 2>&1 ) &
wait
```

**注意**: 各 worker の出力は `<prefix>-NN-01.png` 形式（engine の default format は `png`、`-n 1` でも engine の suffix 付与は変わらない）。気になるなら fire 後に `mv` で正規化するか、prefix 運用で許容する（scenery wrap と同方針）。`.webp` が欲しい場合のみ `--format webp` を付ける。

### Step 5: 目視 + open

`Read` で全 4 枚確認 → `open output/<prefix>-*.png`。日本語ラベルが化けていない / 情報量が足りているかを確認する。

### Step 6: 部分リトライ

不合格があれば、そのバリアントだけ再 fire。メタプロンプト本文（グラレコ風・日本語・情報量）は **再走時も変えない**（スタイル一貫性が崩れる）。

## 参考画像でスタイル継承

既存の良い図解のスタイルを継承したい場合、engine の `--ref-image` を使う:

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/diag-new --aspect 16:9 -n 1 \
  --ref-image ./reference.png \
  --ref-instruction "このスタイル・配色・タッチを完全に継承。内容のみ変更" \
  -p "<本文>"
```

## Gotchas

- **メタファーが抽象的すぎると情報量ゼロの絵になる**: 「AIの概念図」ではなく「AIを執事として描く、目＝知覚、脳＝推論、手＝行動」のように具体的な見立てを必ず入れる
- **テンプレのコピペは禁物**: examples.md のテンプレートは構造だけ借りて中身は必ずテーマに合わせて書き換える。コピペするとテーマと無関係なメタファーが混入する
- **プロンプトは日本語**: 説明画像は日本語ラベルが主役なので、プロンプトも日本語で書いた方が image_gen のラベル描画品質が上がる
- **情報量 > 見た目**: 説明画像はインフォグラフィックであり、装飾画像ではない。メリデメ・ポイント・矢印を詰め込む方向で指示する
- **4 バリアントは同じプロンプトにしない**: 同じプロンプトで 4 枚なら `run-ai-images -n 4` で十分。この wrap の価値は「違うメタファー/切り口で 4 案出して選ぶ」運用にある
- **engine 落とし穴は run-ai-images SKILL.md 参照**: `--aspect` フラグ仕様、CODEX_HOME 隔離、image_gen の 1.5MP 内部丸めなどは engine 一次情報を信頼する

## ファイル構成

```
.claude/skills/wrap-ai-image-detail-illustration/
├── SKILL.md        # このファイル (engine は持たない / wrap のみ)
└── examples.md     # モード別プロンプトテンプレ + 具体例
```

engine は `.claude/skills/run-ai-images/scripts/generate.sh`。この skill は engine を直接叩く。
