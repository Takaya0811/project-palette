#!/bin/bash
# UserPromptSubmit hook: session_id と Eval loop 状態を Claude に注入する
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。
# set -euo pipefail は使わない。jq パースはすべて guard で囲む。

if ! command -v jq &>/dev/null; then
  # jq がなければ何も出力せず正常終了（hook を壊さない）
  exit 0
fi

INPUT=$(cat) || exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null) || CWD="."
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
  exit 0
fi

BASE_DIR="$CWD/.mso"
STATE_FILE="$BASE_DIR/sessions/$SESSION_ID/state.json"

# session_id は常に注入（SKILL.md がスクリプトに渡す用）
# ループ状態があればそれも付加
MSG="EVAL_LOOP_SESSION_ID=$SESSION_ID"

if [ -f "$STATE_FILE" ] && [ "$(jq -r '.active' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
  ITERATION=$(jq -r '.iteration' "$STATE_FILE" 2>/dev/null) || ITERATION="?"
  MAX=$(jq -r '.max_iterations' "$STATE_FILE" 2>/dev/null) || MAX="?"
  SCORE=$(jq -r '.latest_score // "none"' "$STATE_FILE" 2>/dev/null) || SCORE="none"
  THRESHOLD=$(jq -r '.threshold // 90' "$STATE_FILE" 2>/dev/null) || THRESHOLD="90"
  MSG="$MSG | Eval loop active (iteration $ITERATION/$MAX, score: $SCORE/100, target: $THRESHOLD)."

  # write_targets 衝突検知
  MY_TARGETS=$(jq -r '(.write_targets // []) | .[]' "$STATE_FILE" 2>/dev/null) || MY_TARGETS=""
  if [ -n "$MY_TARGETS" ]; then
    PROJECT_DIR=$(jq -r '.project_dir // ""' "$STATE_FILE" 2>/dev/null) || PROJECT_DIR=""
    if [ -n "$PROJECT_DIR" ]; then
      CONFLICT_MSGS=""
      for other_state in "$BASE_DIR"/sessions/*/state.json "$BASE_DIR"/agents/*/state.json; do
        [ -f "$other_state" ] || continue
        [ "$other_state" = "$STATE_FILE" ] && continue
        OTHER_ACTIVE=$(jq -r '.active // false' "$other_state" 2>/dev/null) || continue
        [ "$OTHER_ACTIVE" = "true" ] || continue
        OTHER_PROJECT=$(jq -r '.project_dir // ""' "$other_state" 2>/dev/null) || continue
        [ "$OTHER_PROJECT" = "$PROJECT_DIR" ] || continue
        OTHER_TARGETS=$(jq -r '(.write_targets // []) | .[]' "$other_state" 2>/dev/null) || continue
        [ -n "$OTHER_TARGETS" ] || continue
        # 重複チェック (改行区切りで比較、スペース含みパス対応)
        OVERLAPS=""
        while IFS= read -r my_t; do
          [ -n "$my_t" ] || continue
          while IFS= read -r other_t; do
            [ -n "$other_t" ] || continue
            if [ "$my_t" = "$other_t" ]; then
              OVERLAPS="${OVERLAPS:+$OVERLAPS, }$my_t"
            fi
          done <<< "$OTHER_TARGETS"
        done <<< "$MY_TARGETS"
        if [ -n "$OVERLAPS" ]; then
          OTHER_SID=$(jq -r '.session_id // "unknown"' "$other_state" 2>/dev/null) || OTHER_SID="unknown"
          CONFLICT_MSGS="${CONFLICT_MSGS:+$CONFLICT_MSGS }[CONFLICT] Session $OTHER_SID shares write_targets: $OVERLAPS."
        fi
      done
      if [ -n "$CONFLICT_MSGS" ]; then
        MSG="$MSG | WARNING: write_targets conflict detected. $CONFLICT_MSGS"
      fi
    fi
  fi
fi

# --- Stale loop watchdog ---
# active なのに state.json が長時間更新されていないループは停滞の可能性が高い
# (orchestrator がサイクル途中で応答を終了した、evaluator が死んだ等 — 障害クラス: liveness)。
# state.json は全フェーズ遷移で書き換わるため、mtime を生存信号に使う。ただし generator
# fork の実行中は state が更新されない正規の沈黙があるため、閾値は長め (30 分) に取り、
# 警告も「確認を促す」止まりにする (即 cancel 誘導は健全ループの誤殺を招く)。
# 性能: agents/ 配下は数千 dir に達するため per-file の jq spawn は禁止 (実測 3,357 dir
# で毎プロンプト ~11s)。state は全て jq が書くため '"active": true' の書式は安定 —
# grep -l で active 候補だけに絞ってから個別検査する。
STALE_MIN=30
STALE_CAP=3
STALE_WARNED=0
STALE_EXTRA=0
NOW=$(date +%s)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)" || HOOK_DIR=".claude/scripts"
ACTIVE_CANDIDATES=$(grep -l '"active": true' "$BASE_DIR"/agents/*/state.json 2>/dev/null) || ACTIVE_CANDIDATES=""
while IFS= read -r lstate; do
  [ -n "$lstate" ] || continue
  [ -f "$lstate" ] || continue
  LACTIVE=$(jq -r '.active // false' "$lstate" 2>/dev/null) || continue
  [ "$LACTIVE" = "true" ] || continue
  # task 未設定 = ループ未開始の事前作成 state (SubagentStart が全 subagent に作る)。
  # 警告対象にしない (loop-control の never_started 掃除対象)
  LTASK=$(jq -r '.task // ""' "$lstate" 2>/dev/null) || continue
  { [ -n "$LTASK" ] && [ "$LTASK" != "task not set" ]; } || continue
  # GNU stat を先に試す: BSD stat の -c は無出力で即エラーになるが、GNU stat の -f は
  # filesystem status を stdout に吐いて LMTIME を汚染するため、この順でないと Linux で壊れる
  LMTIME=$(stat -c %Y "$lstate" 2>/dev/null || stat -f %m "$lstate" 2>/dev/null) || continue
  [[ "$LMTIME" =~ ^[0-9]+$ ]] || continue
  AGE_MIN=$(( (NOW - LMTIME) / 60 ))
  [ "$AGE_MIN" -ge "$STALE_MIN" ] || continue
  if [ "$STALE_WARNED" -ge "$STALE_CAP" ]; then
    STALE_EXTRA=$((STALE_EXTRA + 1))
    continue
  fi
  LPHASE=$(jq -r '.phase // "?"' "$lstate" 2>/dev/null) || LPHASE="?"
  LSID=$(jq -r '.session_id // ""' "$lstate" 2>/dev/null) || LSID=""
  WARN="WARNING: eval loop appears STALLED (state: $lstate, phase=$LPHASE, no update for ${AGE_MIN}m)."
  if [ "$lstate" = "$STATE_FILE" ] || [ "$LSID" = "$SESSION_ID" ]; then
    # 自セッション所有: 再開か明示キャンセルを促す
    WARN="$WARN Resume the iteration, or cancel: bash '$HOOK_DIR/loop-cancel.sh' '$lstate'"
  else
    # 他セッション所有: 長い generator フェーズの可能性もあるため cancel は誘導しない
    WARN="$WARN Owned by another session (possibly a long generator phase) — inspect its state file ($lstate) before touching it."
  fi
  MSG="$MSG | $WARN"
  STALE_WARNED=$((STALE_WARNED + 1))
done <<EOF
$STATE_FILE
$ACTIVE_CANDIDATES
EOF
if [ "$STALE_EXTRA" -gt 0 ]; then
  MSG="$MSG | WARNING: ... and $STALE_EXTRA more stalled loop(s) under .mso/"
fi

# plain text 出力 → Claude のコンテキストに追加される
echo "$MSG"
