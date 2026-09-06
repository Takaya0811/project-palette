#!/bin/bash
set -euo pipefail
# Eval loop を開始する
# Usage: loop-start.sh <cwd> <max_iterations> <threshold> <session_id> [--agent-id <agent_id>] [--max-wall-minutes <N>]
#
# --max-wall-minutes: wall-clock 上限 (分)。超過すると loop-control が次の hook 発火時に
#   ループを終了する (ended_reason: wall_clock_exceeded)。0 で無効。デフォルト 360。

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

CWD="${1:-.}"
MAX="${2:-12}"
THRESHOLD="${3:-70}"
SESSION_ID="${4:?session_id is required}"

# --- オプション引数 ---
AGENT_ID=""
MAX_WALL_MINUTES="360"
shift 4 || true
while [ $# -gt 0 ]; do
  case "$1" in
    --agent-id)
      AGENT_ID="${2:?--agent-id requires a value}"
      shift 2
      ;;
    --max-wall-minutes)
      MAX_WALL_MINUTES="${2:?--max-wall-minutes requires a value}"
      shift 2
      ;;
    --*)
      echo "ERROR: unknown option: '$1'" >&2
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# --- 入力バリデーション ---
if ! [[ "$MAX" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: max_iterations must be a positive integer, got: '$MAX'" >&2
  exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -gt 100 ]; then
  echo "ERROR: threshold must be an integer 0-100, got: '$THRESHOLD'" >&2
  exit 1
fi

if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
  echo "ERROR: session_id must not contain path separators or '..': '$SESSION_ID'" >&2
  exit 1
fi

# leading zero は --argjson が invalid JSON として拒否するため regex 側で弾く
if ! [[ "$MAX_WALL_MINUTES" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "ERROR: --max-wall-minutes must be a non-negative integer (0 = disabled), got: '$MAX_WALL_MINUTES'" >&2
  exit 1
fi

if [ -n "$AGENT_ID" ]; then
  if [[ "$AGENT_ID" =~ [/\\] ]] || [[ "$AGENT_ID" == *..* ]]; then
    echo "ERROR: agent_id must not contain path separators or '..': '$AGENT_ID'" >&2
    exit 1
  fi
fi

if [ ! -d "$CWD" ]; then
  echo "ERROR: Working directory does not exist: $CWD" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$CWD" && pwd)"
BASE_DIR="$PROJECT_DIR/.mso"

if [ -n "$AGENT_ID" ]; then
  SESSION_DIR="$BASE_DIR/agents/$AGENT_ID"
else
  SESSION_DIR="$BASE_DIR/sessions/$SESSION_ID"
fi

# --- Snapshot 機能の検出 ---
# git repo なら refs/eval-loop/<session>[/<agent>] にイテレーション snapshot を作る
SNAPSHOT_ENABLED="false"
SNAPSHOT_REF_PREFIX=""
if (cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1); then
  SNAPSHOT_ENABLED="true"
  if [ -n "$AGENT_ID" ]; then
    SNAPSHOT_REF_PREFIX="refs/eval-loop/$SESSION_ID/$AGENT_ID"
  else
    SNAPSHOT_REF_PREFIX="refs/eval-loop/$SESSION_ID"
  fi
fi

TURNS_DIR="$SESSION_DIR/turns"
STATE_FILE="$SESSION_DIR/state.json"

# 既にアクティブなら警告
if [ -f "$STATE_FILE" ] && [ "$(jq -r '.active' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
  ITER=$(jq -r '.iteration' "$STATE_FILE")
  MMAX=$(jq -r '.max_iterations' "$STATE_FILE")
  echo "Eval loop already active (iteration $ITER/$MMAX). Cancel first with /run-eval-loop-cancel"
  exit 0
fi

# 前回のターン履歴をクリア（同一セッションで再ループ時の残骸を防ぐ）
rm -f "$TURNS_DIR"/turn-*.md "$TURNS_DIR"/turn-*.json 2>/dev/null
mkdir -p "$TURNS_DIR"

# --- write_targets 衝突検知 ---
# 同一 project_dir の他 active セッション/エージェントの write_targets と突合
for other_state in "$BASE_DIR"/sessions/*/state.json "$BASE_DIR"/agents/*/state.json; do
  [ -f "$other_state" ] || continue
  [ "$other_state" = "$STATE_FILE" ] && continue
  OTHER_ACTIVE=$(jq -r '.active // false' "$other_state" 2>/dev/null) || continue
  [ "$OTHER_ACTIVE" = "true" ] || continue
  OTHER_PROJECT=$(jq -r '.project_dir // ""' "$other_state" 2>/dev/null) || continue
  [ "$OTHER_PROJECT" = "$PROJECT_DIR" ] || continue
  OTHER_TARGETS=$(jq -r '(.write_targets // []) | join(", ")' "$other_state" 2>/dev/null) || continue
  if [ -n "$OTHER_TARGETS" ]; then
    OTHER_SID=$(jq -r '.session_id // "unknown"' "$other_state" 2>/dev/null) || OTHER_SID="unknown"
    OTHER_AID=$(jq -r '.agent_id // empty' "$other_state" 2>/dev/null) || OTHER_AID=""
    echo "WARNING: Active session $OTHER_SID${OTHER_AID:+ (agent: $OTHER_AID)} has write_targets: $OTHER_TARGETS" >&2
  fi
done

jq -n \
  --argjson max "$MAX" \
  --argjson threshold "$THRESHOLD" \
  --argjson started_at "$(date +%s)" \
  --argjson max_wall "$MAX_WALL_MINUTES" \
  --arg session_id "$SESSION_ID" \
  --arg agent_id "$AGENT_ID" \
  --arg project_dir "$PROJECT_DIR" \
  --arg turns_dir "$TURNS_DIR" \
  --arg eval_skill "assign-eval-loop-evaluator" \
  --arg snapshot_enabled "$SNAPSHOT_ENABLED" \
  --arg snapshot_ref_prefix "$SNAPSHOT_REF_PREFIX" \
  '{
    loop_type: "eval",
    active: true,
    iteration: 0,
    max_iterations: $max,
    threshold: $threshold,
    started_at: $started_at,
    max_wall_minutes: $max_wall,
    ended_reason: null,
    session_id: $session_id,
    agent_id: (if $agent_id == "" then null else $agent_id end),
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
  }' > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

echo "Eval loop ACTIVATED (max: $MAX, threshold: $THRESHOLD, session: $SESSION_ID${AGENT_ID:+, agent: $AGENT_ID})"
echo "Turns dir: $TURNS_DIR"
echo "State file: $STATE_FILE"
