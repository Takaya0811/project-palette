---
name: wrap-ai-image-chara
base: run-ai-images
description: クリックベイト用キャラ画像 (サムネ・OGP・記事冒頭) を生成する run-ai-images の wrap。「キャラ画像」「キャラ立ち絵」で発動。
user-invocable: true
argument-hint: "<character world | topic> [mode: A|B|C|D] [pose hints]"
---

# wrap-ai-image-chara

`run-ai-images` engine を **クリックベイト用キャラ立ち絵専用メタプロンプト**で叩く wrap。視線を止める強表情 + 手顔近ジェスチャー + カメラ目線を標準装備。画風と構図は固定、世界観・表情・ポーズだけパラメータで振る。engine 仕様は `.claude/skills/run-ai-images/SKILL.md` が一次情報。この skill は **メタプロンプトの組み立てと既知罠の回避**だけを担当する。

## モード判定

ユーザー発話から下表で展開モードを決定。曖昧なら **mode A デフォルト**。

| シグナル | モード | 出力 |
|---|---|---|
| 無指定 / 「キャラ作って」「サムネ用キャラ」「アイデア pattern」 | **A** 4 キャラ × 4 ポーズ zip | `<base>-c<N>-<pose-id>-01.png` × 4（各キャラ 1 ポーズ） |
| 「同じキャラで」「ポーズだけ振って」「素材セット」 | **B** 1 キャラ × 4 ポーズ | `<base>-<pose-id>-01.png` × 4 |
| 「ドヤ顔だけ 1 枚」「単発」 | **C** 1 キャラ × 1 ポーズ | 1 枚 |
| 「N キャラ全種類のポーズで」 | **D** N キャラ × 4 ポーズ全展開 | 4N 枚（N≤3 推奨） |

各 PNG に `-nobg.png` 透過版を Step 4 で自動生成。

## いつ使う / 使わない

| 用途 | スキル |
|---|---|
| キャラ立ち絵を統一画風で複数キャラ作る | **`wrap-ai-image-chara`** |
| 自由プロンプトで画像生成（風景・概念図・ロゴ素材） | `run-ai-images` |
| YouTube/ブログサムネ | `wrap-thumbnails` / `run-thumbnail` |

## メタプロンプト（v1）

実証済みの「vibrant flat anime」骨格。**この骨格は変更しない**（変更すると画風が崩れる）。世界観差し替えはパラメータ部だけ。

### パラメータ

```yaml
SUBJECT:        # "mecha musume girl" / "magical girl idol" / "sci-fi battle nun" / "cyber samurai girl"
THEME_COLOR:    # 2 色併記の組: "hot pink and crimson red" / "cyan-blue and silver" / "deep purple and rose"
ACCENT_EYE:     # "cyan" / "yellow" / "soft-pink" — THEME の補色寄り
ACCENT_GLOW:    # "pale yellow" / "white"
HAIR:           # "twin-tail hot pink" / "long silver wavy" / "short magenta-rose bob"
MOTIF:          # "star" / "heart" / "snowflake" / "cross-flame" / "sakura petal"
                # HAIR_CLIP / CHEST_EMBLEM は MOTIF から自動派生 (heart→heart-shaped clips / heart-shaped core)
OUTFIT:         # SUBJECT に合わせたジャンル固有の名詞句:
                # "sci-fi battle armor" / "magical idol stage outfit with armor accents"
                # / "battle nun habit with armor accents" / "cyber samurai armor with side-skirt plates"
EXPRESSION:     # POSE カタログから自動展開
POSE:           # POSE カタログから自動展開
```

### 組み立て本文（このまま `-p` に渡す / 4 キャラで完全に同一に保つ）

```
"vibrant anime illustration, medium bust-up composition with face centered in the upper portion of the frame, head shoulders and upper chest visible with a small comfortable margin of empty space around the character,
{SUBJECT}, {HAIR} hair with glowing {MOTIF}-shaped clips emitting 4-point sparkle bursts,
large sparkly {MOTIF}-shaped pupils clearly visible inside the iris with {ACCENT_EYE}/{ACCENT_GLOW} multi-color reflection,
{EXPRESSION}, {POSE}, hands kept very close to the face within a face-frame radius — palms or fingers touching or hovering right next to the cheeks, chin, temples, or just below the eyes, never thrown out wide away from the face, never resting on hips or at the sides,
detailed {THEME_COLOR} {OUTFIT} with mecha panel lines and {MOTIF}-shaped core inset emitting sparkle,
peach skin,
3-tone cel-shading (base + shadow + highlight) + subtle 3D toon-shader feel giving moderate volume to hair and outfit,
subtle warm rim light along edges,
{THEME_COLOR}-dominant palette + {ACCENT_EYE} eye + {ACCENT_GLOW} {MOTIF} accent, NOT monochrome,
plain white background, bold clean lineart"
```

