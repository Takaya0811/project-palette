#!/usr/bin/env bash
#
# run-ai-images - 汎用 AI 画像生成 (codex exec + image_gen, 並列安全)
#
# 指定プロンプトで N 枚の画像を並列生成する。各 worker は CODEX_HOME を
# per-invocation で隔離するため、同時起動時の png 衝突は起きない。
#
# Usage:
#   generate.sh -o <output-prefix> -p <prompt> [options]
#
# Required:
#   -o, --output-prefix <path>    出力 prefix (結果は <prefix>-01.<ext>, <prefix>-02.<ext>, ...)
#   -p, --prompt <text>           画像生成プロンプト
#
# Options:
#   -n, --count <N>               生成枚数 (default: 4)
#   --aspect <ratio>              王道アスペクト比 (1:1 / 3:2 / 2:3 / 16:9 / 9:16)
#                                   image_gen の native 出力をそのまま保存する (無駄な resize なし)
#                                   実測ピクセル: 1:1 ≈ 1254², 3:2 = 1536×1024, 2:3 = 1024×1536,
#                                                 16:9 ≈ 1672×941, 9:16 ≈ 941×1672
#   --size <WxH>                  ピクセル厳密指定 (--aspect と排他)
#                                   magick で WIDTHxHEIGHT に resize + center-extent する。
#                                   CMS・印刷など厳密なピクセル数が必要な時の escape hatch。
#   --format <png|webp|jpg>       出力フォーマット (default: png)
#   --quality <high|medium|low>   品質 (default: high)
#   --ref-image <path>            参照画像 (logo/character 再現用。絶対または repo 相対)
#   --ref-instruction <text>      参照画像の使い方指示 (omit 時: 忠実再現)
#
# 指定なしの default は --aspect 1:1。--aspect と --size 両方指定するとエラー。
#
# Examples:
#   generate.sh -o output/cat -p "a cat wearing a hat"                       # default 1:1 native
#   generate.sh -o output/hero --aspect 16:9 -p "cinematic sunset"           # 16:9 native
#   generate.sh -o output/pixel --size 1920x1080 -p "must be exactly 1080p"  # 厳密 pixel

set -euo pipefail

N=4
OUTPUT_PREFIX=""
PROMPT=""
SIZE=""
ASPECT=""
FORMAT="png"
QUALITY="high"
REF_IMAGE=""
REF_INSTRUCTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-prefix) OUTPUT_PREFIX="$2"; shift 2 ;;
    -p|--prompt)        PROMPT="$2"; shift 2 ;;
    -n|--count)         N="$2"; shift 2 ;;
    --size)             SIZE="$2"; shift 2 ;;
    --aspect)           ASPECT="$2"; shift 2 ;;
    --format)           FORMAT="$2"; shift 2 ;;
    --quality)          QUALITY="$2"; shift 2 ;;
    --ref-image)        REF_IMAGE="$2"; shift 2 ;;
    --ref-instruction)  REF_INSTRUCTION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Error: unknown option '$1'" >&2
      exit 1 ;;
  esac
done

# --aspect と --size は排他 (意図の競合)
if [[ -n "$ASPECT" && -n "$SIZE" ]]; then
  echo "Error: --aspect and --size are mutually exclusive" >&2
  echo "  --aspect: image_gen の native 出力をそのまま保存 (無駄な resize なし)" >&2
  echo "  --size:   magick で厳密ピクセルに正規化 (escape hatch)" >&2
  exit 1
fi

# 指定なしは --aspect 1:1 を default とする
[[ -z "$ASPECT" && -z "$SIZE" ]] && ASPECT="1:1"

# --aspect は image_gen に渡すラベル (width:height)。image_gen 側で pixel は丸められる
if [[ -n "$ASPECT" ]]; then
  case "$ASPECT" in
    1:1|3:2|2:3|16:9|9:16) ;;
    *) echo "Error: --aspect must be one of 1:1 / 3:2 / 2:3 / 16:9 / 9:16" >&2; exit 1 ;;
  esac
fi

if [[ -z "$OUTPUT_PREFIX" || -z "$PROMPT" ]]; then
  echo "Error: -o <output-prefix> and -p <prompt> are required" >&2
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

case "$FORMAT" in
  png|webp|jpg|jpeg) ;;
  *) echo "Error: --format must be one of png / webp / jpg" >&2; exit 1 ;;
esac

if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
  echo "Error: -n must be a positive integer" >&2
  exit 1
fi

