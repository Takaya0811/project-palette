#!/bin/bash
# loop-snapshot.sh — イテレーション毎の作業ツリーを git 隠し ref に冷凍保存 / 復元する
# Usage: loop-snapshot.sh <state_file> <iteration>             # snapshot 保存
#        loop-snapshot.sh <state_file> <iteration> --restore   # snapshot 復元 (write_targets 限定)
#
# 動作 (保存):
#   - state.json の snapshot_enabled が true で snapshot_ref_prefix が設定されているときだけ動く
#   - git stash create -u で commit object を作り、stash list には積まない
#   - update-ref で <prefix>/iter-<N> に貼る (refs/heads/, refs/tags/ ではないので git log/branch/tag に出ない)
#   - 失敗は exit 0 で飲む。snapshot は best-effort、ループの進行を止めない
#
# 動作 (--restore):
#   - <prefix>/iter-<N> から state.json の write_targets に列挙されたパスだけを復元する
#   - write_targets が空なら復元を拒否する (全ツリー 'git checkout <ref> -- .' への fallback は
#     しない — 並列ループ時に他ループの成果物まで巻き戻すため)
#   - restore は明示操作なので、失敗は exit 1 で loud に報告する (best-effort ではない)

STATE_FILE="${1:-}"
ITER="${2:-}"
MODE="snapshot"
[ "${3:-}" = "--restore" ] && MODE="restore"

fail() { echo "ERROR: $*" >&2; exit 1; }
# 前提条件 NG 時の終了: snapshot は黙って exit 0 (best-effort)、restore は exit 1 (明示操作)
bail() {
  if [ "$MODE" = "restore" ]; then fail "$@"; fi
  exit 0
}

command -v jq &>/dev/null || bail "jq is required"
[ -n "$STATE_FILE" ] || bail "usage: loop-snapshot.sh <state_file> <iteration> [--restore]"
[ -n "$ITER" ] || bail "usage: loop-snapshot.sh <state_file> <iteration> [--restore]"
[ -f "$STATE_FILE" ] || bail "state file not found: $STATE_FILE"

ENABLED=$(jq -r '.snapshot_enabled // false' "$STATE_FILE" 2>/dev/null) || bail "cannot parse state: $STATE_FILE"
[ "$ENABLED" = "true" ] || bail "snapshot_enabled is not true in $STATE_FILE"

PREFIX=$(jq -r '.snapshot_ref_prefix // ""' "$STATE_FILE" 2>/dev/null) || bail "cannot parse state: $STATE_FILE"
[ -n "$PREFIX" ] || bail "snapshot_ref_prefix is empty in $STATE_FILE"

PROJECT_DIR=$(jq -r '.project_dir // ""' "$STATE_FILE" 2>/dev/null) || bail "cannot parse state: $STATE_FILE"
[ -d "$PROJECT_DIR" ] || bail "project_dir not found: $PROJECT_DIR"

SESSION_ID=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null) || bail "cannot parse state: $STATE_FILE"

cd "$PROJECT_DIR" 2>/dev/null || bail "cannot cd to project_dir: $PROJECT_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || bail "not a git repo: $PROJECT_DIR"

# --- restore モード: write_targets 限定で snapshot ref から復元 ---
if [ "$MODE" = "restore" ]; then
  REF="$PREFIX/iter-$ITER"
  git rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1 || fail "snapshot ref not found: $REF"

  TARGETS=()
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in
      *..*) fail "unsafe write_target (contains '..'): $t" ;;
    esac
    TARGETS+=("$t")
  done < <(jq -r '(.write_targets // []) | .[]' "$STATE_FILE" 2>/dev/null)

  # write_targets が空なら復元しない (安全側)。全ツリー復元 'git checkout <ref> -- .' は
  # 並列ループで他ループの成果物を巻き戻すため、自動では絶対に行わない。
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    fail "write_targets is empty in $STATE_FILE — refusing restore. Set write_targets, or restore specific paths manually: git checkout $REF -- <paths>"
  fi

  git checkout "$REF" -- "${TARGETS[@]}" || fail "git checkout failed: $REF -- ${TARGETS[*]}"
  echo "restored: $REF -- ${TARGETS[*]}"
  exit 0
fi

# git stash create -u は「tracked 変更が無い場合」untracked があっても空を返す。
# このため untracked-only のケース (新規ファイルだけのタスク等) を取りこぼす。
# 解決策: temp index に read-tree HEAD → add -A → write-tree → commit-tree。
# .gitignore は add -A が尊重するので .mso/ 等は混ざらない。ユーザーの実際の
# index には一切触れない。
TMPINDEX="$(mktemp -t eval-loop-idx.XXXXXX 2>/dev/null)" || exit 0
trap 'rm -f "$TMPINDEX"' EXIT

PARENT=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$PARENT" ]; then
  GIT_INDEX_FILE="$TMPINDEX" git read-tree "$PARENT" 2>/dev/null
fi
# `.mso/` はハーネス内部状態 (state.json / sessions / agents 等)。
# ユーザーの .gitignore に書いていなくても snapshot からは常に除外する
# (snapshot は user 成果物の凍結が目的、harness 自身の進捗は別管理)。
GIT_INDEX_FILE="$TMPINDEX" git add -A -- ':(exclude).mso' ':(exclude).mso/**' 2>/dev/null
TREE=$(GIT_INDEX_FILE="$TMPINDEX" git write-tree 2>/dev/null)
[ -n "$TREE" ] || exit 0

# Working tree が HEAD と同一なら新 commit を作らず HEAD をそのまま指す
# (毎回別 commit になるとイテレーション間の no-op を区別できなくなるため)
if [ -n "$PARENT" ] && [ "$TREE" = "$(git rev-parse "$PARENT^{tree}" 2>/dev/null)" ]; then
  SNAP="$PARENT"
elif [ -n "$PARENT" ]; then
  SNAP=$(echo "eval-loop $SESSION_ID iter $ITER" | git commit-tree "$TREE" -p "$PARENT" 2>/dev/null)
else
  SNAP=$(echo "eval-loop $SESSION_ID iter $ITER" | git commit-tree "$TREE" 2>/dev/null)
fi
[ -n "$SNAP" ] || exit 0

REF="$PREFIX/iter-$ITER"
git update-ref "$REF" "$SNAP" 2>/dev/null || exit 0
echo "snapshot: $REF -> $SNAP"
