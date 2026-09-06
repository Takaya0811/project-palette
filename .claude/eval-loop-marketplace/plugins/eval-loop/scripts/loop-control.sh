#!/bin/bash
# loop-control.sh — Stop/SubagentStop hook 共通ロジック
#
# 呼び出し側が以下を設定してから source する。
#   STATE_FILE:  state.json の絶対パス
#   LOOP_LABEL:  ログ用ラベル ("Eval-loop iteration" / "Eval-loop parallel iteration")
#
# HOOK SAFETY: hook は何があっても exit 0 しなければならない。

if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ACTIVE=$(jq -r '.active' "$STATE_FILE" 2>/dev/null) || ACTIVE="false"
if [ "$ACTIVE" != "true" ]; then
  exit 0
fi

ITERATION=$(jq -r '.iteration' "$STATE_FILE" 2>/dev/null) || ITERATION="0"
MAX=$(jq -r '.max_iterations' "$STATE_FILE" 2>/dev/null) || MAX="12"
THRESHOLD=$(jq -r '.threshold // 90' "$STATE_FILE" 2>/dev/null) || THRESHOLD="90"
SCORE=$(jq -r '.latest_score // "null"' "$STATE_FILE" 2>/dev/null) || SCORE="null"
TASK=$(jq -r '.task // "task not set"' "$STATE_FILE" 2>/dev/null) || TASK="task not set"
PHASE=$(jq -r '.phase // "plan"' "$STATE_FILE" 2>/dev/null) || PHASE="plan"
EVAL_ITER=$(jq -r '.evaluated_iteration // "null"' "$STATE_FILE" 2>/dev/null) || EVAL_ITER="null"
STARTED_AT=$(jq -r '.started_at // "null"' "$STATE_FILE" 2>/dev/null) || STARTED_AT="null"
MAX_WALL=$(jq -r '.max_wall_minutes // 0' "$STATE_FILE" 2>/dev/null) || MAX_WALL="0"
REPAIR=$(jq -r '.eval_repair_attempts // 0' "$STATE_FILE" 2>/dev/null) || REPAIR="0"

if [ "$SCORE" != "null" ]; then
  if ! [[ "$SCORE" =~ ^-?[0-9]+$ ]]; then
    SCORE="null"
  fi
fi
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  THRESHOLD="90"
fi
if ! [[ "$ITERATION" =~ ^[0-9]+$ ]]; then
  ITERATION="0"
fi
if ! [[ "$MAX" =~ ^[0-9]+$ ]]; then
  MAX="20"
fi
if ! [[ "$REPAIR" =~ ^[0-9]+$ ]]; then
  REPAIR="0"
fi

NOW=$(date +%s)

# --- Never-started cleanup ---
# SubagentStart hook は全 subagent に active=true の state を事前作成するが、
# ループを使わない subagent では誰も deactivate せず active 残骸が無限に溜まる
# (実測 3000+ 件)。task が書かれないまま終了した state はループ未開始なので
# ここで明示的に閉じる (障害クラス: 観測性 — 残骸を「終了済み + 理由」に変換)。
# 猶予 10 分: loop-start 直後・task 書き込み前に応答が切れた正規ループを誤殺しない
# (started_at を持たない legacy state は従来どおり即クローズ)。
if { [ -z "$TASK" ] || [ "$TASK" = "task not set" ]; } && [ "$ITERATION" = "0" ] && [ "$SCORE" = "null" ]; then
  if [[ "$STARTED_AT" =~ ^[0-9]+$ ]] && [ $((NOW - STARTED_AT)) -lt 600 ]; then
    exit 0
  fi
  jq '.active = false | .ended_reason = "never_started"' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  exit 0
fi

# --- Wall-clock budget ---
# iteration 数とは独立した暴走天井 (障害クラス: 資源上限)。超過したらループを終了し
# ended_reason に記録する。例外: ちょうど threshold を満たした評価が来ている場合は
# 成功として下の通常パスに任せる (wall_clock_exceeded と誤ラベルしない)。例外の成立には
# evaluated_iteration の整合も要求する — 不整合 state を例外が素通しし続けると
# double-fire guard との組合せで wall-clock が永遠に執行されないため。
# started_at / max_wall_minutes を持たない legacy state では何もしない。
if [[ "$STARTED_AT" =~ ^[0-9]+$ ]] && [[ "$MAX_WALL" =~ ^[1-9][0-9]*$ ]]; then
  if [ $((NOW - STARTED_AT)) -ge $((MAX_WALL * 60)) ]; then
    if [ "$PHASE" = "eval" ] && [ "$SCORE" != "null" ] && [ "$SCORE" -ge "$THRESHOLD" ] 2>/dev/null \
       && { [ "$EVAL_ITER" = "null" ] || [ "$EVAL_ITER" = "$ITERATION" ]; }; then
      : # threshold met on this very evaluation — let the success path label it
    else
      jq '.active = false | .ended_reason = "wall_clock_exceeded"' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
        && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
      exit 0
    fi
  fi
