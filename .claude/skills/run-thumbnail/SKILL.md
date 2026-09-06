---
name: run-thumbnail
description: サムネイル画像を 1 枚単発で生成する engine。「サムネ 1 枚だけ」「単発サムネ」で発動。複数パターンなら wrap-thumbnails を使う。
user-invocable: true
argument-hint: "<title> [mode] [-o output] [reference image]"
---

# run-thumbnail

YouTube/ブログ向けサムネイル画像を **固定テンプレート** で生成する。`config.json` に完成品のプロンプトテンプレートが入っており、`scripts/generate.sh` が入力スロットを埋めて `scripts/codex-image.sh` (内部で `codex exec` + `image_gen` ツールを 1920x1080 / high quality で呼び出し、magick で 1920x1080 正規化) を叩く。出力形式は `-o` の拡張子で決まる (default `.png`、`.webp` / `.jpg` 指定可)。

**Claude はプロンプトを組まない。** タイトルをモードに応じたスロットに分解して generate.sh を叩くだけ。

## Input / Output

- **Input**: タイトル文字列、モード選択、（任意）参照画像
- **Output**: `output/{ファイル名}.png` — 16:9 サムネイル画像 (拡張子で format 判定。`.webp` / `.jpg` も可)

## モード選択

| モード | 用途 | 必須スロット |
|--------|------|------------|
| `right-layout` | 解説・チュートリアル・4要素整理（汎用） | line1 / line2 / line3 / line4 |
| `sandwich` | ○選・まとめ・比較・複数アイテム紹介 | top-text / bottom-text / objects |
| `face-closeup` | 衝撃ニュース・リアクション・速報（顔75%以上） | hook-text / bottom-text |
| `center-chaos` | 煽り・ランキング・衝撃（中央キャラ + テキスト散布） | hook-left / hook-right / brand / bottom-text / objects |
| `vs-split` | ビフォーアフター対比・導入効果・変化訴求 | before-label / after-label / bottom-text |
| `product-flow` | 比較・推薦・意見系（疑問フック→結論） | line1 / line2 |
| `badge-comparison` | 収入変化・成果報告・スキルアップ（数値バッジ） | before-label / before-value / after-label / after-value / middle-text / bottom-text |
| `concept-map` | 技術スタック紹介・概念マップ・システム構成 | top-text / bottom-text / labeled-objects |
| `center-hero` | 教育系・解説系・ハウツー・専門家紹介 | bottom-text / objects |

どのモードもハマらない場合は `right-layout` をデフォルトに（汎用性が高い）。

> **一次情報は config.json。** 上表は編集時点のスナップショットで、`config.json` の更新に追従しない可能性がある。
> 最新のモード一覧は `bash .claude/skills/run-thumbnail/scripts/generate.sh --list-modes`、
> 各モードのパラメータ詳細と説明は `bash .claude/skills/run-thumbnail/scripts/generate.sh -m <mode> --help` で確認する。
> `--character-image` / `--icon-image` は多くのモードで optional として共通で受け付けるため、上表の必須スロットからは省いている。

## 生成フロー

### Step 1: モードとスロットを決める

タイトルをモードのスロットに分解する。**各行の役割が厳密に異なる** ので混同しないこと:

**right-layout の場合（役割の違いが最重要）:**

| スロット | 役割 | 中身 | 例 |
|----------|------|------|---|
| `--line1` | **フック** | 感情を揺さぶる煽り文。タイトルではない。警告・驚き・命令・疑問でクリックを誘う | 「もう全員これ使え」「9割が知らない」「知らないと損」「全エンジニア必見」「衝撃」「ガチでヤバい」「もう戻れない」 |
| `--line2` | **タイトル + アイコン** | プロダクト名・ブランド名・テーマ名。アイコンバッジ + タイトル文字の横長バナーとして描かれる | 「Claude Code」「ChatGPT」「Gemini」「Cursor」「MCP」「v0」 |
| `--line3` | **補足情報（サブタイトル）** | タイトルを修飾する属性・権威付け・数値・属性。主張は弱め。**決め台詞ではない** | 「公式ベストプラクティス19選」「Anthropic公式直伝」「現役エンジニアの」「2026年最新版」「プロが教える」「業界震撼の」 |
| `--line4` | **キラーワード / 決め台詞** | 結論・最大強調語・読後に残したい言葉。line3 より主張が圧倒的に強い。action/結果/変化を示す | 「徹底解説」「完全攻略」「10倍生産性」「開発革命」「時代が変わる」「全自動化」「神技連発」「秒で終わる」 |

### 完成形の組み合わせ例

| line1 (Hook) | line2 (Title) | line3 (補足) | line4 (Killer) |
|---|---|---|---|
| 知らないと損 | Claude Code | 公式ベストプラクティス19選 | 10倍生産性 |
| もう全員これ使え | Cursor | 現役エンジニアの | 開発革命 |
| 9割が知らない | ChatGPT | プロの使い方 | 完全攻略 |
| 衝撃 | MCP | Anthropic公式直伝 | 全自動化 |

