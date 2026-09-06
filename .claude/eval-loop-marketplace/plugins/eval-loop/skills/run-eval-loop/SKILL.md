---
name: run-eval-loop
template: core
description: 品質スコアが目標に達するまで自律ループで改善したい場面で発動。「品質ループ」で発動。
user-invocable: true
argument-hint: "<task description> [criteria: 正確性,可読性,...] [threshold: 70] [max: 12]"
allowed-tools: "*"
---

# Eval Loop

あなたはオーケストレーターです。計画をインラインで作成し、assign-eval-loop-generator → assign-eval-loop-evaluator の 2 フェーズを制御し、品質基準を満たすまでループします。

**Planner スキルは使わない。** 計画はオーケストレーター自身が書く。複雑なタスクで詳細計画が要るときは、事前に詳細計画を作成し、その成果物を task に含めてから起動すること。

**絶対ルール: 1イテレーション内の全フェーズ (計画作成 → assign-eval-loop-generator → assign-eval-loop-evaluator → スコア更新 → 判定) は、1回の応答ターンで途切れなく実行すること。フェーズ間でテキストだけ出力して応答を終了してはならない。Skill 展開後は、そのスキルの作業を完了したら即座に次のツール呼び出しに進む。**

## Step 1: 入力解析

ユーザーの入力 `$ARGUMENTS` から以下を抽出:

| 項目 | デフォルト | 例 |
|------|-----------|-----|
| **task** | (必須) | "skillAを実装する" |
| **criteria** | オーケストレーターがタスクに応じて設定 | "テストカバレッジ、エラーハンドリング、可読性" |
| **threshold** | 70 | 70 |
| **max_iterations** | 12 | 12 |
| **max_wall** | 360 (分、0 で無効) | 720 |
| **generator** | assign-eval-loop-generator | "my-custom-generator" |
| **evaluator** | assign-eval-loop-evaluator | "my-custom-evaluator" |

task が不明な場合はユーザーに確認すること。criteria が未指定の場合は、タスクの性質に応じて適切な品質基準を設定する:
- **コードタスク**: 正確性、テストカバレッジ、エラーハンドリング、可読性 など
- **コンテンツタスク**: タスク意図の忠実度、文体・語調の適切さ、構造の自然さ、情報の正確性 など
- **クリエイティブタスク**: 原文のテクスチャ保存、表現の豊かさ、意図の明確さ など

コンテンツ/クリエイティブタスクで「可読性」「簡潔さ」を基準にすると論理的整理に走りやすい。原文のスタイルが重要な場合は「テクスチャ保存」を基準に含めること。

## Step 2: 初期化

UserPromptSubmit hook が `EVAL_LOOP_SESSION_ID=<id>` をコンテキストに注入しています。この値を使います。

**EVAL_LOOP_SESSION_ID が見つからない場合**: ユーザーに「プラグインが正しくインストールされているか確認してください」と案内してください。

```bash
CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-start.sh . <max_iterations> <threshold> <EVAL_LOOP_SESSION_ID>
```

ユーザーが max_wall を指定した場合のみ `--max-wall-minutes <N>` を末尾に付ける (デフォルト 360 分。超過すると Stop hook がループを終了し `ended_reason: wall_clock_exceeded` を記録する)。

スクリプトが以下を出力します:
```
Eval loop ACTIVATED (max: N, threshold: N, session: xxx)
Turns dir: /absolute/path/to/turns
State file: /absolute/path/to/state.json
```

**"State file:" の行から STATE_FILE のパスを取得して、以降すべてそのパスを使うこと。**

次に state.json に task/criteria を書き込みます:

```bash
jq --arg task "<task>" --arg criteria "<criteria>" \
   --arg gen "<generator_skill>" --arg eval "<evaluator_skill>" \
   '.task=$task | .criteria=$criteria | .generator_skill=$gen | .evaluator_skill=$eval' \
   "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"
```

`<generator_skill>` と `<evaluator_skill>` はユーザー指定値、未指定なら state.json のデフォルト値をそのまま使う（jq コマンドから省略してよい）。

