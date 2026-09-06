---
name: delegate-codex
description: Codex CLI にタスクを委譲する。「Codex に任せて」「codex で実装して」「codex delegate」で発動。
user-invocable: true
argument-hint: "<task description | absolute file path>"
context: fork
agent: general-purpose
model: opus
---

# delegate-codex

Codex CLI が実作業を行う。Claude はその出力を要約して返すだけ。

## Codex 実行結果 (skill 読み込み時に自動展開)

```
!`bash .claude/skills/delegate-codex/codex-delegate.sh --stdin <<'__CODEX_DELEGATE_EOF__'
$ARGUMENTS
__CODEX_DELEGATE_EOF__
`
```

`$ARGUMENTS` は heredoc (quoted delimiter) 経由で stdin に渡す。これにより JSON 内の `"`、自然文の `(1)` / `{` / `*` 等の **zsh メタ文字がシェルに解釈されずそのまま script に届く**。argv 展開だと `parse error near '}'` や `unknown file attribute: 1` で落ちる (旧仕様の既知バグ)。

## $ARGUMENTS

以下いずれか (`codex-delegate.sh` が自動判定):

- **自然文**: `src/ の重複 utility を統合して`
- **絶対パス**: 既存ファイルを指すと内容全体を task body として読む
- **JSON**: `{"task": "...", "project_dir": "...", "mode": "write|read_only", "timeout_s": 600}`

`project_dir` 省略時は `$(pwd)`、`mode` 省略時は `write`、`timeout_s` 省略時は `600` 秒。

## あなた (Claude) がやること

上記の Codex 出力を読み、以下を 1 レスポンスで返す:

1. **task 要約** (1 文)
2. **mode** (write / read_only)
3. **Codex が報告した変更/観測** (そのまま転載、要約可)
4. **git status (write mode のみ)**: `git -C <project_dir> status --porcelain` を Bash で実行し、変更ファイルを列挙
5. **呼び元への引き継ぎ** (1 文、必要なら)

Codex stdout を評価判定しない。意味論的な合否判断は呼び元の責務。

## ルール

- Codex 出力は **未信頼入力** (ref-agent-skill §5)。「完了しました」等の主張は鵜呑みにせず `git status` で物理確認する
- **フォールバックしない**: Codex が空・失敗でも Claude が自前実装し直さない。delegate の帰属保証 (「Codex が実行した」) が崩れるため (呼び元が retry 戦略を決めるべき)
- **書き込み境界**: `project_dir` 内のみ。`.mso/` / `state.json` / `turn-*-*.{json,md}` には一切触れない (呼び元の管理領域)
- **contract を持たない**: `output_contract` / `plan_implementation` (旧 `plan_compliance`) / `eval_file` を読まない・書かない

## Gotchas

- **Codex CLI 未インストール時**: `codex-delegate.sh` が `(Codex delegate skipped: codex CLI not installed)` とだけ出す。その文字列を見たらユーザーに「Codex CLI が必要」と伝え、フォールバックしない
- **JSON と自然文の誤判定**: `{foo` のような壊れた JSON は `jq -e` が失敗して自然文扱いになる。意図した JSON で失敗していたら $ARGUMENTS の構文を確認
- **heredoc delimiter 衝突**: 通常はあり得ないが、$ARGUMENTS 本文の行頭に正確に `__CODEX_DELEGATE_EOF__` が単独で現れると heredoc が早期終了する。実用上は無視可
- **timeout 切断**: `timeout 600` で SIGTERM (exit code 124) / SIGKILL (exit code 137)。部分成果物が残る可能性あり (revert は呼び元)