fi

# --- Phase gate ---
# Stop hook fires after every response. Only act when a complete
# plan→generator→evaluator cycle has finished (phase="eval").
# Mid-cycle responses (phase="plan" or "generator") are silently ignored.
if [ "$PHASE" != "eval" ]; then
  exit 0
fi

# --- Invalid eval output repair ---
# phase=eval なのに score が整数でない = evaluator が壊れた JSON を書いたか score の
# 書き戻しが失敗した (障害クラス: 境界の入力検証)。静かに停滞させず修復指示付きで
# block する。修復が 2 回続けて失敗したらループを終了する (無限 block 防止)。
if [ "$SCORE" = "null" ]; then
  if [ "$REPAIR" -ge 2 ]; then
    jq '.active = false | .ended_reason = "invalid_eval_output"' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
      && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
    exit 0
  fi
  jq '.eval_repair_attempts = ((.eval_repair_attempts // 0) + 1)' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  REPAIR_TURNS_DIR=$(jq -r '.turns_dir // ""' "$STATE_FILE" 2>/dev/null) || REPAIR_TURNS_DIR=""
  EVAL_FILE_HINT="$REPAIR_TURNS_DIR/turn-$(printf '%03d' "$ITERATION")-eval.json"
  REASON="[$LOOP_LABEL $ITERATION/$MAX | INVALID EVAL OUTPUT]
STATE_FILE=$STATE_FILE
The evaluation phase finished but latest_score is not a valid integer — the evaluator likely wrote invalid JSON or the score write-back failed.
Repair now: (1) read $EVAL_FILE_HINT and check it contains an integer .score 0-100; (2) if broken, fix the file or re-run the evaluator; (3) write the score back to latest_score in STATE_FILE (keep phase=\"eval\"), then end your response."
  jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
  exit 0
fi

# --- Double-fire guard ---
# Prevent acting twice on the same completed evaluation cycle.
# evaluated_iteration is set atomically with the score by the orchestrator.
# After the hook increments iteration, it no longer matches evaluated_iteration.
if [ "$EVAL_ITER" != "null" ] && [ "$EVAL_ITER" != "$ITERATION" ]; then
  exit 0
fi

# スコアが閾値以上 → 完了
if [ "$SCORE" != "null" ] && [ "$SCORE" -ge "$THRESHOLD" ] 2>/dev/null; then
  jq '.active = false | .ended_reason = "threshold_met"' "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  exit 0
fi

NEXT_ITERATION=$((ITERATION + 1))

# max 到達 → 終了
if [ "$NEXT_ITERATION" -ge "$MAX" ]; then
  jq --argjson i "$NEXT_ITERATION" '.active = false | .iteration = $i | .ended_reason = "max_iterations"' \
    "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  exit 0
fi

# iteration 更新 + phase/score/evaluated_iteration/repair リセット（次サイクルの plan 開始に備える）
jq --argjson i "$NEXT_ITERATION" '.iteration = $i | .phase = "plan" | .latest_score = null | .evaluated_iteration = null | .eval_repair_attempts = 0' \
  "$STATE_FILE" > "$STATE_FILE.tmp.$$" \
  && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null

# 前回レビューのフィードバック
TURNS_DIR=$(jq -r '.turns_dir' "$STATE_FILE" 2>/dev/null) || TURNS_DIR=""
PREV_EVAL=""
if [ -n "$TURNS_DIR" ]; then
  PREV_FILE="$TURNS_DIR/turn-$(printf '%03d' "$ITERATION")-eval.json"
  # fallback for legacy review.json
  if [ ! -f "$PREV_FILE" ]; then
    PREV_FILE="$TURNS_DIR/turn-$(printf '%03d' "$ITERATION")-review.json"
  fi
  if [ -f "$PREV_FILE" ]; then
    PREV_EVAL=$(jq -r '.feedback // "no feedback"' "$PREV_FILE" 2>/dev/null) || PREV_EVAL=""
  fi
fi

REASON="[$LOOP_LABEL $NEXT_ITERATION/$MAX | current score: ${SCORE:-none} out of 100 (passing threshold: $THRESHOLD, NOT the max)]
STATE_FILE=$STATE_FILE
TURNS_DIR=$TURNS_DIR
Continue the plan->generator->eval loop. Task: $TASK"

if [ -n "$PREV_EVAL" ]; then
  REASON="$REASON
Previous eval feedback: $PREV_EVAL"
fi

# デバッグログ
if [ -d "$(dirname "$(dirname "$STATE_FILE")")/.." ]; then
  LOG_DIR="$(cd "$(dirname "$(dirname "$STATE_FILE")")/.." && pwd)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $HOOK_TYPE loop-control: block iteration=$NEXT_ITERATION score=$SCORE" >> "$LOG_DIR/subagent-debug.log" 2>/dev/null
fi

# Stop / SubagentStop 共通: トップレベルの decision で block する
jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}' 2>/dev/null || exit 0