## Step 3: イテレーションプロトコル

**各イテレーションはオーケストレーターの計画作成から始まる。**

### 3a. 状態読み込み + 計画作成

**1回の bash で状態を読み込む:**

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
TASK=$(jq -r '.task' "$STATE_FILE")
CRITERIA=$(jq -r '.criteria' "$STATE_FILE")

PREV_EVAL=""
if [ "$ITER" -gt 0 ]; then
  PREV_ITER=$((ITER - 1))
  PREV_EVAL_FILE="$TURNS_DIR/turn-$(printf '%03d' $PREV_ITER)-eval.json"
  [ -f "$PREV_EVAL_FILE" ] && PREV_EVAL=$(cat "$PREV_EVAL_FILE")
fi

echo "ITER: $ITER"
echo "TASK: $TASK"
echo "CRITERIA: $CRITERIA"
echo "TURNS_DIR: $TURNS_DIR"
[ -n "$PREV_EVAL" ] && echo "PREV_EVAL: $PREV_EVAL"
```

**即座に Write ツールで計画ファイルを作成する:**

ファイルパス: `{TURNS_DIR}/turn-{NNN}-plan.md` (NNN = iteration を3桁ゼロパディング)

```markdown
## Goal

{このイテレーションで達成すること。1-2文}

## Analysis

{iteration 0 なら task の要約。iteration > 0 なら eval feedback の要点と改善方針}

## Changes

{具体的な変更リスト}

- {変更1}: {理由}
- {変更2}: {理由}

## Acceptance Criteria

{観測可能な条件}

- [ ] {基準1}
- [ ] {基準2}
```

**計画作成のポイント:**
- **iteration 0**: task と criteria から初期計画を立てる。コードベースの詳細な探索はしない — それは Generator の仕事
- **iteration > 0**: eval feedback を分析し、何を改善すべきかの方針を書く。task の本来の目的からの逸脱に注意する (T-2.2)
- **戦略的な方向転換は明確に書く。** eval feedback に対してアプローチをどう変えるかの判断がこの計画の核心
- **Acceptance Criteria は Generator の自己チェック用であって、Evaluator の評価軸ではない。** Evaluator は task と criteria を主軸に絶対評価する (C-3 確証バイアス回避)。plan の項目に過剰に最適化する誘惑を避ける

### 3b. write_targets 更新

計画作成後、計画の Changes から変更対象ファイルを抽出し、state.json の `write_targets` を更新する。

**粒度**: ファイルパス単位。ディレクトリ単位では粗すぎ、行単位では細かすぎる。計画の Changes に登場する具体的なファイルパス（project_dir からの相対パス）をそのまま使う。

```bash
STATE_FILE="<STATE_FILE>"
# 計画の Changes から変更対象ファイルパス（相対パス）をリストアップし JSON 配列にする
# 例: ["${CLAUDE_PLUGIN_ROOT}/skills/foo/SKILL.md", ".claude/scripts/bar.sh"]
TARGETS='["<file1>", "<file2>"]'
jq --argjson targets "$TARGETS" '.write_targets = $targets' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
```

### 3c. Generator コンテキスト作成 + 起動

**1回の bash で phase 更新と Generator コンテキストを作成する:**

`task` 原文を必ず同梱すること (T-2.2: 目標再注入)。plan は task を圧縮した派生物にすぎず、ドリフトを継承する。

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
SESSION_DIR="$(dirname "$STATE_FILE")"
PLAN_CONTENT=$(cat "$TURNS_DIR/turn-$(printf '%03d' $ITER)-plan.md")
GEN_SKILL=$(jq -r '.generator_skill // "assign-eval-loop-generator"' "$STATE_FILE")

jq --arg phase "plan" --arg plan "$TURNS_DIR/turn-$(printf '%03d' $ITER)-plan.md" \
  '.phase=$phase | .latest_plan=$plan' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

jq -n \
  --arg project_dir "$(jq -r '.project_dir' "$STATE_FILE")" \
  --arg task "$(jq -r '.task' "$STATE_FILE")" \
  --arg plan "$PLAN_CONTENT" \
  --arg criteria "$(jq -r '.criteria' "$STATE_FILE")" \
  --argjson iteration "$ITER" \
  --arg turns_dir "$TURNS_DIR" \
  '{project_dir:$project_dir, task:$task, plan:$plan, criteria:$criteria, iteration:$iteration, turns_dir:$turns_dir}' \
  > "$SESSION_DIR/generator-context.json"
echo "SKILL:$GEN_SKILL"
echo "CONTEXT:$SESSION_DIR/generator-context.json"
```

