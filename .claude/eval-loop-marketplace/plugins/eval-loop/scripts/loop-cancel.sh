#!/bin/bash
set -euo pipefail
# Eval loop を finalize する (cancel / PASS / max_iterations の終端を一本化)
# Usage: loop-cancel.sh <state_file> [--reason <reason>] [--purge-snapshots]
#    or: loop-cancel.sh <cwd> <session_id> [--reason <reason>] [--purge-snapshots]
#
# --reason <passed|threshold_met|max_iterations|cancelled>
#   終端理由を明示する (fork/parallel orchestrator の Step e 終了処理用)。
#   `passed` は `threshold_met` に正規化する (loop-control.sh の語彙と統一)。
#   passed/threshold_met は state の latest_score >= threshold で裏取りし、
#   不成立なら警告して auto-detect (cancelled) に落とす (PASS 詐欺ガード)。
#   省略時は従来どおり auto-detect (score >= threshold なら threshold_met、他は cancelled)。
#
# finalize は常に iteration を evaluated_iteration から確定させる
# (hook の block 時のみ increment されるため、初回 PASS だと iteration=0 のまま
#  evaluated_iteration と食い違う — 観測性の修復。後退はさせない)。
#
# --purge-snapshots を付けると refs/eval-loop/<session>/ の snapshot ref を全削除する。
# デフォルトは保持し、復元用コマンドをヒントとして表示する。

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

PURGE=false
REASON=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --purge-snapshots)
      PURGE=true
      shift
      ;;
    --reason)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --reason requires a value (passed|threshold_met|max_iterations|cancelled)" >&2
        exit 1
      fi
      REASON="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ -n "$REASON" ]; then
  case "$REASON" in
    passed) REASON="threshold_met" ;;  # loop-control.sh (hook finalize) と同じ語彙に正規化
    threshold_met|max_iterations|cancelled) ;;
    *)
      echo "ERROR: --reason must be one of passed|threshold_met|max_iterations|cancelled, got: '$REASON'" >&2
      exit 1
      ;;
  esac
fi

# 引数が1つ → state_file パス直接指定
# 引数が2つ → cwd + session_id (従来互換)
if [ $# -eq 1 ]; then
  STATE_FILE="$1"
else
  CWD="${1:-.}"
  SESSION_ID="${2:?session_id is required}"
  if [[ "$SESSION_ID" =~ [/\\] ]] || [[ "$SESSION_ID" == *..* ]]; then
    echo "ERROR: session_id must not contain path separators or '..': '$SESSION_ID'" >&2
    exit 1
  fi
  BASE_DIR="$CWD/.mso"
  STATE_FILE="$BASE_DIR/sessions/$SESSION_ID/state.json"
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found: $STATE_FILE"
  exit 0
fi

was_active="$(jq -r '.active' "$STATE_FILE" 2>/dev/null || echo false)"
if [ "$was_active" = "true" ]; then
  # PASS 詐欺ガード: --reason passed/threshold_met の主張は state の数値で裏取りする。
  # 不成立なら auto-detect (下の jq) に落とす — 結果は cancelled になる。
  if [ "$REASON" = "threshold_met" ]; then
    CLAIM_OK="$(jq -r 'if ((.latest_score | type) == "number") and ((.threshold | type) == "number")
                          and (.latest_score >= .threshold)
                       then "yes" else "no" end' "$STATE_FILE" 2>/dev/null || echo no)"
    if [ "$CLAIM_OK" != "yes" ]; then
      echo "WARNING: --reason passed/threshold_met but latest_score < threshold (or non-numeric) — falling back to auto-detect" >&2
      REASON=""
    fi
  fi
  # ended_reason の記録 (観測性): 成功完了フロー (orchestrator が threshold 達成後に
  # finalize を呼ぶ) では Stop hook の threshold_met パスを通らないため、ここで判定する。
  # 既に理由が入っていれば保持。--reason 指定があればそれを採用 (上で裏取り済み)。
  # auto-detect: score >= threshold なら threshold_met、それ以外は cancelled。
  # 型チェック必須: jq は number < string なので文字列 score は常に >= threshold になる
  # iteration 確定: evaluated_iteration (orchestrator が score と同時に書く) が数値で
  # iteration より進んでいれば採用する。後退はさせない (hook が先に increment 済みのケース)。
  jq --arg reason "$REASON" '
      .active = false
      | .ended_reason = (.ended_reason // (
          if $reason != "" then $reason
          elif ((.latest_score | type) == "number") and ((.threshold | type) == "number")
             and (.latest_score >= .threshold)
          then "threshold_met" else "cancelled" end))
      | (if ((.evaluated_iteration | type) == "number")
            and (((.iteration | type) != "number") or (.evaluated_iteration > .iteration))
         then .iteration = .evaluated_iteration else . end)' \
    "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
  if [ -n "$REASON" ]; then
    echo "Eval loop finalized (reason: $(jq -r '.ended_reason' "$STATE_FILE")). Final state:"
  else
    echo "Eval loop cancelled. Final state:"
  fi
  jq '.' "$STATE_FILE"
