---
name: assign-multi-evaluator
template: core
description: 複数 evaluator の結果をアンサンブルする ensemble evaluator。run-eval-loop から呼ばれる (internal)。
user-invocable: false
context: fork
agent: general-purpose
model: opus
---

# assign-multi-evaluator

**既存の `assign-*-evaluator` skill を N 個 (2〜5) dispatch し、結果をまとめる dispatcher.** 自身の評価ロジックは持たない。

各 sub-eval は fork で独立に走るため、orchestrator の context を消費しない (= token お得)。判定の独立性と採点の安定性を両立する。

出力 JSON は `assign-eval-loop-evaluator` の `score` / `quality` / `plan_implementation` / `feedback` / `passed` / `evaluator_skill` と**上位互換**。追加の `ensemble` フィールドは存在すれば読まれる (無ければ無視)。

**新 schema 規約** (主軸 evaluator と同じ):
- `score` = `quality.overall` と一意同値 (旧: plan_compliance + quality の重み付き複合は廃止)
- `quality.breakdown` のキーは `criteria` 項目で iteration 間**固定** (新観点は `feedback` に書き、breakdown には足さない)
- `plan_implementation` は補助指標で `score` 算出に**使わない** (旧 `plan_compliance` のように加重合算しない)

## コンテキスト (スキル読み込み時に自動展開)

````
!`cat $ARGUMENTS`
````

## コンテキスト JSON のキー

| キー | 必須 | 内容 |
|------|------|------|
| `project_dir` | ✓ | 作業対象のプロジェクトディレクトリ (絶対パス) |
| `criteria` | ✓ | 品質基準 |
| `threshold` | ✓ | 合格スコア (0-100) |
| `plan` | ✓ | Planner が作成した実行計画 (Markdown 全文) |
| `turns_dir` | ✓ | ターンログの保存先ディレクトリ (絶対パス) |
| `iteration` | ✓ | 現在のイテレーション番号 |
| `output_contract` | ✓ | 出力先と JSON スキーマの仕様 |
| `perspectives` | — | 2〜5 個の sub-evaluator 指定 (下記)。未指定ならデフォルト |
| `aggregation` | — | `conservative_weighted` (既定) / `min` / `weighted_avg` |

### `perspectives` 要素

```json
{
  "skill": "<assign-*-evaluator の skill 名>",
  "name": "<kebab_case の識別子ラベル。集約ログや breakdown のキーになる>",
  "weight": <float, 既定 1.0>,
  "role": "<score (既定) | veto>",
  "criteria_override": "<optional. sub-eval に渡す criteria を差し替えたい場合>"
}
```

**`role` (既定 `score`、後方互換)**:
- **`score`** — 従来どおり。score を加重平均に入れる採点 member。`role` を省略すると全て score 扱い (= 既存呼び出しは挙動不変)。
- **`veto`** — **平均に入れない gate member**。その sub-eval が「不合格」を返したら ensemble の `final_score` を `threshold-1` に cap する (= ループ継続/不合格を強制)。複数モデルの採点アンサンブル + 機能ゲートを**希釈なく両取り**するための役割。典型は `assign-goal-aware-evaluator` (機能 probe veto) を veto member に置く構成。
  - 「不合格」の判定: veto sub-eval の `passed == false`、または `score < threshold` (goal-aware は機能 FAIL 時に自分の score を threshold 未満に cap するので両者一致)。
  - **なぜ平均でなく cap か**: 平均に混ぜると高スコア成果物に薄まって veto が消える (= 防ぎたいグッドハート素通り)。乗算ゲートとして final_score を threshold 未満へ落とすことで、`score` しか読まない `run-eval-loop` の継続判定にも確実に効く。

**制約**:
- **N は 2〜5** (score + veto の合計)。1 以下なら単独 evaluator を使えばよい。6 以上は coordination cost が合わない
- **score member は最低 1 つ必須** (全部 veto だと平均する score が無い)。veto member は 0〜複数
- **`skill` は `assign-` で始まる evaluator skill**。本プラグイン同梱の `assign-eval-loop-evaluator` / `assign-debate-evaluator` を想定。`assign-codex-evaluator` / `assign-goal-aware-evaluator` 等を使う場合はそれらの evaluator skill を別途インストールしておくこと (本プラグインには同梱されない。未存在の skill は Phase 3 の失敗処理で除外される)
- **generator や planner skill は指定禁止** (評価以外を呼ぶと意味が壊れる)

**veto member 構成例** (採点アンサンブル + 機能ゲート。`assign-codex-evaluator` / `assign-goal-aware-evaluator` は本プラグイン非同梱の例示):
```json
[
  {"skill": "assign-eval-loop-evaluator",  "name": "claude-score", "weight": 1.0, "role": "score"},
  {"skill": "assign-codex-evaluator",      "name": "gpt-score",    "weight": 1.0, "role": "score"},
  {"skill": "assign-goal-aware-evaluator", "name": "functional-gate",            "role": "veto"}
]
```