**hands-near-face hard rule**: `{POSE}` 直後の `hands kept very close to the face ...` 行は不変。素材流用性を壊す最大要因が「手顔離脱」なので、ここは妥協しない。POSE カタログ各エントリも全て face-frame radius（顔幅 ~1.5 倍以内）内で書かれている。

**全身立ち絵が欲しい時のみ**冒頭の "medium bust-up composition ..." 行を "full-body standing pose, centered" に差し替える（そこ以外は触らない）。

### 入れない語（rich化 / 引き構図の罠）

```
NEVER:
  - "around character" / "scattered sparkles"        ← 引き構図化
  - "sticker-cutout" / "card art"                    ← 余白要求で被写体縮小
  - "frilly" / "stage outfit" 単独                  ← 衣装ボリュームで引き → "with armor accents" 必須
  - "painterly" / "photorealistic" / "cinematic"     ← rich化
  - "monochromatic" / "duotone"                      ← セピア化
  - "hands on hips" / "arms at sides" / "spread wide" / "in front of chest" ← 手顔離脱
```

## 手順

### Step 1: パラメータを 4 セット組む（mode A の場合）

| 既定値 | |
|---|---|
| ACCENT_EYE | THEME の補色寄り（cyan が無難） |
| ACCENT_GLOW | "pale yellow" |
| MOTIF | キャラごとに振る（無指定なら "star"） |
| OUTFIT | SUBJECT に合わせたジャンル固有句（"sci-fi battle armor" は機械娘専用） |

**4 キャラ振りの原則**: SUBJECT 軸（mecha / magical / nun / samurai / 騎士 / 弓兵 …）を**職能ごと変える**。色だけ 4 振りは mode A 派生（4 キャラ × 1 共通ポーズが明示指示されたとき）のみ。THEME_COLOR は **2 色併記の組**で色域内 4 振り（pink-red 指定なら `hot pink and crimson red` / `crimson and rose` / `magenta and burgundy` / `coral and scarlet`）。

参考テーブル（pink-red 指定時）:

| 枠 | SUBJECT / HAIR / MOTIF / OUTFIT |
|---|---|
| c1 | mecha musume / twin-tail hot pink / heart / sci-fi battle armor |
| c2 | magical girl idol / long crimson wavy / star / magical idol stage outfit with armor accents |
| c3 | sci-fi battle nun / short magenta-rose bob / cross-flame / battle nun habit with armor accents |
| c4 | cyber samurai girl / coral-red ponytail / sakura petal / cyber samurai armor with side-skirt plates |

mode B では 4 セット全て同じ params にして POSE だけ振る。mode D は N キャラ分作って各キャラに 4 ポーズ展開。

### POSE / EXPRESSION カタログ

クリックベイト用途専用（無表情・横向きは想定外）。**hands-near-face hard rule** 全エントリ共通。

