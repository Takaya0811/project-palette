---
name: assign-eval-loop-generator
template: core
description: eval-loop の汎用 generator。run-eval-loop から呼ばれる (internal)。
user-invocable: false
context: fork
agent: general-purpose
model: opus
pair: assign-eval-loop-evaluator
---

# assign-eval-loop-generator

## コンテキスト (スキル読み込み時に自動展開)

```json
!`cat $ARGUMENTS`
```

## コンテキスト JSON のキー

| キー | 内容 |
|------|------|
| `project_dir` | 作業対象のプロジェクトディレクトリ (絶対パス) |
| `task` | ユーザーが指定した task 原文。**最終的な目的の拠り所**。plan と乖離があれば task を優先する |
| `plan` | このイテレーションの実行計画 (Markdown 全文)。Changes と Acceptance Criteria を含む |
| `criteria` | 品質基準 (例: "正確性, テストカバレッジ, 可読性") |
| `iteration` | 現在のイテレーション番号 (0 = 初回) |
| `turns_dir` | ターンログの保存先ディレクトリ (絶対パス) |

**注意:** Evaluator からの feedback は直接届かない。Planner が feedback を分析し、修正方針を `plan` に織り込み済み。`plan` の Changes に従えばよい。ただし `plan` は `task` の派生物であり、ドリフトしうる。両者が乖離する場合は `task` を優先し、その判断と理由を Step 5 のレポートに明記すること (T-2.2)。

## 指示

上記の JSON コンテキストに従って、**計画 (`plan`) に厳密に従って**実装する。

- **`project_dir` で作業する。** 他のディレクトリのファイルを変更しない。
- `iteration` が 0 (初回) なら新規作成。1以上なら前回の成果物を改善。

## ワークフロー

以下の順序で実行すること:

### Step 1: 計画の確認

`plan` の **Changes** セクションと **Acceptance Criteria** を読み、実装すべき項目を把握する。

### Step 2: 現状把握

- Glob / Read で `project_dir` のファイル構造と既存コードを確認する
- 変更対象のファイルを特定する

### Step 3: 実装

`plan` の Changes に従い、1項目ずつ実装する:

- **既存ファイルの変更**: Read でファイルを読み、Edit で変更する
- **新規ファイルの作成**: Write で作成する
- **ファイルの削除**: Bash で削除する
- **`criteria` を意識して品質を確保する。** 計画にない変更はしない。

### Step 4: 検証

- テストがあれば Bash で実行し、全パスを確認する
- lint / type check があれば実行する
- Acceptance Criteria を1項目ずつ自己チェックする

### Step 5: 結果報告をファイルに保存

以下の内容を **Write ツールで直接ファイルに書き込む**:

```
ファイルパス: {turns_dir}/turn-{NNN}-generator.md
```

`{NNN}` は `iteration` を3桁ゼロパディング (例: iteration 0 → `turn-000-generator.md`)。

内容:
1. **変更内容** — 変更したファイル、追加した機能、修正した箇所
2. **計画との対応** — Changes の各項目にどう対応したか（変更内容と計画項目の対応のみ記載。合否判定は書かない — 合否判定は Evaluator の責務）
3. **テスト結果** — 実行した場合はその結果

## ルール

- **書き込み境界**:
  - **コードタスク** (ソースコード・設定ファイルの変更): `project_dir` 内の既存プロジェクトファイルを変更する
  - **非コードタスク** (文書作成・コンテンツ生成): 成果物は `turns_dir/turn-NNN-output.md` に書き込む。`project_dir` のルートに新規ファイルを作成しない
  - **レポート**: `turns_dir/turn-NNN-generator.md` にのみ書き込む
  - `.mso/` ディレクトリには一切書き込まない（`turns_dir` 内の自分のレポート・成果物を除く）
  - `*-eval.json`、`state.json`、`*-plan.md` には書き込まない — これらは他フェーズの成果物
- **戦略判断をしない** — 「何を変えるか」は plan が決めている。Generator は「どう実装するか」だけに集中する
- 計画に曖昧な点がある場合は、最も自然な解釈で実装する。計画自体を変更しない
- Step を飛ばさない。特に Step 4 の検証は省略しない
