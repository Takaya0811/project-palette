#!/usr/bin/env bash
# codex-debate-eval.sh — Codex CLI で成果物を独立評価する
# assign-debate-evaluator の !`bash ${CLAUDE_PLUGIN_ROOT}/skills/assign-debate-evaluator/scripts/codex-debate-eval.sh $ARGUMENTS` で事前展開される
#
# Usage: bash codex-debate-eval.sh <context.json>
#
# HOOK SAFETY 対象外 (非 hook スクリプト)
set -euo pipefail

CONTEXT="${1:-}"
if [ -z "$CONTEXT" ] || [ ! -f "$CONTEXT" ]; then
  echo "(Codex evaluation skipped: context file not found)"
  exit 0
fi

CODEX_BIN="${CODEX_BIN:-codex}"
if ! command -v "$CODEX_BIN" &>/dev/null; then
  echo "(Codex evaluation skipped: codex CLI not installed)"
  exit 0
fi

PROJECT_DIR=$(jq -r '.project_dir // "."' "$CONTEXT" 2>/dev/null) || PROJECT_DIR="."
CRITERIA=$(jq -r '.criteria // ""' "$CONTEXT" 2>/dev/null) || CRITERIA=""
THRESHOLD=$(jq -r '.threshold // 90' "$CONTEXT" 2>/dev/null) || THRESHOLD=90
PLAN=$(jq -r '.plan // ""' "$CONTEXT" 2>/dev/null) || PLAN=""
ITERATION=$(jq -r '.iteration // 0' "$CONTEXT" 2>/dev/null) || ITERATION=0
TURNS_DIR=$(jq -r '.turns_dir // ""' "$CONTEXT" 2>/dev/null) || TURNS_DIR=""

if [ -z "$PLAN" ]; then
  echo "(Codex evaluation skipped: no plan content)"
  exit 0
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

ITER_PADDED=$(printf '%03d' "$ITERATION")
OUTPUT_HINT=""
if [ -n "$TURNS_DIR" ]; then
  OUTPUT_HINT="- 非コード成果物は turns_dir 内の turn-${ITER_PADDED}-output.md にある可能性がある
- turns_dir: ${TURNS_DIR}"
fi

cat > "$PROMPT_FILE" <<__EOF__
あなたは厳格なコードレビュアーです。以下の計画に基づいて実装された成果物を独立に評価してください。

## 評価基準
${CRITERIA}

## 合格ライン
${THRESHOLD} 点以上 (100点満点)

## 実行計画
${PLAN}

## 成果物の探索先
- プロジェクトディレクトリ内のファイル（メイン）
${OUTPUT_HINT}

## 指示

1. プロジェクトディレクトリと turns_dir の両方の成果物を実際に読んで検証すること
2. 計画の Acceptance Criteria を各項目チェックすること
3. 評価基準の各項目を個別に採点すること
4. 忖度禁止。問題があれば明確に指摘すること
5. 「改善された」ではなく絶対品質で判定すること

## 出力形式

以下の形式で日本語で出力してください:

### 総合スコア
(0-100の数値と根拠)

### 計画準拠性
各 Acceptance Criteria の充足状況を個別に評価

### 品質評価
各評価基準の個別スコアと根拠

### 問題点
具体的な問題点のリスト

### 改善提案
具体的な改善指示
__EOF__

"$CODEX_BIN" exec -s workspace-write -C "$PROJECT_DIR" - < "$PROMPT_FILE"