| ID | 用途 | EXPRESSION | POSE |
|---|---|---|---|
| `01-excited-wink` | 汎用・紹介系（万能デフォルト） | `open mouth excited big smile with slight wink` | `both hands raised up to cheek level right next to the face, one hand clenched in a cheerful fist pump tucked near the chin, other hand open palm hovering against the cheek` |
| `02-home-alone-shock` | 「衝撃の〜」 | `shocked surprised expression with mouth wide open in a big O shape and wide round eyes` | `both hands pressed flat against both cheeks in the iconic home-alone surprise pose, palms touching the cheeks and fingers splayed framing the face` |
| `03-finger-gun-smug` | 「答えはこれ」 | `smug confident smirk with one eye winking` | `one hand making a finger-gun gesture with the index finger held at chin level pointed directly at the viewer with a small sparkle at the fingertip, other hand open palm gently resting against the opposite cheek` |
| `04-thumbs-up-grin` | 「おすすめ」 | `big toothy cheerful grin with one eye winking` | `one hand giving a strong thumbs-up gesture held up right next to the cheek with the thumb pointing up framing the face, other hand clenched in a small fist pump tucked near the chin` |
| `05-double-peace-joy` | 「楽しい」 | `bright happy smile with eyes closed in a joyful expression` | `both hands making double peace V-sign gestures held up right next to both cheeks with the V-fingers framing the face just below the eyes` |
| `06-point-at-viewer` | 「あなたに朗報」 | `confident bright smile with direct eye contact` | `one index finger pointed straight at the viewer held at chin level with a small sparkle at the fingertip, other hand open palm resting against the opposite cheek` |
| `07-mind-blown` | 「驚愕の仕組み」 | `mind-blown expression with mouth agape and sparkling wide eyes` | `both hands brought up close right beside the cheeks with all fingers splayed wide open as if mind exploding, palms facing forward within a few centimeters of the face, small sparkle bursts radiating between the hands and head` |
| `08-chin-thinking-smug` | 「実は…」 | `smug knowing half-smile with one eyebrow raised` | `one hand resting on the chin in a thinking gesture with the index finger lightly touching the lower lip, head tilted slightly to one side, other hand crossed under the chin arm cradling the elbow close to the chest` |
| `09-heart-hands` | 「推し」「感謝」 | `blissful warm smile with slightly blushing cheeks` | `both hands joined together raised up to the chin level forming a heart shape with the fingers right in front of the face, hands close enough to touch the chin` |
| `10-scream-shout` | 「警告」 | `open mouth wide shout with determined intense eyes` | `one clenched fist held up next to the cheek pumping upward, other fist tucked near the chin, leaning forward slightly with both fists framing the face` |

POSE 選び方:
- 無指定 → 既定 4 種 (`01` / `02` / `04` / `08`)
- 題材文脈あり → 文脈に合う 4 種を選ぶ。**徹底解説系**: `03` / `06` / `08` / `04`（提示 / 指差し / 思わせぶり / 推奨）。**衝撃ネタ系**: `02` / `07` / `10` / `08`。**推し紹介系**: `01` / `05` / `09` / `04`
- ユーザー自由記述 → 上書き可。ただし `palms/fingers near cheeks/chin/temples` の制約句を末尾に必ず足す（手顔近は不可侵）

### Step 2: prefix と発火

base prefix は kebab-case で（例: `opencode-go-pink-red`、`aws-blue`）。出力命名はモード判定表の通り。

```bash
BASE=output/<base-prefix>

declare -A CHARS  # mode A: c1..c4 別 params / mode B: 全枠同 params / mode D: c1..cN
CHARS[c1]="mecha musume girl|twin-tail hot pink hair|hot pink and crimson red|heart|sci-fi battle armor"
CHARS[c2]="magical girl idol|long crimson wavy hair|crimson and rose|star|magical idol stage outfit with armor accents"
CHARS[c3]="sci-fi battle nun|short magenta-rose bob|magenta and burgundy|cross-flame|battle nun habit with armor accents"
CHARS[c4]="cyber samurai girl|coral-red ponytail with bangs|coral and scarlet|sakura petal|cyber samurai armor with side-skirt plates"

declare -A POSES_FOR_CHAR
POSES_FOR_CHAR[c1]="03-finger-gun-smug"
POSES_FOR_CHAR[c2]="06-point-at-viewer"
POSES_FOR_CHAR[c3]="08-chin-thinking-smug"
POSES_FOR_CHAR[c4]="04-thumbs-up-grin"

# PROMPTS[c<N>] は **手書き** で 4 通り組み立てる（後述「組み立ての作法」参照）
for cid in c1 c2 c3 c4; do
  pose_id="${POSES_FOR_CHAR[$cid]}"
  ( bash .claude/skills/run-ai-images/scripts/generate.sh \
      -o "${BASE}-${cid}-${pose_id}" -n 1 --aspect 1:1 \
      -p "${PROMPTS[$cid]}" \
      > "/tmp/chara-${cid}-${pose_id}.log" 2>&1 ) &
done
wait
```

`-n 1` 固定（1 プロンプト 1 枚）。`--aspect 1:1` 固定。CODEX_HOME 隔離で衝突しない。

### プロンプト組み立ての作法

**シェル関数で機械的に slot 置換しない**。骨格 ~150 単語が 4 回完全一致して差分がパラメータ単語だけになると、image_gen 内部で「色違いの同じキャラ」に流れる。4 プロンプトを**手書きで**個別に組み立てる。守るのは:

- **骨格行は 4 プロンプトで同一**: "vibrant anime illustration, medium bust-up..." から "bold clean lineart" まで。"hands kept very close..." 行も不変。
- **{SUBJECT}/{HAIR}/{OUTFIT} スロットは各キャラ固有のジャンル名詞句で書き分ける**: 例: SUBJECT を `mecha / magical / nun / samurai` に振り、OUTFIT も `sci-fi battle armor` / `magical idol stage outfit with armor accents` / `battle nun habit with armor accents` / `cyber samurai armor with side-skirt plates` のように対応するジャンル句に。1〜3 語の小ディテールを足してよい（`with veiled headdress` 等）。
- **`for cid in c1..c4; do PROMPTS[$cid]="...{$VAR[$cid]}..."`** のような全テンプレ共有ループは禁止（「色違いの同じ甲冑娘」ルートに直結する）。

### Step 2.5: 小物（バッジ / ロゴ / ぬいぐるみ / マスコット）を精密反映したい場合

特定のバッジ・ロゴ・アイテム・ぬいぐるみを持たせるなら engine の `--ref-image` + `--ref-instruction`。

```bash
curl -sL "<URL>" -o output/ref-<name>.png
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o output/<prefix> --aspect 1:1 \
  --ref-image output/ref-<name>.png \
  --ref-instruction "添付の参照画像は、キャラクターが片手に高く掲げている小さなバッジの絵柄として描き込むこと。形状と模様を忠実に再現する。サイズは手に収まる程度。**画風はキャラクター本体と完全に統一すること (vibrant anime / 3-tone cel-shading + subtle 3D toon-shader feel / bold clean lineart)。参照画像の元画風 (フラット 2D / カートゥーン / 水彩 / 写真など) はトレースせず、デザイン・形状・配色・ロゴだけを採用する**。" \
  -p "<本文。POSE に「one hand high raised holding a small badge」を必ず含める>"
```

**画風統一ルール (必須)**: `--ref-instruction` には常に以下の趣旨を含める:

> *デザイン・形状・配色・ロゴ等の identity だけを参照画像から採用する。画風 (線・塗り・陰影) は本体キャラと完全に統一すること: vibrant anime, 3-tone cel-shading + subtle 3D toon-shader feel, bold clean lineart。フラット 2D / カートゥーン調 / 水彩 / 写真 などの参照元画風はそのまま使わない。*

加えて **プロンプト本文側にも保険を入れる**:

> *the plushie/badge/item rendered in the exact same vibrant anime cel-shading style as the main character, with matching 3-tone shading, subtle 3D toon-shader volume, and bold clean lineart, NOT in a separate flat 2D cartoon style*

理由: ref-image はデフォルトで「絵柄ごと」流用される。ぬいぐるみ・マスコットを参照に入れると、本体は cel-shading なのにぬいぐるみだけ参照元のフラット調になり、同じ画面内で 2 画風が衝突して合成感のある画になる (実例: Qwen クマぬいぐるみを抱くアイドル — クマだけフラット 2D で残った)。ref-instruction とプロンプト本文の二重縛りで矯正する。

複数素材は事前に `magick +append` で 1 枚にまとめる (run-thumbnail と同じ方式)。

### Step 3: 背景除去（必須）

```bash
# mode A: <base>-c<N>-<pose-id>-01.png
for f in "${BASE}"-c*-*-01.png; do
  .claude/skills/run-remove-bg/scripts/removebg.swift "$f" "${f%.png}-nobg.png" &
done
wait
```

macOS Vision API のローカル処理で 4 枚 ~3-5 秒。元 PNG はそのまま、`-nobg.png` で透過版を並置。

### Step 4: 目視 + 素材性チェック

`Read` で 4 枚確認。**手顔近は不可侵**（palms/fingers/fists が頬・顎・こめかみ・目下にある）。残り 2 要素（カメラ目線 / 強表情）はどちらか欠けても可。1 枚でも手顔離脱があれば Step 5 で再走（残り 2 要素より優先）。

確認後 `open output/<base>-*.png` でまとめてプレビュー（`-nobg.png` も含めて開く）。

### Step 5: 部分リトライ

不合格 1 枚だけ同 prefix で `-n 1` 再走（他は残る）。**メタプロンプト本文は再走時も変えない**。