if [[ -n "$SIZE" ]] && ! [[ "$SIZE" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Error: --size must be WIDTHxHEIGHT (e.g. 1920x1080)" >&2
  exit 1
fi

# 相対パスは repo root 相対で解決
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
resolve_abs() {
  case "$1" in
    /* ) printf '%s' "$1" ;;
    *  ) printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

OUTPUT_PREFIX_ABS="$(resolve_abs "$OUTPUT_PREFIX")"
mkdir -p "$(dirname "$OUTPUT_PREFIX_ABS")"

if [[ -n "$REF_IMAGE" ]]; then
  REF_IMAGE="$(resolve_abs "$REF_IMAGE")"
  if [[ ! -f "$REF_IMAGE" ]]; then
    echo "Error: ref image not found: $REF_IMAGE" >&2
    exit 1
  fi
fi

CODEX_HOME_ORIG="${CODEX_HOME:-$HOME/.codex}"

# ---------------- 1 枚生成関数 (subshell で呼ぶため trap は関数内で OK) ----------------
gen_one() {
  local idx="$1"
  local padded
  padded=$(printf '%02d' "$idx")
  local out="${OUTPUT_PREFIX_ABS}-${padded}.${FORMAT}"

  # CODEX_HOME を per-worker で隔離 (race 回避の要)
  local tmp_home
  tmp_home=$(mktemp -d -t "codex-genai.${padded}.XXXXXX")
  trap "rm -rf '$tmp_home'" EXIT

  if [[ -d "$CODEX_HOME_ORIG" ]]; then
    shopt -s dotglob nullglob 2>/dev/null || true
    local item name
    for item in "$CODEX_HOME_ORIG"/*; do
      name=$(basename "$item")
      [[ "$name" == "generated_images" ]] && continue
      ln -s "$item" "$tmp_home/$name"
    done
  fi
  mkdir -p "$tmp_home/generated_images"

  local ref_step=""
  if [[ -n "$REF_IMAGE" ]]; then
    ref_step="- 添付した参照画像を元に、${REF_INSTRUCTION:-参照画像のデザイン・キャラクター・ロゴを忠実に再現すること}。"
  fi

  # image_gen に渡す size ヒント: ASPECT 指定時はアスペクト文字列、SIZE 指定時は WxH
  local size_hint
  if [[ -n "$ASPECT" ]]; then
    size_hint="${ASPECT} aspect ratio"
  else
    size_hint="${SIZE} resolution"
  fi

  local codex_prompt
  codex_prompt=$(cat <<EOF
次の指示に従って画像を 1 枚生成してください。**出力先は \$CODEX_HOME/generated_images/<session_id>/ 以下に image_gen が自動保存するため、保存先の指定・変換・コピーは不要です。呼び出し側が後処理します。**

## 手順
1. image_gen ツールで下記「プロンプト」の内容を **${size_hint} / quality=${QUALITY}** で生成する。image_gen のプロンプト末尾に必ず "${size_hint}, ${QUALITY} quality" を含めること。image_gen はアスペクト比を尊重するが画素数は内部バジェット (~1.5MP) で丸められる点は承知しておくこと。
${ref_step}
2. 画像が生成されたら、\`ls \$CODEX_HOME/generated_images/*/*.png | head -1\` で存在を確認するだけで良い。
3. **他のファイルは作らない。magick 等の変換も一切不要。**

## プロンプト
${PROMPT}

## 制約
- 失敗したら 1 回だけ image_gen をリトライしてよい。
- 最終メッセージは \`OK\` もしくは \`NG <理由>\` の 1 行のみ。
EOF
)

  local codex_args=(
    exec
    -s
    workspace-write
    --skip-git-repo-check
    -C "$REPO_ROOT"
    -c model="gpt-6-astra"
    -c model_reasoning_effort="medium"
  )
  [[ -n "$REF_IMAGE" ]] && codex_args+=(-i "$REF_IMAGE")

  echo "[run-ai-images $padded] CODEX_HOME=$tmp_home -> $out"
  printf '%s' "$codex_prompt" | CODEX_HOME="$tmp_home" codex "${codex_args[@]}" - >/dev/null

  local src_png
  src_png=$(find "$tmp_home/generated_images" -type f -name '*.png' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  if [[ -z "$src_png" || ! -f "$src_png" ]]; then
    echo "[run-ai-images $padded] ERROR: no png produced under $tmp_home/generated_images" >&2
    return 1
  fi

  # --aspect: image_gen の native 出力を保存 (format のみ変換、resize なし)
  # --size:   magick で厳密ピクセルに resize + center-extent
  if [[ -n "$ASPECT" ]]; then
    magick "$src_png" "$out"
  else
    magick "$src_png" -resize "${SIZE}^" -gravity center -extent "$SIZE" "$out"
  fi
  if [[ ! -f "$out" ]]; then
    echo "[run-ai-images $padded] ERROR: magick failed to produce $out" >&2
    return 1
  fi

  local size
  size=$(stat -f '%z' "$out" 2>/dev/null || wc -c < "$out")
  echo "[run-ai-images $padded] done: $out ($size bytes)"
}

# ---------------- 並列 fire & wait ----------------
echo "[run-ai-images] generating $N image(s) prefix=$OUTPUT_PREFIX_ABS ${ASPECT:+aspect=$ASPECT}${SIZE:+size=$SIZE} format=$FORMAT"

pids=()
for i in $(seq 1 "$N"); do
  ( gen_one "$i" ) &
  pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=$((failed+1))
  fi
done

ok=$((N - failed))
echo "[run-ai-images] result: $ok/$N succeeded"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