**即座に Skill ツールで Generator を起動:**
- **skill**: bash 出力の `SKILL` 行の値
- **args**: `CONTEXT` 行のパス

### 3d. Evaluator コンテキスト作成 + 起動

Generator 完了後、**1回の bash で phase 更新と Evaluator コンテキストを作成:**

evaluator skill ディレクトリの `eval-schema.json` (artifact、spec: `ref-skill-component-design` §13) を読んで `breakdown_keys` / `score_field` / `extras` を解決する。eval-schema.json 不在の場合は criteria 文字列から動的生成 (旧動作フォールバック)。

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
SESSION_DIR="$(dirname "$STATE_FILE")"
EVAL_SKILL=$(jq -r '.evaluator_skill // "assign-eval-loop-evaluator"' "$STATE_FILE")
PLAN_CONTENT=$(cat "$TURNS_DIR/turn-$(printf '%03d' $ITER)-plan.md")
CRITERIA_VAL=$(jq -r '.criteria' "$STATE_FILE")
SCHEMA_FILE="${CLAUDE_PLUGIN_ROOT}/skills/${EVAL_SKILL}/eval-schema.json"

# eval-schema.json から breakdown_keys / score_field を解決 (artifact 優先、不在時は動的)
if [ -f "$SCHEMA_FILE" ]; then
  SCORE_FIELD=$(jq -r '.score_field // "quality.overall"' "$SCHEMA_FILE")
  BREAKDOWN_KEYS_JSON=$(jq -c '[.breakdown_keys[]?.key]' "$SCHEMA_FILE")
  IS_DYNAMIC=$(jq -r 'if (.breakdown_keys | length) == 0 then "true" else "false" end' "$SCHEMA_FILE")
  SCHEMA_ORIGIN="artifact"
else
  SCORE_FIELD="quality.overall"
  BREAKDOWN_KEYS_JSON="[]"
  IS_DYNAMIC="true"
  SCHEMA_ORIGIN="fallback"
fi

# 動的なら criteria 文字列を breakdown キー指示に使う
if [ "$IS_DYNAMIC" = "true" ]; then
  KEY_INSTRUCTION="quality.breakdown のキーは criteria 引数 ('${CRITERIA_VAL}') の各項目で固定し iteration 間で不変"
else
  KEY_INSTRUCTION="quality.breakdown のキーは eval-schema.json で定義された固定キー (${BREAKDOWN_KEYS_JSON}) を使い iteration 間で不変"
fi

jq '.phase="generator"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

EVAL_FILE="$TURNS_DIR/turn-$(printf '%03d' $ITER)-eval.json"
OUTPUT_CONTRACT=$(jq -n \
  --arg ef "$EVAL_FILE" \
  --arg score_field "$SCORE_FIELD" \
  --argjson breakdown_keys "$BREAKDOWN_KEYS_JSON" \
  --arg key_instruction "$KEY_INSTRUCTION" \
  --arg schema_origin "$SCHEMA_ORIGIN" \
  '{
    eval_file: $ef,
    instructions: ("成果物を task と criteria に基づいて絶対評価する。score = " + $score_field + " と一意に定義する。" + $key_instruction + "。新しい観点は feedback に書き、breakdown のキーには加えない。plan は実装確認の参考であって、評価軸の引用元にしない (期待される答えとして読まない)。結果を eval_file に JSON で書き込む。"),
    score_field: $score_field,
    breakdown_keys: $breakdown_keys,
    schema_origin: $schema_origin,
    schema: {
      score: "integer 0-100 score_field と同値の総合スコア",
      quality: {overall: "integer 0-100 task と criteria への絶対適合度", breakdown: "breakdown_keys (空なら criteria 引数) を固定キーとした 0-100 の連想配列。iteration 間でキー不変"},
      plan_implementation: {overall: "integer 0-100 plan の Changes が実装された割合 (補助指標、score 算出には使わない)", notes: "string 未実装項目のメモ"},
      feedback: "string 具体的な改善指示。task の本来の目的への適合を最優先で書く。次イテレーションの計画に使われる",
      passed: "boolean score >= threshold",
      evaluator_skill: "string 自分の skill 名"
    }
  }')

