---
name: run-eval-loop-cancel
template: core
description: 実行中の品質ループを停止したい場面で発動。「ループ停止」で発動。
user-invocable: true
allowed-tools: Bash, Read
---

Eval loop をキャンセルします。

## Step 1: アクティブセッション検出

serial eval (sessions/) と parallel eval (agents/) の両方を検索します:

```bash
for f in .mso/sessions/*/state.json .mso/agents/*/state.json; do
  [ -f "$f" ] || continue
  active=$(jq -r '.active' "$f" 2>/dev/null)
  if [ "$active" = "true" ]; then
    mode="serial"
    echo "$f" | grep -q "/agents/" && mode="parallel"
    task=$(jq -r '.task // "unknown"' "$f" 2>/dev/null)
    iter=$(jq -r '.iteration' "$f" 2>/dev/null)
    max=$(jq -r '.max_iterations' "$f" 2>/dev/null)
    score=$(jq -r '.latest_score // "none"' "$f" 2>/dev/null)
    echo "ACTIVE: $f (mode=$mode, task=$task, iter=$iter/$max, score=$score)"
  fi
done
```

## Step 2: キャンセル実行

- **アクティブが1つだけ**: そのセッションを自動キャンセル
- **アクティブが複数**: 親にリスト表示してどれをキャンセルするか確認。「全部」も選択肢に含める
- **アクティブなし**: 「アクティブなループはありません」と親に報告

キャンセル実行:
```bash
CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop-cancel.sh "<STATE_FILE>"
```

eval loop 中であれば STATE_FILE パスがコンテキストに残っているはずです。そちらのパスがある場合は直接使ってください。

実行後、「Eval loop cancelled」と表示されれば成功です。
