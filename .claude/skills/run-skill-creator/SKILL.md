---
name: run-skill-creator
description: Claude Code Skill を新規作成する。「スキルを作りたい」「スキル化」で発動。
user-invocable: true
argument-hint: "<skill description>"
---

# run-skill-creator

`ref-agent-skill` の原則に従って Claude Code Skill を **新規作成** する **手順 Skill**。原則 (4 軸 / 決定木 / Less is More / Why-driven / 段階的開示 / Gotchas / `assign-*-evaluator` 契約) は ref-agent-skill が正本。本 Skill はそれを **いつ読み、どう適用するか** のフロー指揮に集中する。既存 skill の改善は別 skill (未実装) のスコープであり、本 skill は扱わない。

## Input / Output

- **Input**: `$ARGUMENTS` = 作りたいスキルの説明
- **Output**: `.claude/skills/<prefix-name>/` 配下に SKILL.md + (必要なら) 補助ファイル

## 親と subagent の責務分担 (本 Skill の核)

run-skill-creator は **オーケストレーター**。Step 0〜8 を親 1 ターンで全部こなす設計ではない。重い処理 (探索 / レビュー) は subagent に逃がし、親は **判断・統合・ユーザー対話** に専念する。理由: 親 context に探索結果や ref 全文が積み上がると、後段の起草で attention が削られ、判断が雑になる。

| Step | 担当 | subagent 手段 |
|---|---|---|
| 0 適格性 | 親 | — |
| 1 意図 | 親 | — |
| 2 探索 | **subagent** | Agent: `subagent_type=Explore` |
| 2 ヒアリング | 親 | — |
| 3 軸判定 + prefix | 親 | — |
| 4 SKILL.md 起草 | 親 | — |
| 5 description 最適化 | 親 | — |
| 6 セルフチェック | 親 | — |
| 7 内部レビュー | **subagent** | Skill: `assign-agent-skill-evaluator` |
| 8 提示 | 親 | — |

subagent 手段の使い分け: **read-only な探索は Agent ツール (`subagent_type=Explore`)** — fast search 用に最適化された組み込み subagent。**専門 evaluator は Skill ツール経由** — `assign-*-evaluator` は frontmatter で `context: fork` 既定なので、Skill ツール起動するだけで自動的に別コンテキストで走る。

---

## Step 0: Skill 適格性チェック

そもそもこれは Skill か。決定論で組めるなら Hook / CI / CLI / MCP / API に逃がす方が確実で速くトークンも食わない。Skill は最後の選択肢。

| 兆候 | 逃がし先 | Skill にしない理由 |
|---|---|---|
| 毎コミット前 / 毎ターン必ず走らせたい | Hook | LLM 注意力に依存させない |
| 機械的に判定可能 (lint / schema / 禁止語) | CI / CLI | 100% 通る検査をプロンプトで再発明しない |
| 外部 API / DB の実体 | CLI / MCP | 実装層は実装層に置く |
| API キー / 内部状態 / 共通処理が育ってきた | 自作 CLI に昇華 | スクリプトの寄せ集めから「小さなアプリ」へ |
| 文脈依存の判断 + 複数手段の使い分け | **Skill (本フロー継続)** | これが Skill の領分 |

Skill にしない判断が出たら本フローを終了し、代替手段をユーザーに提案する。

---

## Step 1: 意図の把握

3 つを明確にする。会話履歴に答えがあれば抽出してユーザーに確認する。

1. **何をさせるか** — このスキルでエージェントが何をできるようになるか
2. **いつ発動するか** — どんなユーザー発話・状況でトリガーすべきか
3. **入出力** — 何を受け取り、何を生成するか (観測可能な形で)

(配置場所は Step 3 で prefix が確定すると `.claude/skills/<prefix-name>/` に機械的に決まるので、ここでは決めない)

---

## Step 2: 調査とヒアリング

ヒアリング (ユーザー対話) と調査 (コードベース探索) を分離する。**調査は subagent**、ヒアリングは親。

### 2.1 ヒアリング (親)

ユーザーに直接確認する:

- エッジケースと失敗パターン
- 依存するツール・MCP・他スキル
- ユーザーの技術レベルに合わせた説明の粒度

### 2.2 探索 (subagent: Agent `subagent_type=Explore`)

類似スキル / 既存実装層 / コードベースの既存パターンは **Agent ツールで Explore subagent を起こして逃がす**。read-only fast search 用に最適化された組み込み subagent。

```
Agent({
  description: "類似スキル + 既存実装層の探索",
  subagent_type: "Explore",
  prompt: "次を調べて 200 語以内のサマリで返す:
  (1) `.claude/skills/` 配下に似た目的のスキル ({意図に関連するキーワード列}) があれば名前と prefix
  (2) 同じ処理が CLI / script / 自作 CLI で既に組まれていないか (`.claude/scripts/` / リポジトリの `bin/` 等)
  (3) 関連 ref-* skill の有無
  サマリだけで良い、ファイル本文は流し込まない"
})
```