jq -n \
  --arg project_dir "$(jq -r '.project_dir' "$STATE_FILE")" \
  --arg task "$(jq -r '.task' "$STATE_FILE")" \
  --arg criteria "$CRITERIA_VAL" \
  --argjson threshold "$(jq -r '.threshold' "$STATE_FILE")" \
  --arg plan "$PLAN_CONTENT" \
  --arg turns_dir "$TURNS_DIR" \
  --argjson iteration "$ITER" \
  --argjson output_contract "$OUTPUT_CONTRACT" \
  '{project_dir:$project_dir, task:$task, criteria:$criteria, threshold:$threshold, plan:$plan, turns_dir:$turns_dir, iteration:$iteration, output_contract:$output_contract}' \
  > "$SESSION_DIR/evaluator-context.json"
echo "SKILL:$EVAL_SKILL"
echo "SCHEMA_ORIGIN:$SCHEMA_ORIGIN"
echo "CONTEXT:$SESSION_DIR/evaluator-context.json"
```

**即座に Skill ツールで Evaluator を起動:**
- **skill**: bash 出力の `SKILL` 行の値
- **args**: `CONTEXT` 行のパス

Evaluator が `output_contract.eval_file` に評価結果を書き込む。

### 3e. スコア更新

```bash
STATE_FILE="<STATE_FILE>"
TURNS_DIR="$(jq -r '.turns_dir' "$STATE_FILE")"
ITER=$(jq -r '.iteration' "$STATE_FILE")
EVAL_FILE="$TURNS_DIR/turn-$(printf '%03d' $ITER)-eval.json"
SCORE=$(jq -r '.score' "$EVAL_FILE")
HAS_DEBATE=$(jq -r 'if .debate then "yes" else "no" end' "$EVAL_FILE")
if [ "$HAS_DEBATE" = "yes" ]; then
  SIDE_A=$(jq -r '.debate.scores.side_a' "$EVAL_FILE")
  SIDE_B=$(jq -r '.debate.scores.side_b' "$EVAL_FILE")
  DISAGREE_COUNT=$(jq -r '[.debate.disagreements[]? | select(.severity == "high")] | length' "$EVAL_FILE")
  echo "DEBATE: side_a=$SIDE_A side_b=$SIDE_B high_disagreements=$DISAGREE_COUNT"
fi
jq --argjson s "$SCORE" --argjson i "$ITER" --arg phase "eval" \
  '.latest_score = $s | .phase=$phase | .evaluated_iteration = $i' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
echo "Score: $SCORE, Threshold: $(jq -r '.threshold' "$STATE_FILE")"
```

**debate フィールドがある場合のスコア調整:**

eval JSON に `debate` フィールドが存在する場合、bash で出力された両者のスコアと争点情報を確認し、**オーケストレーターが最終スコアを決定**する。以下を判断材料にすること:

- **両者の乖離が小さい (10点以内)**: 信頼性が高い。低い方のスコアを基準にしつつ妥当な値を決める
- **両者の乖離が大きい (10点超)**: disagreements の severity と内容を読み、どちらの評価がより妥当か判断する。根拠の強い方に寄せる
- **high severity の争点がある**: その争点の内容を重視し、見落としリスクを考慮して保守的に採点する
- **単純に平均を取らないこと。** 争点の中身を読んで判断する

決定したスコアで state.json を上書きする:

```bash
FINAL_SCORE=<オーケストレーターが決定した 0-100>
jq --argjson s "$FINAL_SCORE" '.latest_score = $s' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
echo "Adjusted Score: $FINAL_SCORE"
```

### 3e-2. ベストスコア追跡 + snapshot 保存

スコア確定後 (debate 調整があれば適用後) に best を更新し、作業ツリーを snapshot ref に冷凍保存する:

```bash
STATE_FILE="<STATE_FILE>"
ITER=$(jq -r '.iteration' "$STATE_FILE")
SCORE=$(jq -r '.latest_score' "$STATE_FILE")
jq --argjson s "$SCORE" --argjson i "$ITER" '
  if (.best_score == null or $s > .best_score)
  then .best_score = $s | .best_iteration = $i
  else . end
' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# git repo なら refs/eval-loop/<session>/iter-<N> に snapshot を貼る (best-effort)
CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-snapshot.sh "$STATE_FILE" "$ITER"

echo "Best: iter $(jq -r '.best_iteration' "$STATE_FILE") score $(jq -r '.best_score' "$STATE_FILE")"
```

### 3f. 判定

両ケースで `best: iter N (score X)` を要約に必ず含める。state.json の `snapshot_enabled` が true かつ最終 iter とベストが異なる場合、復元コマンドも添える (write_targets 限定で復元する。全ツリー復元 `git checkout <ref> -- .` は並列ループの他成果物を巻き戻すため使わない):

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-snapshot.sh "$STATE_FILE" <best_iteration> --restore
```

- **score >= threshold**: `/run-eval-loop-cancel` を実行して完了。最終スコア (= quality.overall) と quality.breakdown + plan_implementation + best (+ 必要なら復元コマンド) を報告。
- **score < threshold**: 現在のイテレーション番号・スコア・弱い項目・best を 1-2 行で要約出力し、**それ以上テキストを生成せずに応答を終了する。** Stop hook が `{"decision":"block"}` を返して次イテレーションを自動開始する。max 到達時はこの要約が最終出力となる。

## 重要なルール

1. **Generator / Evaluator は Skill ツールで起動する。** Agent ツールではない。スキル名は state.json の `generator_skill` / `evaluator_skill` から読む。
2. **Planner スキルは起動しない。** 計画はオーケストレーター自身が Write ツールで直接書く。
3. **Evaluator は成果物の絶対品質を評価する。** 改善度ではない。
4. **ターンログ (plan.md, generator.md, eval.json) は必ず保存する。**
5. **score を state.json に書き戻す。**
6. **EVAL_LOOP_SESSION_ID を全スクリプト呼び出しに渡す。**
7. **score < threshold の場合、応答を終了して Stop hook に制御を渡す。** 自分でループを回さない。
8. **STATE_FILE パスは Step 2 で取得したものを使い続ける。**
9. **Eval の feedback はオーケストレーターが次の計画で反映する。** Generator に直接返さない。
10. **フェーズ間で応答を終了しない。** Skill 展開 → 作業完了 → 次フェーズのツール呼び出し、を1回の応答で連続実行する。テキスト出力のみで応答を止めるのは禁止。「Generator完了。」「state更新中。」などのテキストだけ出力して次のツール呼び出しを遅延させると、Stop hook が中間応答で発火しイテレーションが狂う。テキスト確認は挟まず即座に次のツール呼び出しに進むこと。

## Gotchas

- **1ループ = 1 計画 + 1 generator + 1 evaluator。** Planner スキルは使わない。
- **複雑なタスクは事前に詳細計画**を作り、task にその成果物を含めてからループを起動する。
- **並列実行が必要な場合**: `/run-eval-loop-parallel` を使う。
- **`${CLAUDE_PLUGIN_DATA}` は hook 専用。** orchestrator の bash では利用できない。
- **スクリプトパスは `${CLAUDE_PLUGIN_ROOT}/scripts/` を使う。**
- **eval 結果に evaluator 情報を記録する。** Evaluator が `turn-NNN-eval.json` を書く際、`evaluator_skill` フィールドを含めること。スコア連続性の事後分析に必要。
