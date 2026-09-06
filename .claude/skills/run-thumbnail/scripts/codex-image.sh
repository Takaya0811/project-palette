#!/usr/bin/env bash
#
# run-thumbnail - codex exec wrapper (aiimage replacement)
#
# codex exec (gpt-6-astra / reasoning_effort=medium) を起動し、
# image_gen ツールで 2K / 16:9 / high quality の画像を生成させ、
# 指定パスに保存する (拡張子で format 判定: .png / .webp / .jpg)。
#
# Usage:
#   codex-image.sh -o <output.png> [-r <ref.png>] [--ref-instruction <txt>] "<prompt>"

set -euo pipefail

OUTPUT=""
REF_IMAGE=""
REF_INSTRUCTION=""
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)       OUTPUT="$2"; shift 2 ;;
    -r|--ref-image)    REF_IMAGE="$2"; shift 2 ;;
    --ref-instruction) REF_INSTRUCTION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --) shift; PROMPT="${1:-}"; shift || true; break ;;
    -*) echo "Error: unknown option '$1'" >&2; exit 1 ;;
    *)
      if [[ -z "$PROMPT" ]]; then PROMPT="$1"; else
        echo "Error: extra positional argument '$1'" >&2; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$OUTPUT" || -z "$PROMPT" ]]; then
  echo "Usage: $0 -o <output.png> [-r <ref.png>] [--ref-instruction <txt>] \"<prompt>\"" >&2
  exit 1
fi

# 相対パスは repo root 相対として解決する (CWD が skill ディレクトリに
# なっていても skill 配下に output/ が掘られないよう)。git 外から叩か
# れた場合は CWD にフォールバック。存在チェックは正規化後に行う。
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

resolve_abs() {
  case "$1" in
    /* ) printf '%s' "$1" ;;
    *  ) printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

OUTPUT_ABS="$(resolve_abs "$OUTPUT")"
if [[ -n "$REF_IMAGE" ]]; then
  REF_IMAGE="$(resolve_abs "$REF_IMAGE")"
  if [[ ! -f "$REF_IMAGE" ]]; then
    echo "Error: ref image not found after normalization: $REF_IMAGE" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$OUTPUT_ABS")"

WORKDIR="$REPO_ROOT"

# 並列実行時の race を物理的に回避するため、CODEX_HOME を per-invocation の
# 一時 dir に差し替える。元 ~/.codex の中身を symlink で複製し、
# generated_images のみ per-invocation の空 dir にすることで、
# image_gen 出力が完全に分離される。
CODEX_HOME_ORIG="${CODEX_HOME:-$HOME/.codex}"
CODEX_TMP_HOME=$(mktemp -d -t codex-img.XXXXXX)
trap 'rm -rf "$CODEX_TMP_HOME"' EXIT

if [[ -d "$CODEX_HOME_ORIG" ]]; then
  # hidden と visible 両方を symlink (generated_images を除く)。
  shopt -s dotglob nullglob 2>/dev/null || true
  for item in "$CODEX_HOME_ORIG"/*; do
    name=$(basename "$item")
    [[ "$name" == "generated_images" ]] && continue
    ln -s "$item" "$CODEX_TMP_HOME/$name"
  done
fi
mkdir -p "$CODEX_TMP_HOME/generated_images"

REF_STEP=""
if [[ -n "$REF_IMAGE" ]]; then
  REF_STEP="- 添付した参照画像を元に、${REF_INSTRUCTION:-参照画像のデザイン・キャラクター・ロゴを忠実に再現すること}。"
fi

# codex には image_gen 実行のみを指示する (magick / webp 変換は bash 側で実施)。
# CODEX_HOME を per-invocation に隔離しているため、generated_images 配下は
# 自セッションの png しか存在せず、`ls -t` で race せず最新を拾える。
CODEX_PROMPT=$(cat <<EOF
次の手順で画像を1枚生成してください。**出力先は \$CODEX_HOME/generated_images/<session_id>/ig_*.png に image_gen が自動保存するため、保存先の指定・変換・コピーは不要です。呼び出し側が後処理します。**

## 手順
1. image_gen ツールで、下の「画像プロンプト」の内容を **1920x1080 (16:9) / high quality** で生成する。image_gen に渡すプロンプト本文の末尾に必ず "1920x1080 resolution, 16:9 aspect ratio, high quality, sharp details" を含めること。
${REF_STEP}
2. 画像生成が成功したら、\`ls \$CODEX_HOME/generated_images/*/ig_*.png | head -1\` で生成物が存在することだけ確認する。
3. **他のファイルは作らない。magick 等の変換は一切不要。**

## 画像プロンプト
$PROMPT

## 制約
- 失敗したら1回だけ image_gen をリトライしてよい。
- 最終メッセージは \`OK\` もしくは \`NG <理由>\` の1行のみ。
EOF
)

CODEX_ARGS=(
  exec
  -s
  workspace-write
  --skip-git-repo-check
  -C "$WORKDIR"
  -c model="gpt-6-astra"
  -c model_reasoning_effort="medium"
)

if [[ -n "$REF_IMAGE" ]]; then
  CODEX_ARGS+=(-i "$REF_IMAGE")
fi

echo "[codex-image] output: $OUTPUT_ABS"
echo "[codex-image] CODEX_HOME (isolated): $CODEX_TMP_HOME"
[[ -n "$REF_IMAGE" ]] && echo "[codex-image] ref: $REF_IMAGE"
echo "[codex-image] invoking codex exec (gpt-6-astra, medium)..."

# プロンプトは stdin 経由で渡す (`-i` の後ろに位置引数で渡すと clap が
# それを `-i` の追加ファイルとして解釈し `No prompt provided via stdin` になる)。
printf '%s' "$CODEX_PROMPT" | CODEX_HOME="$CODEX_TMP_HOME" codex "${CODEX_ARGS[@]}" -

# 自セッション dir は CODEX_TMP_HOME/generated_images 配下に 1 つだけ存在する
# (並列他セッションとは物理的に分離されている)。最新 png を pick する。
SRC_PNG=$(ls -t "$CODEX_TMP_HOME/generated_images"/*/ig_*.png 2>/dev/null | head -1)
if [[ -z "$SRC_PNG" || ! -f "$SRC_PNG" ]]; then
  echo "Error: codex did not produce any ig_*.png under $CODEX_TMP_HOME/generated_images" >&2
  exit 1
fi

echo "[codex-image] converting $SRC_PNG -> $OUTPUT_ABS"
magick "$SRC_PNG" -resize '1920x1080^' -gravity center -extent 1920x1080 "$OUTPUT_ABS"

if [[ ! -f "$OUTPUT_ABS" ]]; then
  echo "Error: magick failed to produce $OUTPUT_ABS" >&2
  exit 1
fi

SIZE=$(stat -f '%z' "$OUTPUT_ABS" 2>/dev/null || wc -c < "$OUTPUT_ABS")
echo "[codex-image] done: $OUTPUT_ABS ($SIZE bytes)"