```bash
bash .claude/skills/run-ai-images/scripts/generate.sh \
  -o "${BASE}-c1-03-finger-gun-smug" -n 1 --aspect 1:1 \
  -p "${PROMPTS[c1]}"
.claude/skills/run-remove-bg/scripts/removebg.swift \
  "${BASE}-c1-03-finger-gun-smug-01.png" \
  "${BASE}-c1-03-finger-gun-smug-01-nobg.png"
```

## 使用例

### 例 1: mode A（既定）

ユーザー: 「opencode go 徹底解説のサムネ用キャラ、pink red 系で」

→ POSE 4 種を題材から選定: `03` / `06` / `08` / `04`（徹底解説系）。pink-red 内で 4 キャラ案展開（Step 1 の参考テーブル参照）。4 並列発火、合計 4 枚。

### 例 2: mode B（同一キャラ素材セット）

ユーザー: 「水色の魔法少女、雪モチーフ、**ポーズだけ振って**」

→ 1 キャラ固定 (`SUBJECT=magical girl, HAIR=long silver wavy, THEME=cyan-blue and silver, MOTIF=snowflake, OUTFIT=magical girl dress with armor accents`) で既定 4 ポーズ並列。

## Gotchas

- **手顔近 (face-frame radius) は不可侵**: 素材性 (サムネ・OGP・UI 合成) は手と顔が同じ画面領域に収まることに直結。ユーザーが自由記述ポーズを指定しても `palms/fingers near cheeks/chin/temples` の制約句を末尾に足してから fire。手顔離脱は Step 4 で即リトライ対象（カメラ目線・強表情より優先）。
- **メタプロンプト本文は弄らない**: 「もう少し可愛く」等の追加指示はパラメータ側 (POSE/EXPRESSION/OUTFIT) で吸収。"3-tone cel-shading" / "NOT monochrome" を消すと画風が崩れる。
- **mode A は SUBJECT も振る**: 4 枠が同職能（全部 mecha musume の色違い）にならないよう mecha / magical / nun / samurai 等で職能分散。色だけ 4 振りは mode A 派生（明示指示時）のみ。
- **POSE は題材文脈で 4 種選ぶ**: 既定 4 種を盲目的に使わない。徹底解説系 `03/06/08/04`、衝撃ネタ `02/07/10/08`、推し紹介 `01/05/09/04`。
- **MOTIF 瞳孔は形状依存**: `star` / `heart` / `leaf` は出やすいが `lightning` は通常瞳に流れがち。希望時は `"<MOTIF>-shaped pupils clearly visible inside the iris"` で補強。
- **柔らかい衣装語は引きトリガー**: `frilly` / `lacy` / `stage outfit` 単独 NG、必ず `"with armor accents"` 併記。
- **mode D は N≤3 推奨**: 4N 並列。5 キャラ以上ならキャラ単位で直列、ポーズ 4 並列のまま。
- **画風以外を変えたいなら別 wrap**: 全身立ち絵 / 背景あり / 別画風 が必要なら派生 wrap を作る（このスキルは「上半身 / 白背景 / vibrant flat anime」専用）。
- **ref-image は画風ごと流用される**: ぬいぐるみ・マスコット・小物を `--ref-image` に渡すとき、参照元がフラット 2D / カートゥーン / 水彩 / 写真だと本体キャラ (cel-shading + 3D toon-shader) と画風衝突する。Step 2.5 の「画風統一ルール」を ref-instruction とプロンプト本文の両方に必ず入れる。identity だけ採用、画風は本体に揃える。
- **engine 落とし穴は run-ai-images SKILL.md 参照**: `--aspect` リネーム、CODEX_HOME 隔離、image_gen の 1.5MP 内部丸めなど。

## ファイル構成

```
.claude/skills/wrap-ai-image-chara/
└── SKILL.md          # このファイル (engine は持たない / wrap のみ)
```

engine は `.claude/skills/run-ai-images/scripts/generate.sh`。

## メタプロンプトの根拠

`output/style-flat/` `output/style-color/` `output/style-mix/` `output/style-3d/` `output/meta-demo/` で 30+ 枚を並列発火し参照画像との近接度で実証。最終構成は `vibrant anime illustration` + `3-tone cel-shading` + `chest gem + sparkle hair clip` + `<theme>-dominant palette + accent eye/glow, NOT monochrome` + `peach skin` + `bold clean lineart`。リッチ化 / 引き構図 / モノクロ化の罠を 30 枚で潰した記録。