### 混同しやすいポイント

- line1 は **Hook** であって Title ではない（プロダクト名を line1 に入れない）
- line4 は **Killer word** であって Title ではない（プロダクト名を line4 に入れない）
- プロダクト名は必ず line2 に入れる（line2 のアイコン行がタイトルを担う）
- **line3 と line4 の役割を混同しない**: 「徹底解説」「完全解説」「10倍生産性」は line4（決め台詞）。line3 は「業界震撼の」「公式19選」のような属性・権威付けで、主張は line4 より弱い
- 行の主張強度順: **line4 > line2 > line1 > line3**（line3 が最も控えめ）

**sandwich の場合:**
- `--top-text` 上部バナー（年号・カテゴリ等）
- `--bottom-text` 下部バナー — **最大強調・結論**
- `--objects` 中央に散らすオブジェクト群（カンマ区切り）

### Step 2: 参照画像を集める

> **NOTE**: 以下に登場する `imgsearch` は社内向けロゴ検索 CLI で本 bundle には同梱されていない。読者環境で **`imgsearch` を別途用意するか、ロゴ URL を WebSearch / 手動 curl で取得して `output/ref-*.png` に保存する** 形に置き換えて運用する (Step 後段の `--icon-image output/ref-*.png` 指定はそのまま使える)。

「任意」ではない。**line2 に固有名詞（プロダクト/ブランド/サービス名）が入るなら `imgsearch` (もしくは代替手段) でロゴを探し `--icon-image` に渡す** のがデフォルト行動。キャラ指名（「まさおで」等）があれば `--character-image` も同様。image_gen に任せると公式ロゴの形状・色が崩れるか別物になる。

```bash
imgsearch search "{プロダクト名}" --tag logo --json   # line2 が固有名詞なら必ず叩く
imgsearch search "{キャラ}" --tag character --json     # キャラ指名があれば叩く
imgsearch get <id> --json
curl -sL "<url>" -o output/ref-xxx.{webp,png,jpeg}
```

**スキップしてよい条件** (どちらかを満たす時のみ):
- line2 が一般名詞・抽象語（「AI開発」「生産性」等）でロゴ化対象がない
- `imgsearch search` がヒット 0 件（このときは image_gen の自動生成に任せる）

検索してヒットしたのにロゴを渡さず生成を始めるのは原則 NG。「プロダクト名あり → 即 imgsearch」を反射で動かすこと。

**置き場のルール**: 参照画像もサムネ出力もすべて **プロジェクトルートの `output/` 直下** に置く (skill ディレクトリ配下に掘らない)。`generate.sh` / `codex-image.sh` は `-o` や `--character-image` などに相対パスが渡ると `git rev-parse --show-toplevel` で解決した **リポジトリルート相対** に自動正規化するので、CWD がどこでも `output/...` と書けば常にプロジェクトルートの `output/` を指す。

取得した画像は `--character-image` / `--icon-image` に渡す。複数ファイルの結合は generate.sh 側が自動で行う（`magick +append`）ので、Claude 側で結合する必要はない。

### Step 3: generate.sh を実行

```bash
bash .claude/skills/run-thumbnail/scripts/generate.sh \
  -o output/{ファイル名}.png \
  -m right-layout \
  --line1 "..." --line2 "..." --line3 "..." --line4 "..." \
  [--character-image output/ref-char.png] \
  [--icon-image output/ref-logo.png]
```

生成前にプロンプトを確認したい場合は `--dry-run` を付ける（codex-image.sh を呼ばずに組み上がったプロンプトを標準出力に表示）。

**テスト / 動作確認用: `--sample`**

各モードに `config.json` の `sample` が定義されており、`--sample` を付けるとその値で生成できる（テンプレ調整後の回帰確認用）:

```bash
bash .claude/skills/run-thumbnail/scripts/generate.sh -m right-layout --sample
# → output/samples/right-layout.png

bash .claude/skills/run-thumbnail/scripts/generate.sh -m sandwich --sample
# → output/samples/sandwich.png
```

`-o` を明示すれば出力先を上書き可能、個別のスロットを CLI で指定すれば sample 値を上書きできる（`--sample --line1 "..."` で line1 だけ差し替え等）。

### Step 4: レビュー & リトライ

生成後、**必ず Read ツールで画像を目視確認** する。不合格なら原則 **同じコマンドで再実行**（codex / image_gen 側のランダム性で改善することが多い）。**上限3リトライ**、それ以上改善しなければその時点のベストで確定。

テンプレ自体を直したい場合（色指定・配置指示の調整など）は `config.json` の `promptTemplate` を編集する。

## テンプレートを変更したい時

`config.json` が真実の源。ここを触れば全生成に反映される:

- **色・装飾ルール**: promptTemplate 内の hex コードを変更
- **レイアウト比率**: 「画面横幅45%」等の数値を変更
- **キャラクター設定**: `characterBlocks.default` を変更（参照画像なし時のデフォルト）

## モードを追加したい時

