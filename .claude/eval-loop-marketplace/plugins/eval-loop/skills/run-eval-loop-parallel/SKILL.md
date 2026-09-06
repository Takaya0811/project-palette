---
name: run-eval-loop-parallel
template: core
description: 複数の品質ループを同時に走らせたい場面で発動。「並列ループ」で発動。
user-invocable: true
argument-hint: "<task1 threshold:70; task2 threshold:70 -- semicolon separated>"
allowed-tools: "*"
---
# Eval Loop Parallel

複数の eval ループ (2フェーズ: Generator → Evaluator、orchestrator が planner を兼任) を **並列に** 実行し、結果を統合して報告します。各タスクは独立した subagent orchestrator として spawn され、SubagentStop hook によってループが制御されます。

## Step 1: 入力解析

ユーザーの入力 `$ARGUMENTS` からタスクリストを抽出する。セミコロン `;` で区切られた複数タスク:

```
例: "UIを磨いて70点; APIのエラーハンドリングを70点; ドキュメントを整備して70点"
```

各タスクから以下を特定:
- **task**: 何をするか
- **criteria**: 品質基準 (未指定ならタスク種別に応じて自動設定: コードなら正確性・テストカバレッジ等、コンテンツなら意図忠実度・テクスチャ保存等)
- **threshold**: 目標スコア (指定なければ 70)
- **max_iterations**: 最大イテレーション (デフォルト 12)

## Step 2: 並列 Subagent Orchestrator の spawn

**各タスクに対して Agent ツールで orchestrator subagent を spawn する。独立したタスクは必ず同一メッセージ内で並列に spawn すること。全 subagent は `model: "opus"` を指定すること。**

各 subagent の prompt には以下の **完全なプロトコル** を含めること。subagent は SKILL.md を読めないため、prompt がすべての指示を含む必要がある。

**注意:** prompt テンプレート内の `<EVAL_LOOP_STATE>` 等は SubagentStart hook が subagent のコンテキストに注入する値。parent は解決できないため、テンプレートの説明文をそのまま渡す。subagent 自身がコンテキストから読み取って使う。

各 subagent への prompt テンプレート:

```
あなたは Eval loop の orchestrator（兼 planner）です。SubagentStop hook があなたのループを制御します。

## 初期化

SubagentStart hook があなたの会話コンテキストに以下を注入しています:
- `EVAL_LOOP_AGENT_ID=<実際のID>`
- `EVAL_LOOP_STATE=<state.json の絶対パス>`
- `EVAL_LOOP_TURNS_DIR=<turns ディレクトリの絶対パス>`

state.json は hook が自動作成済みです。スクリプトの実行は不要です。
STATE_FILE=<EVAL_LOOP_STATE の値>、TURNS_DIR=<EVAL_LOOP_TURNS_DIR の値> として以降使うこと。

task/criteria/threshold/max_iterations/session_id を書き込む:
jq --arg task "<task>" --arg criteria "<criteria>" \
   --argjson max <max_iterations> --argjson threshold <threshold> \
   --arg sid "<session_id>" \
   '.task=$task | .criteria=$criteria | .max_iterations=$max | .threshold=$threshold | .session_id=$sid' \
   "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"

## イテレーション再開（2回目以降）

SubagentStop hook がブロックすると、新しいターンが開始される。
ブロックメッセージに `STATE_FILE=<パス>` と `TURNS_DIR=<パス>` が含まれている。
**これらのパスを読み取り、以降のコマンドで使うこと。初期化を再度実行しないこと。**

## イテレーション (毎ターン実行)

### a. 状態読み込み + 計画立案（orchestrator が planner を兼任）
1. state.json を読む: jq '.' "<STATE_FILE>"
   **ITER = state.json の `.iteration` の値 (0 始まり)。turn 番号 NNN = ITER を3桁ゼロパディング (printf '%03d' "$ITER")。** iteration を自分で増減しないこと (SubagentStop hook が block 時に増やす)。evaluated_iteration には必ずこの ITER を書く — 1 始まりで数えると hook の double-fire guard (evaluated_iteration != iteration で無視) に弾かれ、終了処理が永遠に走らない。
2. 前回の eval feedback があれば $TURNS_DIR/turn-{前回NNN}-eval.json を読む
3. task, criteria, 前回フィードバックに基づき、このイテレーションの計画を立案する
4. 計画を $TURNS_DIR/turn-{NNN}-plan.md に Write で書き込む
   - 何を作成/変更するか
   - Generator への具体的な指示
   - Acceptance Criteria（完了条件）
5. 計画の Changes から変更対象ファイル (project_dir からの相対パス) を抽出し write_targets を更新する (並列ループの衝突検知と snapshot 復元の対象限定に使われる):
   jq --argjson targets '["<file1>", "<file2>"]' '.write_targets = $targets' "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"

### b. Generator 起動
Generator コンテキスト JSON を作成して Skill ツールで起動:
- skill: state.json の `generator_skill` の値
- args: <generator-context.json のパス>

コンテキスト JSON には project_dir, **task**, plan (plan.md の全文), criteria, iteration, turns_dir を含める。**task** は state.json の task フィールド (T-2.2 目標再注入: plan は task を圧縮した派生物にすぎずドリフトを継承するため、generator にも task 原文を必ず同梱する)。
Generator が $TURNS_DIR/turn-{NNN}-generator.md に直接書き込む。orchestrator は保存不要。

phase を更新:
jq '.phase = "generator"' "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"

### c. Evaluator 起動

**eval-schema 解決** (固定キー evaluator 対応):

```bash
EVAL_SKILL=$(jq -r '.evaluator_skill' "<STATE_FILE>")
SCHEMA_FILE="${CLAUDE_PLUGIN_ROOT}/skills/${EVAL_SKILL}/eval-schema.json"
if [ -f "$SCHEMA_FILE" ]; then
  SCORE_FIELD=$(jq -r '.score_field // "quality.overall"' "$SCHEMA_FILE")
  BREAKDOWN_KEYS_JSON=$(jq -c '[.breakdown_keys[]?.key]' "$SCHEMA_FILE")
  IS_DYNAMIC=$(jq -r 'if (.breakdown_keys | length) == 0 then "true" else "false" end' "$SCHEMA_FILE")
