# eval-loop

品質スコアが目標に達するまで自律ループで成果物を改善する Claude Code プラグイン。
eval-loop 系コマンド・スキルを単独プラグインとして切り出したもの。

## 構成

```
eval-loop/                              ← ディレクトリ marketplace のルート
├── .claude-plugin/marketplace.json     ← marketplace 定義 (plugin "eval-loop")
└── plugins/eval-loop/                   ← プラグイン本体
    ├── .claude-plugin/plugin.json
    ├── hooks/hooks.json                 ← UserPromptSubmit / Stop / SubagentStart / SubagentStop
    ├── scripts/                         ← ループ制御スクリプト群
    └── skills/                          ← 8 スキル
```

## コマンド (user-invocable スキル)

| コマンド | 用途 |
|----------|------|
| `/run-eval-loop` | 単一の品質ループ (serial)。メイン会話で plan→generator→evaluator を回す |
| `/run-eval-loop-fork` | ループを subagent にフォークし会話履歴をメインに残さない |
| `/run-eval-loop-parallel` | 複数タスクの品質ループを並列実行 (`;` 区切り) |
| `/run-eval-loop-cancel` | 実行中のループを停止 (serial/parallel 両対応) |

## 内部スキル (evaluator/generator, user-invocable=false)

| スキル | 役割 |
|--------|------|
| `assign-eval-loop-generator` | 計画に従って実装する汎用 generator (デフォルト) |
| `assign-eval-loop-evaluator` | task/criteria で絶対評価する汎用 evaluator (デフォルト) |
| `assign-multi-evaluator` | 複数 evaluator を dispatch して保守的に集約する ensemble (veto gate 対応) |
| `assign-debate-evaluator` | Codex(GPT)+Claude の debate 形式 evaluator (Codex 無しは Advocate/Critic に縮退) |

`evaluator` 引数で evaluator を差し替え可能 (例: `evaluator: assign-debate-evaluator`)。

## 仕組み (hooks)

- **UserPromptSubmit** (`hook-prompt-submit.sh`): `EVAL_LOOP_SESSION_ID` を注入。active ループの状態・write_targets 衝突・stale 検知も通知。
- **Stop** (`hook-stop.sh` → `loop-control.sh`): serial ループの継続/終了判定。`phase=eval` かつ `score < threshold` で `{"decision":"block"}` を返して次イテレーションを自動開始。
- **SubagentStart** (`hook-subagent-start.sh`): fork/parallel 用に `.mso/agents/<id>/state.json` を事前生成し、`EVAL_LOOP_STATE`/`EVAL_LOOP_TURNS_DIR` を subagent に注入。
- **SubagentStop** (`hook-subagent-stop.sh` → `loop-control.sh`): fork/parallel ループの継続/終了判定。

状態は project 直下 `.mso/sessions/<session_id>/` (serial) または `.mso/agents/<agent_id>/` (fork/parallel) に保存。git リポジトリでは各イテレーションを `refs/eval-loop/...` の隠し ref に snapshot 保存し、`loop-snapshot.sh --restore` で write_targets 限定復元できる。

## インストール

```bash
# 1. marketplace を登録 (ディレクトリ marketplace)
claude plugin marketplace add /path/to/eval-loop

# 2. プロジェクトで有効化
cd /path/to/your-project
claude plugin install eval-loop@eval-loop --scope project
```

`claude plugin validate plugins/eval-loop --strict` で検証可能。