**`config.json` の `modes` に新エントリを 1 つ足すだけ。** `generate.sh` はスキーマドリブンで動作しており、引数パース・バリデーション・テンプレ埋め込みを config から自動生成するため **触らない**。

新モードに必要なフィールド:

```json
"<new-mode-name>": {
  "name": "表示名",
  "description": "用途の1行説明",
  "params": [
    {"name": "slot1",         "flag": "--slot1",         "required": true,  "desc": "説明"},
    {"name": "slot2",         "flag": "--slot2",         "required": true,  "desc": "説明"},
    {"name": "characterImage","flag": "--character-image","required": false,"desc": "キャラ参照画像"}
  ],
  "sample": {
    "slot1": "テスト入力1",
    "slot2": "テスト入力2"
  },
  "promptTemplate": "... {{slot1}} ... {{slot2}} ... {{characterBlock}} ..."
}
```

- **params**: 各スロットの名前・CLI フラグ・必須/任意・説明。`generate.sh --help` が自動生成する
- **sample**: `--sample` で使われる正準入力。回帰テストにも利用される
- **promptTemplate**: `{{slot1}}` のような Mustache 風プレースホルダで各 param を参照。`{{characterBlock}}` は共有リソースで自動で埋まる。`iconImage` パラメータを持つモードなら `{{iconBlock}}` と `{{line2Whitelist}}` も利用可能（right-layout と同じアスペクト比判定ロジックが走る）

追加後の検証手順:

```bash
# 1. JSON 構文確認
jq . .claude/skills/run-thumbnail/config.json > /dev/null

# 2. --list-modes に新モードが出るか
bash .claude/skills/run-thumbnail/scripts/generate.sh --list-modes

# 3. --help でパラメータが正しく表示されるか
bash .claude/skills/run-thumbnail/scripts/generate.sh -m <new-mode> --help

# 4. dry-run でプロンプトを確認
bash .claude/skills/run-thumbnail/scripts/generate.sh -m <new-mode> --sample --dry-run

# 5. 実画像で最終確認
bash .claude/skills/run-thumbnail/scripts/generate.sh -m <new-mode> --sample
```

既存モード（right-layout / sandwich）の `promptTemplate` や共有リソース（`characterBlocks` / `iconBlocks` / `line2Whitelist`）は **変更禁止**。新モード追加のためだけに既存を触らない。

## Gotchas

- **Claude がプロンプトを組まないこと**: 再現性の要はここ。generate.sh を介さず `codex-image.sh` / `codex exec` を直接呼び出してはいけない。テンプレートを逸脱した瞬間に再現性が崩れる。
- **line2 に固有名詞 → imgsearch は反射**: プロダクト/ブランド/サービス名が line2 に入るのに `imgsearch search ... --tag logo` を叩かず生成開始するのは NG。image_gen は公式ロゴを正しく描けない (形状・色が崩れる / 別物になる)。キャラ指名も同じ — 指名があったら `imgsearch ... --tag character` を反射で叩く。Step 2 参照。
- **line2 はアイコンバッジ + ラベル文字の横並び**: `right-layout` の line2 は「アイコンバッジ + ラベル文字」の横長バナーとして描かれる。`--line2 "Claude Code"` と渡すとラベル文字部分に「Claude Code」が描画される。`--icon-image` を渡した場合、画像のアスペクト比で動作が変わる（正方形ロゴ → 左アイコン + 右ラベル文字、横長バナー → バナー画像のみ・ラベル文字は描画しない）。
- **image_gen はランダム幻覚テキストを描く**: テンプレート側にホワイトリスト形式で許可テキストを明示しているが、それでも稀に幻覚する。失敗したらリトライで大抵直る。
- **`--dry-run` で事前確認**: プロンプトがどう組み上がるかを確認できる。テンプレ変更後の検証に使う。
- **参照画像の自動結合**: `--character-image` と `--icon-image` を両方指定すると、generate.sh が `magick +append` で結合して一時ファイルに書き、codex-image.sh に渡した後削除する。Claude 側で結合を気にする必要はない。
- **並列実行は安全**: `codex-image.sh` は image_gen ツールの返り値 path を直接 magick に渡す実装で、`~/.codex/generated_images` 横断 find をしないため複数同時起動でも衝突しない。各 codex exec は独立した session_id dir を持ち、出力 webp のパスも呼び出し側で一意に決めるため、並列ワーカー間で png・webp 共に分離される。
- **スキーマドリブン**: `generate.sh` は `config.json` の `modes[].params` スキーマを読んで動的に引数パースする。モード追加で `generate.sh` を触る必要はない（むしろ触ると壊れる）。追加手順は「モードを追加したい時」セクションを参照。

## ファイル構成

```
.claude/skills/run-thumbnail/
├── SKILL.md          # このファイル（Claude 向け使い方）
├── config.json       # モード定義 + promptTemplate（真実の源）
└── scripts/
    ├── generate.sh       # Bash + jq のスキーマドリブンラッパー
    └── codex-image.sh    # codex exec (gpt-6-astra / medium) + image_gen + magick で webp 書き出し
```