else
  SCORE_FIELD="quality.overall"
  BREAKDOWN_KEYS_JSON="[]"
  IS_DYNAMIC="true"
fi
```

**OUTPUT_CONTRACT 展開** (run-eval-loop §3d と対称):

```bash
EVAL_FILE="$TURNS_DIR/turn-{NNN}-eval.json"
if [ "$IS_DYNAMIC" = "true" ]; then
  KEY_INSTRUCTION="quality.breakdown のキーは criteria 引数の各項目で固定し iteration 間で不変"
else
  KEY_INSTRUCTION="quality.breakdown のキーは eval-schema.json で定義された固定キー (${BREAKDOWN_KEYS_JSON}) を使い iteration 間で不変"
fi
OUTPUT_CONTRACT=$(jq -n \
  --arg ef "$EVAL_FILE" \
  --arg score_field "$SCORE_FIELD" \
  --argjson breakdown_keys "$BREAKDOWN_KEYS_JSON" \
  --arg key_instruction "$KEY_INSTRUCTION" \
  '{
    eval_file: $ef,
    instructions: ("成果物を task と criteria に基づいて絶対評価する。score = " + $score_field + " と一意。" + $key_instruction + "。新しい観点は feedback に書き breakdown には足さない。plan_implementation は補助指標で score 算出に使わない。plan は実装確認の参考であって、評価軸の引用元にしない (期待される答えとして読まない)。結果を eval_file に JSON で書き込む。"),
    score_field: $score_field,
    breakdown_keys: $breakdown_keys,
    schema: {
      score: "integer 0-100 score_field と同値の総合スコア",
      quality: {overall: "integer 0-100 task と criteria への絶対適合度", breakdown: "breakdown_keys (空なら criteria 引数) を固定キーとした 0-100 の連想配列。iteration 間でキー不変"},
      plan_implementation: {overall: "integer 0-100 plan の Changes が実装された割合 (補助指標、score 算出には使わない)", notes: "string 未実装項目のメモ"},
      feedback: "string 具体的な改善指示。task の本来の目的への適合を最優先で書く。次イテレーションの計画に使われる",
      passed: "boolean score >= threshold",
      evaluator_skill: "string 自分の skill 名"
    }
  }')