### デフォルト (`perspectives` 未指定時)

```json
[
  {"skill": "assign-eval-loop-evaluator", "name": "claude-standard", "weight": 1.0},
  {"skill": "assign-debate-evaluator",    "name": "debate-standard", "weight": 1.0}
]
```

本プラグイン同梱の 2 evaluator による独立判定 (標準 Claude 評価 + debate 評価)。両方ドメイン不問で使える。debate 側は Codex CLI があれば Codex+Claude、無ければ Advocate/Critic に自動縮退する。GPT を独立 member として混ぜたい場合は `perspectives` に `assign-codex-evaluator` を別途指定する (要インストール)。

## ワークフロー

### Phase 1: コンテキスト解析

1. `$ARGUMENTS` で渡された JSON を読む
2. `perspectives` が無ければ上記デフォルトを採用
3. `aggregation` 未指定なら `conservative_weighted` を採用
4. `perspectives` の要素数が 2〜5 の範囲外なら **停止して失敗報告** (eval_file に `{score: null, error: "..."}` を書いて Phase 7 相当の最小報告)
5. 各 perspective の `skill` が `assign-` で始まるか検証 (生成系や planner を弾く)
6. 各 perspective の `role` を解決 (未指定は `score`)。**score member が 0 なら停止して失敗報告** (`error: "no score member"`)。score member 群と veto member 群に振り分ける

### Phase 2: Sub-evaluator を Skill tool で直列 dispatch

**Skill tool は同期かつ直列実行** (Skill → Skill は fork 内でも呼べる)。各 perspective について順に Skill tool を呼び、1 つ完了してから次へ。

各 sub-eval に渡す context は元 context のコピーから以下を **除去 + 差し替え**:

- **除去**: `perspectives` / `aggregation` (これらは multi-evaluator 専用で sub-eval は読まない。混入させない)
- **差し替え**: `output_contract.eval_file` = `{turns_dir}/turn-{NNN}-sub-{idx}-{name}.json` (sub 毎に別ファイル。NNN は iteration の 3 桁ゼロパディング、idx は perspectives 配列の 0 始まり index)
- **差し替え (任意)**: `criteria` = `perspective.criteria_override` があればそれ、無ければ元 criteria

sub-context を `{turns_dir}/turn-{NNN}-sub-{idx}-{name}-ctx.json` に Write してから、Skill tool で以下を実行:

- **skill**: `perspective.skill` の値
- **args**: sub-context ファイルの絶対パス

Skill 呼び出しは同期でブロックする。sub-eval が eval_file を書いて制御が戻ったら次の perspective へ進む。

### Phase 3: Sub-eval 結果の収集

各 sub-eval の `eval_file` を Read。各 JSON から以下を取り出す:

- `score` (0-100、新 schema では `quality.overall` と同値)
- `quality.overall` (0-100、`score` と同値だが互換性のため両方保持)
- `quality.breakdown` (criteria 項目別スコア。**集約のメインソース**)
- `plan_implementation.overall` (0-100、補助指標。**集約には独立フィールドとしてのみ保持し、`score` の重み付けには使わない**)
- `plan_implementation.notes` (任意のメモ)
- `feedback`

**互換受理**: sub-eval が旧 schema (`plan_compliance.{overall,items}`) を返してきた場合、`plan_implementation.overall` は `plan_compliance.overall` に、`notes` は `plan_compliance.items` の未充足項目を文字列化したものにフォールバックする。

**失敗した sub-eval の扱い**:
- ファイルが存在しない / 空 / `score` が null → その perspective を集約から除外し、`concerns: ["sub-eval <name> failed"]` を記録
- 全 perspective が失敗した場合は停止して eval_file に error を書く
- 1 つでも成功すれば残りで続行 (但し実効 perspective 数が 1 になったら警告をログに残す)

### Phase 4: Disagreement 検出と集約スコア算出

**集約のメインソースは各 score member sub-eval の `score` (= `quality.overall`)**。**veto member は平均に含めない** (Phase 4.5 の gate で別途処理)。`plan_implementation.overall` は集約に独立フィールドとして保持するが、`final_score` の算出には**使わない** (新 schema 規約: `score` = `quality.overall` 同値)。

収集した **score member の** score 分布:

- `min_score` / `max_score` / `spread = max - min`
- `weighted_avg = Σ(score × weight) / Σ(weight)` (失敗 perspective は除外)

**Disagreement severity**:
- `spread > 25` → `high`
- `15 < spread <= 25` → `medium`
- `spread <= 15` → `low` (実質合意)