理由: 探索はファイル数が多く、結果を親に直接吸わせると後段の起草と判断に使える context が削られる。subagent に消化させ、サマリだけ親に渡す。

返ってきたサマリで「既に CLI で組まれている処理を Skill で再発明していないか」「既存スキルの wrap で済まないか」を親で判断する。

---

## Step 3: 4 軸判定 + prefix 導出

Skill ツールで `ref-agent-skill` を読み、§1 (4 軸) と §2 (決定木) を適用する。これが本 skill の中心。

副作用なし (知識注入のみ) なら Purpose=`knowledge` 確定で `ref-*` 経路。副作用あり (ファイル生成 / コマンド実行 / 評価 JSON / 外部委譲) なら 4 軸を詰める。

### 3.1 軸値を決める

`ref-agent-skill §1` を参照して A: Purpose / B: Trigger / C: Shape / D: Role を埋める。

### 3.2 決定木で prefix を導出

`ref-agent-skill §2` の決定木 `f(A, B, C, Role) → prefix` で機械的に決まる。例外分岐は無い。prefix が決まれば配置先 `.claude/skills/<prefix-name>/` も同時に確定する。

### 3.3 軸値 + prefix を提示

軸値 (A/B/C/Role) と決定木の辿り方 + 確定した prefix を 1 行でユーザーに提示し、合意を取ってから Step 4 へ。

**Step 3 はここで終わる**。本 skill は scaffold へ dispatch しない。`ref + evaluator (+generator)` 構造は Step 4 以降で手動で起こす (本 bundle に scaffold 自動展開 skill は未同梱)。

---

## Step 4: SKILL.md を起草

**親で Write する**。Step 1-3 で固めた要件 (意図 + 4 軸 + prefix + ヒアリング + 探索サマリ) を使って親が直接ファイルを書く。subagent 起草は ref-agent-skill を再 Read する二重コストが発生し、要件が膨大になるため避ける。

### 4.1 frontmatter

prefix 別の必須/推奨フィールドは `ref-agent-skill §2` modifier 表 + §5 の `assign-*` 共通要件 yaml にある。当該 prefix の行を確認して書き写す。

`base:` / `pair:` / `kind:` を入れる場合は嘘の値を書かない。Claude Code 本体は読まないので起動時のエラーは出ないが、frontmatter lint (harness 側で用意していれば) と他 Skill 本文の参照が壊れる。

`ref-*` を作る場合 (= ドメイン知識辞書 + 相方 `assign-*-evaluator` のペア、もしくは三組形式) は **構造規定が `ref-skill-component-design` skill にある**。同 skill を Read して §2 のディレクトリ構造と §4 のペア契約 (`pair:` の張り方) に従う。

### 4.2 本文構成 (compaction 物理制約から逆算)

compaction で各 Skill は **先頭 5,000 token / 合計 25,000 token** に切り詰められる。本文末尾は消える。書く順序は逆算で決まる:

1. **冒頭 30 行** — Skill の役割 1 文 / Input / Output / 最重要禁則 / モード分岐 (あれば)
2. **Step 群 / 主要セクション** — 順に手順
3. **末尾** — `## Additional resources` (補助ファイル経路) / `## Gotchas`

禁則を本文末尾にまとめると compaction 後に消える事故が起きる。冒頭 30 行に詰める。500 行以下は経験則。超えるなら段階的開示で `references/` へ降ろす。

### 4.3 条件付きルールは `<important if="...">` で囲む

特定アクティビティ (テスト書く / `.claude/settings.json` を触る / PR を作る) でのみ効くルールは囲む:

```markdown
<important if="you are writing or modifying tests">
- Use `createTestApp()` helper.
- Mock database with `dbMock` from `packages/db/test`.
</important>
```

何でも囲まない (全部 important は意味喪失)。具体アクティビティで絞る。

### 4.4 並置 artifact (該当 prefix のみ)

| prefix | 並置 artifact | spec |
|---|---|---|
| `assign-*-evaluator` | `eval-schema.json` | `breakdown_keys` / `score_field` / `extras` を SKILL.md / RUBRIC.md と整合 |
| 他 (`ref-*` / `run-*` / `wrap-*` / `delegate-*` / `assign-*-generator` / `assign-*-contributor`) | なし | — |

---

## Step 5: description の最適化

description は **いつ呼ぶか** だけに絞る。動作の手順や段数を書くと Claude は本文を読まず description の短縮版だけで動く (詳細は `ref-agent-skill §3`)。発動ワードは **2 個前後** が上限 (3 個以上は重複 or 動作説明の紛れ込み)。

3 タイプ Before/After (本 skill 内で完結する最低限テンプレ):