```

Evaluator コンテキスト JSON を作成して Skill ツールで起動:
- skill: `EVAL_SKILL` の値
- args: <evaluator-context.json のパス>

コンテキスト JSON には project_dir, task, criteria, threshold, plan (plan.md の全文), turns_dir, iteration, output_contract を含める。
output_contract.schema は新 schema フォーマット (score = `${SCORE_FIELD}` と一意同値の 0-100, quality {overall, breakdown}, plan_implementation {overall, notes}, feedback, passed, evaluator_skill)。
output_contract.instructions には以下を明記:
- `score = ${SCORE_FIELD}` と一意同値
- `IS_DYNAMIC=true` なら「quality.breakdown のキーは criteria の各項目で iteration 間固定」
- `IS_DYNAMIC=false` なら「quality.breakdown のキーは eval-schema.json で定義された固定キー (`${BREAKDOWN_KEYS_JSON}`) を使い iteration 間で不変」
- 新観点は feedback に書き breakdown には足さない
- plan_implementation は補助指標で score 算出に使わない
- plan は実装確認の参考であって、評価軸の引用元にしない (期待される答えとして読まない)

Evaluator が output_contract.eval_file に評価結果を書き込む。orchestrator は保存不要。

### d. スコア更新
EVAL_FILE="$TURNS_DIR/turn-{NNN}-eval.json"
SCORE=$(jq -r '.score' "$EVAL_FILE")
jq --argjson s "$SCORE" --argjson i "$ITER" --arg phase "eval" \
  '.latest_score = $s | .phase=$phase | .evaluated_iteration = $i
   | (if (.best_score == null or $s > .best_score) then .best_score = $s | .best_iteration = $i else . end)' \
  "<STATE_FILE>" > "<STATE_FILE>.tmp" && mv "<STATE_FILE>.tmp" "<STATE_FILE>"
CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-snapshot.sh "<STATE_FILE>" "$ITER"

### e. 判定 + 終了処理 (finalize)
両ケースで `best: iter N (score X)` を要約に含める。snapshot_enabled かつ best != 最終 iter なら復元コマンド `bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-snapshot.sh "<STATE_FILE>" <best> --restore` (write_targets 限定復元。全ツリー `git checkout <ref> -- .` は並列時に他ループの成果物を巻き戻すため使わない) も添える。
- score >= threshold (PASS): **応答を終える前に finalize を実行する**:
  CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-cancel.sh "<STATE_FILE>" --reason passed
  state が active=false / ended_reason=threshold_met / iteration 確定 (evaluated_iteration から) になる。これを省くと state が実行中のまま残り、ループ状態一覧で永遠に RUNNING/STALLED と表示され並走 warn が誤発火する。finalize 後、完了を報告して応答を終了。
- score < threshold: スコアと残課題と best を1-2行で要約し、応答を終了する。
  SubagentStop hook が block して次イテレーションを自動開始する。自分でループを回さないこと。
  max_iterations 到達時は hook が自動 finalize する (active=false / ended_reason=max_iterations)。orchestrator 側の処理は不要。

## 採点ルール (Evaluator に伝えること)
- 100点満点。threshold は合格ライン、満点ではない。
- 成果物の絶対品質で評価。改善度ではない。
- **score = quality.overall と一意同値** (新 schema)。task と criteria への絶対適合度が拠り所。
- **quality.breakdown のキーは criteria 項目で iteration 間固定**。新観点は feedback に書き breakdown には足さない (breakdown 安定化ルール)。
- **plan_implementation は補助指標**。plan の Changes が実装された割合を 0-100 で記録。**score 算出には使わない** (plan は task の派生物にすぎず、ドリフトを継承する)。
- feedback は次イテレーションの計画立案に使われる。戦略レベルの示唆も含める。
```

## Step 3: 結果集約

全 subagent が完了したら、各タスクの結果をまとめて報告:
- 各タスク名
- 最終スコア (= quality.overall) と quality.breakdown + plan_implementation
- 完了イテレーション数

state.json は `.mso/agents/{agent_id}/` に保存されているので、以下で結果を取得:
```bash
for f in .mso/agents/*/state.json; do
  [ -f "$f" ] || continue
  jq '{task, active, ended_reason, latest_score, best_score, best_iteration, iteration, threshold}' "$f"
done
```

**finalize backstop**: 完了した subagent のループの state が `active: true` のまま残っている場合 (subagent が Step e の finalize を飛ばした / 強制終了)、auto-detect finalize で畳む (まだ走っている他 fork の state には触れないこと — agent_id の取り違え注意):

```bash
CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-cancel.sh "<該当 state.json のパス>"
```

(latest_score >= threshold なら ended_reason=threshold_met、それ以外は cancelled が記録され、iteration も evaluated_iteration から確定する)

## 終端ライフサイクル (finalize)

3 終端すべてで state が `active=false` + `ended_reason` 正値 + iteration 確定 (evaluated_iteration と整合) になるのが正常。`active=true` のまま残った state はループ状態一覧で実行中として出続け、hook の並走 warn が誤発火する。

| 終端 | 誰が finalize するか | state の終値 |
|---|---|---|
| PASS (score >= threshold) | 各 orchestrator subagent が Step e で `loop-cancel.sh "<STATE_FILE>" --reason passed` | active=false / ended_reason=threshold_met / iteration=evaluated_iteration |
| max_iterations 到達 | SubagentStop hook (loop-control.sh) が自動 | active=false / ended_reason=max_iterations / iteration=max 到達値 |
| 中断 (ユーザー停止) | `/run-eval-loop-cancel` → `loop-cancel.sh` | active=false / ended_reason=cancelled (score>=threshold なら threshold_met) |

## 重要なルール

1. **独立したタスクは必ず並列で spawn する。** 直列にしない。
2. **各 subagent に完全なプロトコルを prompt で渡す。** SKILL.md への参照は使えない。
3. **SubagentStop hook がイテレーション制御を行う。** subagent は score < threshold なら応答を終了するだけでよい。
4. **state は `.mso/agents/{agent_id}/` に自動作成される。** SubagentStart hook が `EVAL_LOOP_STATE` (state.json パス) と `EVAL_LOOP_TURNS_DIR` (turns ディレクトリパス) を注入する。subagent はスクリプトを実行する必要はない。