**`aggregation` モード**:

- **conservative_weighted** (既定):
  - 実効 perspective 数 `N = 成功した perspective 数`
  - **`N == 1` の場合**: `final_score = round(weighted_avg)` (= 生き残った1つの score)。penalty は計算しない (独立観点が無いので懲罰の前提が崩れる)
  - **`N >= 2` の場合**:
    - `base = weighted_avg`
    - `penalty = 0`
    - `spread > 25` → `penalty += (spread - 25) / 2`
    - `min_score < 50` → `penalty += (50 - min_score) / 3`
    - `final_score = max(0, round(base - penalty))`
    - 根拠: 観点間で意見が割れる場合、楽観側に引きずられない

- **min**: `final_score = min_score` (N=1 でも同じ)
- **weighted_avg**: `final_score = round(weighted_avg)` (N に関わらず懲罰なし)

### Phase 4.5: veto gate (veto member があるときだけ)

score member から算出した `final_score` に対し、veto member の判定を**乗算ゲート**として適用する (平均には混ぜない):

```
veto_failed = veto member のうち 1 つでも (sub.passed == false) または (sub.score < threshold) を満たすものがあれば true
veto_failed が true なら:  final_score = min(final_score, threshold - 1)
```

- 失敗した veto sub-eval (ファイル無し/null) は **gate を発火させない** (環境失敗を品質失敗と混同しない)。`concerns` に記録するに留める。
- veto member が無い / 全員 pass のときは `final_score` 不変 (= 既存挙動)。
- **なぜ `final_score` を cap するのか**: `run-eval-loop` / `-fork` はループ継続を **`score`(=最終 `final_score`) だけ**で判定し eval JSON の `passed` を読まない。よって veto を `passed` だけに置くと発火しない。`final_score` を `threshold-1` に落として初めて gate がループに効く (`assign-goal-aware-evaluator` が自分の score に cap するのと同じ原理を ensemble 段でも適用)。

### Phase 5: quality.breakdown / plan_implementation のマージ

**quality.breakdown のマージ (主軸)**:

- top-level `quality.breakdown` は、各 sub-eval の `quality.breakdown` から**同名キーの加重平均**で作る
- 全 sub-eval を走査して出現する全キーを収集 (和集合)
- 各キーについて、**そのキーを持つ sub-eval のみで** weight 加重平均 (欠損 sub-eval は集約に含めない)
- `quality.overall` は breakdown の加重平均

**キー安定化前提** (新 schema): `quality.breakdown` のキーは `criteria` 項目で iteration 間固定。sub-eval が iteration 内で異なるキーを返してきた場合は和集合で全列挙する。新観点は `feedback` に書き、`breakdown` のキーには足さない (sub-eval 側もこれに従う前提)。

**正規化フォールバック**: key 文字列の末尾記号 `[:：。、.,]` と前後空白を除去してから比較し、一致すれば同キー扱いにする (軽い正規化のみ。大文字小文字や同義語までは吸収しない)。

**plan_implementation のマージ (補助指標、score 算出には使わない)**:

- `plan_implementation.overall` は各 sub-eval の `plan_implementation.overall` の単純平均 (weight 無し、欠損 sub-eval は除外) を整数で
- `plan_implementation.notes` は各 sub-eval の notes を `<sub-eval name>: <notes>` 形式で改行連結。空 notes は省略
- 旧 schema の `plan_compliance.items` は新 schema には**継承しない** (items 単位の集約は廃止)。互換受理した sub-eval の plan_compliance.overall は plan_implementation.overall に流し込む

**score = quality.overall 同値ルール**: top-level の `score` は Phase 4 (+ Phase 4.5 の veto cap) で算出した `final_score` を使う。**identity 維持のため top-level `quality.overall` も `final_score` に揃える** (= penalty / veto cap 適用後の値)。`quality.breakdown` は各 criteria 項目の raw マージ値のまま残す (goal-aware / seo-blog evaluator と同型: overall は cap、breakdown は raw)。これにより `score == quality.overall` の不変条件が penalty・veto cap のもとでも保たれ、breakdown は診断用に raw 値を保持する。

### Phase 6: feedback の統合

以下のフォーマット:

```
[集約スコア: {final_score} / threshold: {threshold}, mode: {aggregation}, spread: {spread}]

## 観点別スコア
- {name1} (skill: {skill1}, weight {w1}): {score1} — {feedback の要点}
- {name2} (skill: {skill2}, weight {w2}): {score2} — {feedback の要点}
- ...

## 主要争点 (disagreements)
- 最低 {name_min}={min_score} vs 最高 {name_max}={max_score} (spread {spread}, severity {sev}): {両者の相違点要約}

## 次イテレーションへの指示
{最低スコア perspective の feedback を重点に、具体的な修正方針}
```

