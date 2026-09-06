#!/bin/bash
# SubagentStop hook: agent_id で .mso/agents/{id}/state.json を参照しループ制御
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat) || exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null) || CWD="."
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null) || AGENT_ID=""

if [ -z "$AGENT_ID" ]; then
  exit 0
fi

if [[ "$AGENT_ID" =~ [/\\] ]] || [[ "$AGENT_ID" == *..* ]]; then
  exit 0
fi

# Used by sourced loop-control.sh
# shellcheck disable=SC2034
STATE_FILE="$CWD/.mso/agents/$AGENT_ID/state.json"
# shellcheck disable=SC2034
LOOP_LABEL="Eval-loop parallel iteration"
# shellcheck disable=SC2034
HOOK_TYPE="SubagentStop"

# デバッグログ
if [ -d "$CWD/.mso" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] SubagentStop fired: agent_id=$AGENT_ID cwd=$CWD" >> "$CWD/.mso/subagent-debug.log" 2>/dev/null
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=loop-control.sh
source "$SCRIPT_DIR/loop-control.sh"
