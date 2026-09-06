#!/usr/bin/env bash
# codex-delegate.sh — Codex CLI に任意タスクを委譲する thin wrapper
# delegate-codex の !`bash .claude/skills/delegate-codex/codex-delegate.sh $ARGUMENTS` から呼ばれ、
# skill 読み込み時に Codex 出力が SKILL.md の context に展開される。
#
# Usage: bash .claude/skills/delegate-codex/codex-delegate.sh <args>
#   <args> は (a) JSON オブジェクト (b) 既存ファイル絶対パス (c) 自然文 のいずれか
#
# HOOK SAFETY 対象外 (非 hook スクリプト)
set -euo pipefail

# 引数受け渡し: --stdin が来たら標準入力から読む (SKILL.md からの heredoc 経由)
# それ以外は従来通り argv を結合する
if [ "${1:-}" = "--stdin" ]; then
  RAW="$(cat)"
else
  RAW="${*:-}"
fi

# stdin から来た末尾改行は trim (jq -e の判定や file 判定で空行が混じると壊れる)
RAW="${RAW%$'\n'}"

if [ -z "$RAW" ]; then
  echo "(Codex delegate skipped: empty ARGUMENTS)"
  exit 0
fi

CODEX_BIN="${CODEX_BIN:-codex}"
if ! command -v "$CODEX_BIN" &>/dev/null; then
  echo "(Codex delegate skipped: codex CLI not installed)"
  exit 0
fi

# 引数正規化: JSON -> ファイルパス -> 自然文
TASK=""
PROJECT_DIR=""
MODE="write"
TIMEOUT_S=600

if printf '%s' "$RAW" | jq -e . >/dev/null 2>&1; then
  TASK=$(printf '%s' "$RAW" | jq -r '.task // empty')
  PROJECT_DIR=$(printf '%s' "$RAW" | jq -r '.project_dir // empty')
  MODE=$(printf '%s' "$RAW" | jq -r '.mode // "write"')
  TIMEOUT_S=$(printf '%s' "$RAW" | jq -r '.timeout_s // 600')
elif [ -f "$RAW" ]; then
  TASK=$(cat "$RAW")
else
  TASK="$RAW"
fi

: "${PROJECT_DIR:=$(pwd)}"
[ -d "$PROJECT_DIR" ] || { echo "(Codex delegate skipped: project_dir not found: $PROJECT_DIR)"; exit 0; }
[ -n "$TASK" ] || { echo "(Codex delegate skipped: empty task)"; exit 0; }

# timeout 実装を解決 (macOS では coreutils の gtimeout、無ければ env に退避して no-op)
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD=(gtimeout "${TIMEOUT_S}")
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD=(timeout "${TIMEOUT_S}")
else
  TIMEOUT_CMD=(env)
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

if [ "$MODE" = "read_only" ]; then
  cat > "$PROMPT_FILE" <<__EOF__
${TASK}

## 環境メモ
- 作業ディレクトリ: ${PROJECT_DIR}
- **READ-ONLY モード**。ファイルを一切変更しないでください。
- 観察と findings のみを Markdown で出力してください。
__EOF__
  "${TIMEOUT_CMD[@]}" "$CODEX_BIN" exec -C "$PROJECT_DIR" - < "$PROMPT_FILE"
else
  cat > "$PROMPT_FILE" <<__EOF__
${TASK}

## 環境メモ
- 作業ディレクトリ: ${PROJECT_DIR}
- 書き込み権限あり。必要な範囲で編集・新規作成してください。
- project_dir の外側 (.mso/, /tmp/ state, 他プロジェクト) には書き込まない。
- 変更したファイル一覧と、変更しなかった理由を最後に要約してください。
__EOF__
  "${TIMEOUT_CMD[@]}" "$CODEX_BIN" exec -s workspace-write -C "$PROJECT_DIR" - < "$PROMPT_FILE"
fi