| タイプ | Before (人間向け要約) | After (発動条件) |
|---|---|---|
| `ref-*` | `API の規約集です。エンドポイント設計や OpenAPI レビューで参照します。` | `「API規約」「OpenAPIレビュー」で発動。REST/OpenAPI 規約のための ref。` |
| `assign-*-evaluator` | `Skill を評価するスキル。SKILL.md の品質を採点します。` | `「skill レビュー」「SKILL.md 採点」で発動。ref-agent-skill に基づく Skill 設計の evaluator。` |
| `wrap-*` | `サムネイルを複数パターン生成するスキル。` | `「サムネ作って」「サムネイル生成」で発動。run-thumbnail の wrap。` |

After 共通の 3 点: (1) 発動ワード 2 個 / (2) prefix 別の役割 (ref / 採点根拠 ref + evaluator / 派生元 base) / (3) 動詞・段数・出力形式を含めない。

詳細手順 (3 タイプ Before/After の派生 / トリガー eval クエリの作り方 / near-miss クエリの濃度) は `description-optimization.md` を参照。最適化結果は before/after でユーザーに提示する。

---

## Step 6: セルフチェック

- [ ] Step 0 で Skill 適格性を判定した (Hook / CLI / MCP に逃がせなかったか確認)
- [ ] 4 軸値 (A/B/C/Role) が description / frontmatter / 本文から一意に判定できる
- [ ] prefix が決定木と整合している (決定木を辿って導出)
- [ ] frontmatter に prefix 別の必須 modifier が揃っている
- [ ] description がトリガー条件のみ (動詞・段数・出力形式の混入なし)
- [ ] input/output が観測可能 (ファイル / exit code / eval JSON)
- [ ] **最重要ルールが冒頭 30 行に集約**されている (compaction 5,000 token 対策)
- [ ] **補助ファイルを置いたら `## Additional resources` で経路を本文末尾に書いた**
- [ ] **条件付きルールは `<important if="...">` で囲んだ** (該当する場合)
- [ ] **`ALWAYS` / `NEVER` を理由なしで使っていない** (例外: 安全絶対条件のみ)
- [ ] Less is More — 落選理由・検証経緯・一般知識の写経が残っていない
- [ ] Gotchas がある (少なくとも 1 つ) かつ **昇格判断**を通した — 4 段階階段 (Gotchas → 軽い決定論 (lint/Hook/設定) → 重い決定論 (script/CI) → ツール化) のどこに置くべきか。再発頻度 + ブラスト半径 + 検出可能性で判断
- [ ] (`assign-*-evaluator` のみ) `eval-schema.json` を並置した

frontmatter の機械検証 (必須フィールドの存在 / 既存 skill 名との衝突 / `pair:` の相互整合 等) は、harness 側に lint ツールがあれば走らせる。

---

## Step 7: 内部レビュー (single-pass、subagent)

セルフチェックは自己採点なので甘くなる (sycophancy)。Step 8 でユーザーに渡す前に、`assign-agent-skill-evaluator` を **subagent で 1 回だけ** 走らせて HIGH + MEDIUM 指摘を反映する。

- **Skill ツールで起動する**: skill = `assign-agent-skill-evaluator`、args = 対象スキルディレクトリのパス (例: `.claude/skills/<prefix-name>/`)
- 返却された eval JSON の `feedback_structured.high` と `feedback_structured.medium` を読み、**HIGH + MEDIUM 指摘を SKILL.md / 補助ファイルに直接修正**として反映する
- **LOW のみ記録だけ** — Step 8 でユーザーに「未反映」として提示し、判断を仰ぐ

理由: skill-creator が同一コンテキストで自己評価すると ref への迎合 (sycophancy) が起きて甘くなる。subagent で別コンテキストにして初見で読ませる。1 パスで止めるのは、HIGH + MEDIUM の取りこぼしを 0 にすれば設計上の致命傷と整合性問題は避けられるからで、LOW (style 寄りの細部) はユーザー判断に委ねる。

---

## Step 8: ユーザーに提示

完成した成果物を提示:

1. **軸判定** (A/B/C/Role) と **prefix 導出** (決定木の辿り方)
2. **SKILL.md** プレビュー
3. **補助ファイル** (references/ があれば)
4. **Step 7 レビュー結果** — HIGH + MEDIUM 反映済みの内容と、未反映で残った LOW 指摘 (ユーザー判断を仰ぐ)


---

## Gotchas

- **内部レビューは 1 パスで止める** — Step 7 は反復ループではない。HIGH + MEDIUM 反映で十分、LOW はユーザー判断に委ねる
- **主観的なスキル (文章スタイル / デザイン) に assertions を強制しない** — 定性評価が適切な場合がある。「出力が良い」は assertion ではない
- **Step 6 のセルフチェックで自己採点しない** — 同一コンテキストの自己評価は sycophancy で甘くなる。本物の採点は Step 7 で `/assign-agent-skill-evaluator` に subagent で投げる (ref-agent-skill §5「`context: fork` の意義」)
- **既存 skill の改善は本 skill の責務外** — improve は別 skill (未実装) のスコープ。誤って本 skill を呼び出された場合は Step 0 適格性チェックで弾き、ユーザーに「対象 skill のディレクトリを直接編集 or 別 skill を待つ」を提示する
