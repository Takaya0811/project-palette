#!/usr/bin/env bash
#
# run-thumbnail - Schema-driven thumbnail generator
#
# config.json の modes[].params スキーマを読んで動的に引数パースし、
# promptTemplate を埋めて codex-image.sh (codex exec + image_gen) に投げる。
# モード追加時は config.json の modes エントリを足すだけで、このスクリプトは触らない。
#
# Bash 3.2 互換 (macOS デフォルトで動作)。associative array を使わず
# 並列配列 + ヘルパー関数で実装している。
#
# Usage:
#   generate.sh --list-modes
#   generate.sh -m <mode> --help
#   generate.sh -m <mode> [params...] [-o <output>]
#   generate.sh -m <mode> --sample [-o <output>]   # config の sample を使用
#   generate.sh -m <mode> [params...] --dry-run    # プロンプト確認のみ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.json"

# 相対パスは常にリポジトリルート相対として解決する。CWD が
# `.claude/skills/run-thumbnail/` になっていても skill 配下に
# `output/` が掘られない。git 外から叩かれた場合は CWD にフォールバック。
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

resolve_path() {
  case "$1" in
    "" ) printf '' ;;
    /* ) printf '%s' "$1" ;;
    *  ) printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

# ---------- 並列配列ヘルパー (Bash 3.2 互換) ----------

# スキーマ: mode の params から読み込む
SCHEMA_NAMES=()   # param name (例: line1, characterImage)
SCHEMA_FLAGS=()   # CLI flag   (例: --line1, --character-image)
SCHEMA_REQS=()    # "true" / "false"
SCHEMA_DEFAULTS=() # optional のデフォルト値 (無ければ空文字)

# 実行時パラメータ値: CLI / --sample で埋められる
PARAM_KEYS=()
PARAM_VALS=()

schema_add() {
  SCHEMA_NAMES+=("$1")
  SCHEMA_FLAGS+=("$2")
  SCHEMA_REQS+=("$3")
  SCHEMA_DEFAULTS+=("${4-}")
}

default_for_name() {
  local name="$1" i
  for i in "${!SCHEMA_NAMES[@]}"; do
    if [[ "${SCHEMA_NAMES[i]}" == "$name" ]]; then
      printf '%s' "${SCHEMA_DEFAULTS[i]}"
      return 0
    fi
  done
  return 1
}

flag_to_name() {
  local flag="$1" i
  for i in "${!SCHEMA_FLAGS[@]}"; do
    if [[ "${SCHEMA_FLAGS[i]}" == "$flag" ]]; then
      printf '%s' "${SCHEMA_NAMES[i]}"
      return 0
    fi
  done
  return 1
}

is_required() {
  local name="$1" i
  for i in "${!SCHEMA_NAMES[@]}"; do
    if [[ "${SCHEMA_NAMES[i]}" == "$name" ]]; then
      [[ "${SCHEMA_REQS[i]}" == "true" ]]
      return
    fi
  done
  return 1
}

flag_for_name() {
  local name="$1" i
  for i in "${!SCHEMA_NAMES[@]}"; do
    if [[ "${SCHEMA_NAMES[i]}" == "$name" ]]; then
      printf '%s' "${SCHEMA_FLAGS[i]}"
      return 0
    fi
  done
  return 1
}

set_param() {
  local key="$1" value="$2" i
  for i in "${!PARAM_KEYS[@]}"; do
    if [[ "${PARAM_KEYS[i]}" == "$key" ]]; then
      PARAM_VALS[i]="$value"
      return
    fi
  done
  PARAM_KEYS+=("$key")
  PARAM_VALS+=("$value")
}

get_param() {
  local key="$1" i
  for i in "${!PARAM_KEYS[@]}"; do
    if [[ "${PARAM_KEYS[i]}" == "$key" ]]; then
      printf '%s' "${PARAM_VALS[i]}"
      return
    fi
  done
}

# ---------- help / list ----------
top_help() {
  cat <<EOF
Usage:
  generate.sh --list-modes
  generate.sh -m <mode> --help
  generate.sh -m <mode> [mode params...] [-o <output>] [--sample] [--dry-run]

Common options:
  -o, --output <path>    出力先 (拡張子で format 判定: .png / .webp / .jpg)。--sample 使用時は省略で output/samples/<mode>.png
  --sample               config.json の modes[<mode>].sample を使って生成
  --dry-run              codex-image.sh を呼ばずに組み上がったプロンプトを出力
  --list-modes           利用可能なモード一覧を表示
  -h, --help             このヘルプ (-m 指定時はそのモードのヘルプ)

Run 'generate.sh --list-modes' to see available modes.
EOF
}

list_modes() {
  echo "Available modes:"
  jq -r '.modes | to_entries[] | "  \(.key)\n    \(.value.name)\n    \(.value.description)\n"' "$CONFIG"
}

mode_help() {
  local mode="$1"
  jq -r --arg m "$mode" '
    .modes[$m] |
    "Mode: \($m) -- \(.name)\n" +
    "Description: \(.description)\n\n" +
    "Parameters:\n" +
    ([.params[] | "  \(.flag) \(if .required then "[required]" else "[optional]" end)\n    \(.desc)\(if .default then "\n    default: \(.default)" else "" end)"] | join("\n"))
  ' "$CONFIG"
  echo ""
  if jq -e --arg m "$mode" '.modes[$m].sample' "$CONFIG" >/dev/null; then
    echo "Sample (使用: --sample):"
    jq -r --arg m "$mode" '.modes[$m].sample | to_entries[] | "  \(.key) = \(.value | tostring)"' "$CONFIG"
  fi
}

# ---------- Pass 1: -m と特殊オプションの先行検出 ----------
MODE=""
LIST_MODES=0
WANT_HELP=0
ARGS=("$@")

i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[i]}" in
    --list-modes) LIST_MODES=1; i=$((i+1)) ;;
    -m|--mode)    MODE="${ARGS[i+1]:-}"; i=$((i+2)) ;;
    -h|--help)    WANT_HELP=1; i=$((i+1)) ;;
    *)            i=$((i+1)) ;;
  esac
done

if [[ "$LIST_MODES" -eq 1 ]]; then
  list_modes
  exit 0
fi

if [[ "$WANT_HELP" -eq 1 && -z "$MODE" ]]; then
  top_help
  exit 0
fi

if [[ -z "$MODE" ]]; then
  echo "Error: -m/--mode is required" >&2
  top_help >&2
  exit 1
fi

if ! jq -e --arg m "$MODE" '.modes[$m]' "$CONFIG" >/dev/null; then
  echo "Error: unknown mode '$MODE'" >&2
  echo "Available: $(jq -r '.modes | keys | join(", ")' "$CONFIG")" >&2
  exit 1
fi

if [[ "$WANT_HELP" -eq 1 ]]; then
  mode_help "$MODE"
  exit 0
fi

# ---------- スキーマ読み込み ----------
while IFS=$'\t' read -r name flag required default; do
  schema_add "$name" "$flag" "$required" "$default"
done < <(jq -r --arg m "$MODE" '.modes[$m].params[] | [.name, .flag, .required, (.default // "")] | @tsv' "$CONFIG")

# ---------- Pass 2: スキーマドリブン引数パース ----------
OUTPUT=""
USE_SAMPLE=0
DRY_RUN=0

i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  arg="${ARGS[i]}"
  case "$arg" in
    -o|--output)    OUTPUT="${ARGS[i+1]}"; i=$((i+2)) ;;
    -m|--mode)      i=$((i+2)) ;;   # Pass 1 で処理済み
    --sample)       USE_SAMPLE=1; i=$((i+1)) ;;
    --dry-run)      DRY_RUN=1; i=$((i+1)) ;;
    --list-modes)   i=$((i+1)) ;;   # Pass 1 で処理済み
    -h|--help)      i=$((i+1)) ;;   # Pass 1 で処理済み
    *)
      if name=$(flag_to_name "$arg"); then
        set_param "$name" "${ARGS[i+1]}"
        i=$((i+2))
      else
        echo "Error: unknown argument '$arg' for mode '$MODE'" >&2
        echo "Run 'generate.sh -m $MODE --help' for usage" >&2
        exit 1
      fi
      ;;
  esac
done

# ---------- --sample: config から値を埋める (CLI 指定を優先) ----------
if [[ "$USE_SAMPLE" -eq 1 ]]; then
  while IFS=$'\t' read -r key value; do
    if [[ -z "$(get_param "$key")" ]]; then
      set_param "$key" "$value"
    fi
  done < <(jq -r --arg m "$MODE" '.modes[$m].sample // {} | to_entries[] | [.key, .value] | @tsv' "$CONFIG")

  if [[ -z "$OUTPUT" ]]; then
    OUTPUT="output/samples/${MODE}.png"
  fi
fi

# ---------- optional の default を埋める (CLI / --sample 未指定時のフォールバック) ----------
for name in "${SCHEMA_NAMES[@]}"; do
  if [[ -z "$(get_param "$name")" ]]; then
    default_val="$(default_for_name "$name")"
    if [[ -n "$default_val" ]]; then
      set_param "$name" "$default_val"
    fi
  fi
done

# ---------- 相対パス → repo root 相対に正規化 ----------
# CWD が skill ディレクトリになっていても skill 配下に output/ を
# 作らないよう、ここで全パラメータを絶対パス化しておく。
OUTPUT="$(resolve_path "$OUTPUT")"
for key in characterImage iconImage; do
  val="$(get_param "$key")"
  if [[ -n "$val" ]]; then
    set_param "$key" "$(resolve_path "$val")"
  fi
done

# ---------- validation ----------
if [[ -z "$OUTPUT" ]]; then
  echo "Error: -o/--output is required (or use --sample for default output path)" >&2
  exit 1
fi

# 必須パラメータチェック
for name in "${SCHEMA_NAMES[@]}"; do
  if is_required "$name"; then
    if [[ -z "$(get_param "$name")" ]]; then
      flag=$(flag_for_name "$name")
      echo "Error: mode '$MODE' requires parameter '$name' ($flag)" >&2
      exit 1
    fi
  fi
done

# 参照画像の存在チェック
for key in characterImage iconImage; do
  img="$(get_param "$key")"
  if [[ -n "$img" && ! -f "$img" ]]; then
    echo "Error: $key file not found: $img" >&2
    exit 1
  fi
done

# ---------- character block の選択 ----------
if [[ -n "$(get_param characterImage)" ]]; then
  CHARACTER_BLOCK=$(jq -r '.characterBlocks.withImage' "$CONFIG")
else
  CHARACTER_BLOCK=$(jq -r '.characterBlocks.default' "$CONFIG")
fi

# ---------- icon block + line2 whitelist (iconImage パラメータを持つモード向け) ----------
ICON_BLOCK=""
LINE2_WHITELIST=""
HAS_ICON_SLOT=0
if jq -e --arg m "$MODE" '.modes[$m].params[] | select(.name == "iconImage")' "$CONFIG" >/dev/null; then
  HAS_ICON_SLOT=1
fi

if [[ "$HAS_ICON_SLOT" -eq 1 ]]; then
  ICON_IMAGE_PATH="$(get_param iconImage)"
  ICON_VARIANT="default"
  if [[ -n "$ICON_IMAGE_PATH" ]]; then
    DIMS=$(magick identify -format "%w %h" "$ICON_IMAGE_PATH" 2>/dev/null || echo "")
    if [[ -n "$DIMS" ]]; then
      THRESHOLD=$(jq -r '.iconAspectThreshold // 1.5' "$CONFIG")
      SHAPE=$(awk -v d="$DIMS" -v t="$THRESHOLD" 'BEGIN{split(d,a," "); print (a[1]/a[2] >= t) ? "banner" : "square"}')
      if [[ "$SHAPE" == "banner" ]]; then
        ICON_VARIANT="withImageBanner"
      else
        ICON_VARIANT="withImageSquare"
      fi
      echo "Icon image aspect: ${DIMS// /x} -> $ICON_VARIANT"
    else
      echo "Warning: failed to identify $ICON_IMAGE_PATH; falling back to withImageSquare"
      ICON_VARIANT="withImageSquare"
    fi
  fi

  LINE2_VAL="$(get_param line2)"
  ICON_BLOCK=$(jq -rn \
    --arg tmpl "$(jq -r --arg v "$ICON_VARIANT" '.iconBlocks[$v]' "$CONFIG")" \
    --arg l2 "$LINE2_VAL" \
    '$tmpl | gsub("\\{\\{line2\\}\\}"; $l2)')

  if [[ "$ICON_VARIANT" == "withImageBanner" ]]; then
    LINE2_WHITELIST_TMPL=$(jq -r '.line2Whitelist.bannerOnly' "$CONFIG")
  else
    LINE2_WHITELIST_TMPL=$(jq -r '.line2Whitelist.withLabel' "$CONFIG")
  fi
  LINE2_WHITELIST=$(jq -rn --arg tmpl "$LINE2_WHITELIST_TMPL" --arg l2 "$LINE2_VAL" \
    '$tmpl | gsub("\\{\\{line2\\}\\}"; $l2)')
fi

# ---------- テンプレート取得 & 動的埋め込み ----------
TEMPLATE=$(jq -r --arg m "$MODE" '.modes[$m].promptTemplate' "$CONFIG")

# スキーマの全キーを gsub するための jq 引数とフィルタを動的に構築
JQ_ARGS=(--arg tmpl "$TEMPLATE")
JQ_FILTER='$tmpl'

for key in "${SCHEMA_NAMES[@]}"; do
  value="$(get_param "$key")"
  JQ_ARGS+=(--arg "p_$key" "$value")
  JQ_FILTER+=" | gsub(\"\\\\{\\\\{$key\\\\}\\\\}\"; \$p_$key)"
done

# 共有ブロックを gsub (promptTemplate に含まれていない場合は no-op)
JQ_ARGS+=(--arg characterBlock "$CHARACTER_BLOCK")
JQ_FILTER+=' | gsub("\\{\\{characterBlock\\}\\}"; $characterBlock)'

JQ_ARGS+=(--arg iconBlock "$ICON_BLOCK")
JQ_FILTER+=' | gsub("\\{\\{iconBlock\\}\\}"; $iconBlock)'

JQ_ARGS+=(--arg line2Whitelist "$LINE2_WHITELIST")
JQ_FILTER+=' | gsub("\\{\\{line2Whitelist\\}\\}"; $line2Whitelist)'

PROMPT=$(jq -rn "${JQ_ARGS[@]}" "$JQ_FILTER")

# ---------- 参照画像の結合 (codex-image.sh -r は1ファイルのみ) ----------
CHARACTER_IMAGE="$(get_param characterImage)"
ICON_IMAGE="$(get_param iconImage)"
REF_IMAGE=""
REF_INSTRUCTION=""
COMBINED=""

if [[ -n "$CHARACTER_IMAGE" && -n "$ICON_IMAGE" ]]; then
  COMBINED="$(dirname "$OUTPUT")/.ref-combined-$$.webp"
  mkdir -p "$(dirname "$COMBINED")"
  magick "$ICON_IMAGE" "$CHARACTER_IMAGE" +append -resize 1600x "$COMBINED"
  REF_IMAGE="$COMBINED"
  REF_INSTRUCTION="参照画像の左側のロゴ/アイコンを、プロンプトで指定されたプロダクトアイコン位置に忠実に再現（デザイン・色・形を正確にコピー）。右側のキャラクターを、プロンプトで指定されたキャラクター位置に配置し、デザイン・服装・髪型・瞳の色・表情の特徴を忠実に維持すること。"
elif [[ -n "$CHARACTER_IMAGE" ]]; then
  REF_IMAGE="$CHARACTER_IMAGE"
  REF_INSTRUCTION="参照画像のキャラクターを、プロンプトで指定されたキャラクター位置に配置、デザイン・服装・髪型・瞳の色・表情の特徴を忠実に維持すること。"
elif [[ -n "$ICON_IMAGE" ]]; then
  REF_IMAGE="$ICON_IMAGE"
  REF_INSTRUCTION="参照画像のロゴ/アイコンを、プロンプトで指定されたプロダクトアイコン位置に忠実に再現。デザイン・色・形を正確にコピー。"
fi

# ---------- 出力ディレクトリ作成 ----------
mkdir -p "$(dirname "$OUTPUT")"

# ---------- codex-image 実行 ----------
echo "Mode: $MODE"
echo "Output: $OUTPUT"
echo "Prompt length: ${#PROMPT} chars"
[[ -n "$REF_IMAGE" ]] && echo "Reference: $REF_IMAGE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- DRY RUN: prompt ---"
  echo "$PROMPT"
  echo "--- DRY RUN: end ---"
  [[ -n "$COMBINED" && -f "$COMBINED" ]] && rm -f "$COMBINED"
  exit 0
fi

CODEX_IMAGE="${SCRIPT_DIR}/codex-image.sh"
if [[ -n "$REF_IMAGE" ]]; then
  bash "$CODEX_IMAGE" \
    -o "$OUTPUT" \
    -r "$REF_IMAGE" \
    --ref-instruction "$REF_INSTRUCTION" \
    "$PROMPT"
else
  bash "$CODEX_IMAGE" \
    -o "$OUTPUT" \
    "$PROMPT"
fi

# ---------- cleanup ----------
[[ -n "$COMBINED" && -f "$COMBINED" ]] && rm -f "$COMBINED"

echo "Done: $OUTPUT"