else
  echo "No active eval loop."
fi

# --- Snapshot ref の処理 ---
SNAP_PREFIX=$(jq -r '.snapshot_ref_prefix // ""' "$STATE_FILE" 2>/dev/null || echo "")
PROJECT_DIR=$(jq -r '.project_dir // ""' "$STATE_FILE" 2>/dev/null || echo "")
BEST_ITER=$(jq -r '.best_iteration // empty' "$STATE_FILE" 2>/dev/null || echo "")
BEST_SCORE=$(jq -r '.best_score // empty' "$STATE_FILE" 2>/dev/null || echo "")
# SCRIPT_DIR は snapshot ヒント (Restore / Purge) の両方で使う。best_iteration が無い
# (best 未確定で finalize した) ケースでも Purge ヒント行が参照するため、内側の
# if [ -n "$BEST_ITER" ] ブロックに入れず、ここで一度だけ定義する (set -u 下で unbound 回避)。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "$SNAP_PREFIX" ] && [ -d "$PROJECT_DIR" ] && (cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1); then
  if [ "$PURGE" = "true" ]; then
    deleted=0
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      (cd "$PROJECT_DIR" && git update-ref -d "$ref" 2>/dev/null) && deleted=$((deleted + 1))
    done < <(cd "$PROJECT_DIR" && git for-each-ref --format='%(refname)' "$SNAP_PREFIX/" 2>/dev/null)
    echo "Purged $deleted snapshot ref(s) under $SNAP_PREFIX/"
  else
    snap_count=$(cd "$PROJECT_DIR" && git for-each-ref --format='%(refname)' "$SNAP_PREFIX/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$snap_count" -gt 0 ]; then
      echo ""
      echo "Snapshots preserved: $snap_count ref(s) under $SNAP_PREFIX/"
      if [ -n "$BEST_ITER" ]; then
        # 復元は write_targets 限定 (loop-snapshot.sh --restore)。全ツリー復元
        # 'git checkout <ref> -- .' は並列ループの他成果物を巻き戻すため案内しない。
        WT_COUNT=$(jq -r '(.write_targets // []) | length' "$STATE_FILE" 2>/dev/null) || WT_COUNT=0
        echo "  Restore best (iter $BEST_ITER, score $BEST_SCORE):"
        if [ "$WT_COUNT" -gt 0 ] 2>/dev/null; then
          echo "    bash $SCRIPT_DIR/loop-snapshot.sh $STATE_FILE $BEST_ITER --restore   # write_targets のみ復元"
        else
          echo "    (write_targets が空のため自動復元コマンドなし — 対象パスを明示して復元: git checkout $SNAP_PREFIX/iter-$BEST_ITER -- <paths>)"
        fi
      fi
      echo "  List all:    git for-each-ref $SNAP_PREFIX/"
      echo "  Purge later: bash $SCRIPT_DIR/loop-cancel.sh $STATE_FILE --purge-snapshots"
    fi
  fi
fi