**最低観点の指摘を先頭に出す** ことで、次 Planner が鋭さ減衰側に最適化されるのを防ぐ。

### Phase 7: 最終 eval.json 書き込み

`output_contract.eval_file` に以下を Write:

````
{
  "score": <final_score (= quality.overall と原則同値、Phase 4 の penalty で乖離した場合は score を真値とする)>,
  "quality": {
    "overall": <aggregated 0-100 各 sub-eval の quality.overall の加重平均>,
    "breakdown": {"<criteria 項目 (固定キー)>": <aggregated 0-100>, ...}
  },
  "plan_implementation": {
    "overall": <aggregated 0-100 各 sub-eval の plan_implementation.overall の単純平均、補助指標>,
    "notes": "<sub-eval 別 notes の改行連結>"
  },
  "ensemble": {
    "mode": "<aggregation mode>",
    "perspectives": [
      {
        "name": "<name>",
        "skill": "<skill>",
        "weight": <float>,
        "score": <0-100 | null>,
        "sub_eval_file": "<path>",
        "failed": <bool>
      }
    ],
    "aggregation": {
      "weighted_avg": <float, score member のみ>,
      "min_score": <int>,
      "max_score": <int>,
      "spread": <int>,
      "penalty": <float>,
      "score_member_final": <int, veto cap 適用前の score member 集約値>,
      "veto_failed": <bool>,
      "final_score": <int, veto cap 適用後 (veto_failed なら min(score_member_final, threshold-1))>
    },
    "veto_members": [
      {"name": "<name>", "skill": "<skill>", "passed": <bool|null>, "score": <int|null>, "sub_eval_file": "<path>", "failed": <bool>}
    ],
    "disagreement_severity": "<high|medium|low>"
  },
  "feedback": "<Phase 6 の統合 feedback。veto_failed なら冒頭に veto member の blocker を出す>",
  "passed": <final_score >= threshold>,
  "evaluator_skill": "assign-multi-evaluator"
}
````

### Phase 8: 完了報告

保存パス + 以下を報告:

- `final_score` / `threshold` / `passed`
- 各 perspective の `name=score` 一覧 (失敗があれば `name=FAILED`)
- `spread` と disagreement severity
- 集約モード

## ルール

- **`project_dir` のファイルを変更しない。** 観察と集約のみ
- **自身では評価判定をしない。** 全ての採点は sub-eval 側に委ねる。このスキルは dispatcher + aggregator
- **Skill tool で sub-eval を呼ぶ。** Agent tool は fork 内で使えないので使わない
- **sub-eval の output_contract.eval_file は必ず別パス** にする (互いに上書きしないため)
- **集約は決定論的に算術で行う。** LLM に「どちらが妥当」を再判定させない
- **feedback の先頭は最低観点の指摘** を優先する (veto_failed のときは veto member の blocker を最優先)
- **veto member は平均に入れず gate として final_score を cap する** (Phase 4.5)。`role` 省略は score 扱いで既存挙動不変

## Gotchas

- **Perspectives が 1 個 / 6 個以上 / 空 → 失敗**。Phase 1 で停止。**score member が 0 (全部 veto) も失敗** (平均する score が無い)
- **veto member の sub-eval は score を threshold 未満に cap できる evaluator を使う** (`assign-goal-aware-evaluator` 等)。score を cap しない evaluator を veto に置く場合は、その `passed` フィールドが信頼できることを確認する (gate は `passed==false` も見る)
- **veto sub-eval の環境失敗 (ファイル無し) は gate を発火させない** — 環境失敗で全成果物を不合格にしない。`concerns` 記録のみ
- **`assign-codex-evaluator` は Codex CLI 未インストール環境で失敗する。** その場合そのperspective は除外され、残り 1 つで走る。両方 codex 系など全滅構成を避けること
- **sub-eval 同士が `quality.breakdown` のキーを別の文面で書くと Phase 5 のマージが粗くなる。** 新 schema のキー安定化ルール (criteria 項目を固定キー、新観点は feedback へ) 遵守が前提
- **旧 schema (plan_compliance) を返す sub-eval が混在する場合**は Phase 3 で互換受理し plan_implementation.overall に流し込む。ただし items 単位の集約は廃止したため、旧 schema 由来の細粒度情報は notes に文字列化して残す
- **sub-eval の fork は各自 agent+model の frontmatter に従う。** 多く走らせると時間と cost が嵩む。2 個をデフォルトにしているのはその閾値
- **Skill tool で呼ぶ sub-eval が `context: fork` でないと token 隔離効果が薄れる。** ここで想定する `assign-*-evaluator` 系は既定で fork のはず
