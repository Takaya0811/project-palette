#!/bin/bash
# SubagentStart hook: subagent 用の state.json を事前作成し、agent_id と state パスを注入する
#
# HOOK SAFETY: exit 0 必須

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat) || exit 0
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null) || exit 0

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

if [[ "$AGENT_ID" =~ [/\\] ]] || [[ "$AGENT_ID" == *..* ]]; then
  exit 0
fi

# session_id は snapshot_ref_prefix (refs/eval-loop/<session>/<agent>) の組み立てに使う。
# 不正値 (path separator / '..') は ref 名汚染になるため空扱いにする (hook は止めない)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
  SESSION_ID=""
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null) || CWD="."
BASE_DIR="$CWD/.mso"

# デバッグログ
if [ -d "$BASE_DIR" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] SubagentStart fired: agent_id=$AGENT_ID" >> "$BASE_DIR/subagent-debug.log" 2>/dev/null
fi

# agent ディレクトリと state.json を事前作成
# LLM が init スクリプトを実行する必要をなくし、確実に agents/ パスに state を配置する
AGENT_DIR="$BASE_DIR/agents/$AGENT_ID"
TURNS_DIR="$AGENT_DIR/turns"
STATE_FILE="$AGENT_DIR/state.json"

mkdir -p "$TURNS_DIR" 2>/dev/null || exit 0

PROJECT_DIR="$(cd "$CWD" && pwd 2>/dev/null)" || PROJECT_DIR="$CWD"

# --- Snapshot 機能の検出 (loop-start.sh の --agent-id 分岐と同じロジック) ---
# git repo なら refs/eval-loop/<session>/<agent> にイテレーション snapshot を作る。
# session_id が取れない場合は refs/eval-loop/agents/<agent> に fallback
# (agent_id は agent 毎に一意なので衝突しない)
SNAPSHOT_ENABLED="false"
SNAPSHOT_REF_PREFIX=""
if (cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1); then
  SNAPSHOT_ENABLED="true"
  if [ -n "$SESSION_ID" ]; then
    SNAPSHOT_REF_PREFIX="refs/eval-loop/$SESSION_ID/$AGENT_ID"
  else
    SNAPSHOT_REF_PREFIX="refs/eval-loop/agents/$AGENT_ID"
  fi
fi

# SubagentStart hook の stdout は JSON でないと subagent context に届かない
# (plain stdout は無視される。hookSpecificOutput.additionalContext のみ反映)
emit_context() {
  jq -n \
    --arg agent_id "$AGENT_ID" \
    --arg state "$STATE_FILE" \
    --arg turns "$TURNS_DIR" \
    '{
      hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: ("EVAL_LOOP_AGENT_ID=" + $agent_id + "\nEVAL_LOOP_STATE=" + $state + "\nEVAL_LOOP_TURNS_DIR=" + $turns)
      }
    }' 2>/dev/null
}

# 既にアクティブな state があればスキップ（上書き防止）
if [ -f "$STATE_FILE" ] && [ "$(jq -r '.active' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
  emit_context
  exit 0
fi

# 旧 turn ログをクリア
rm -f "$TURNS_DIR"/turn-*.md "$TURNS_DIR"/turn-*.json 2>/dev/null

# デフォルト値で state.json を作成（orchestrator が task/criteria/threshold 等を上書きする）
# snapshot/best/write_targets フィールドは loop-start.sh の state schema と揃える
# (loop-snapshot.sh の snapshot/restore と write_targets 衝突検知が fork/parallel 経路でも動くように)
jq -n \
  --arg agent_id "$AGENT_ID" \
  --arg session_id "$SESSION_ID" \
  --arg project_dir "$PROJECT_DIR" \
  --arg turns_dir "$TURNS_DIR" \
  --arg eval_skill "assign-eval-loop-evaluator" \
  --arg snapshot_enabled "$SNAPSHOT_ENABLED" \
  --arg snapshot_ref_prefix "$SNAPSHOT_REF_PREFIX" \
  --argjson started_at "$(date +%s)" \
  '{
    loop_type: "eval",
    active: true,
    iteration: 0,
    max_iterations: 12,
    threshold: 70,
    started_at: $started_at,
    max_wall_minutes: 360,
    ended_reason: null,
    session_id: $session_id,
    agent_id: $agent_id,
    project_dir: $project_dir,
    task: "",
    criteria: "",
    generator_skill: "assign-eval-loop-generator",
    evaluator_skill: $eval_skill,
    latest_score: null,
    evaluated_iteration: null,
    best_score: null,
    best_iteration: null,
    snapshot_enabled: ($snapshot_enabled == "true"),
    snapshot_ref_prefix: $snapshot_ref_prefix,
    turns_dir: $turns_dir,
    phase: "plan",
    latest_plan: null,
    write_targets: [],
    evaluator_history: [{"evaluator": $eval_skill, "from_iteration": 0, "to_iteration": null, "reason": "initial"}]
  }' > "$STATE_FILE.tmp.$$" 2>/dev/null || exit 0
mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null || exit 0

# additionalContext に agent_id と state パスを注入
emit_context
