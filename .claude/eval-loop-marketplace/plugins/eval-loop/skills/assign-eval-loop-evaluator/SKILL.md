---
name: assign-eval-loop-evaluator
template: core
description: eval-loop の汎用 evaluator。run-eval-loop から呼ばれる (internal)。
user-invocable: false
context: fork
agent: general-purpose
model: opus
pair: assign-eval-loop-generator
---

# assign-eval-loop-evaluator

## コンテキスト (スキル読み込み時に自動展開)

```json
!`cat $ARGUMENTS`
```

## コンテキスト JSON のキー

| キー | 内容 |
|------|------|
| `project_dir` | 作業対象のプロジェクトディレクトリ (絶対パス) |
| `task` | ユーザーが指定した task 原文。**評価軸の最終的な拠り所**。plan より優先する |
| `criteria` | 品質基準 (カンマ区切り文字列)。`quality.breakdown` のキーはここから抽出して**固定**する |
| `threshold` | 合格スコア (0-100) |
| `plan` | このイテレーションの実行計画 (Markdown 全文)。**実装確認の参考であって評価軸ではない** |
| `turns_dir` | ターンログの保存先ディレクトリ (絶対パス) |
| `iteration` | 現在のイテレーション番号 (0 = 初回) |
| `output_contract` | 出力先と JSON スキーマの仕様。`eval_file`(書き込み先パス)、`schema`(出力フォーマット)、`instructions`(評価指示) を含む |

## ワークフロー

### Step 1: 成果物の検証

- **`project_dir` の実際のファイルを Read で読んで検証する。** Generator の自己申告を鵜呑みにしない。
- 非コードタスクの場合、成果物は `turns_dir/turn-{NNN}-output.md` にある可能性がある。`plan` の内容を確認し、`project_dir` と `turns_dir` の両方を検査すること。
- テストがあれば Bash で実行して結果を確認する。

### Step 2: 主軸で評価 (Quality) + 補助 (Plan Implementation)

**主軸 — Quality**: `task` の達成度と `criteria` の各項目への適合を**絶対評価**する。これがスコアの拠り所。

- **`quality.breakdown` のキーは `criteria` から抽出して固定する。** イテレーション間で同一キーを使う (収束を時系列で追えるようにするため)。
- 新たに発見した観点は `feedback` に書く。`breakdown` に新しいキーとして追加しない。
- `task` 原文と乖離した実装は、たとえ `plan` に沿っていても低くつける (plan は task の派生物にすぎず、ドリフトしうる)。

**補助 — Plan Implementation**: `plan` の Changes が実装されたかの実装率。

- これはあくまで進捗確認の補助指標。**`score` 算出には使わない。**
- `plan` の Acceptance Criteria を「期待される答え」として読まないこと。それに沿うことを評価対象にすると、間違った方向の plan が高スコアになる (確証バイアス)。

### Step 3: 採点

- **成果物の絶対品質で評価する。** 前回からの改善度ではない。毎回ゼロベース。
- 採点は **100点満点 (0-100)**。`threshold` は合格ラインであり満点ではない。
- **`score` は `quality.overall` と一意に同値とする。** 重みのブレを排除する。
- **`criteria` の各項目を個別に採点する。** キーは固定。

### Step 4: 評価結果をファイルに保存

以下の JSON を **Write ツールで `output_contract.eval_file` に直接書き込む**:

(`output_contract` がない場合のフォールバック: `{turns_dir}/turn-{NNN}-eval.json`、`{NNN}` は `iteration` の3桁ゼロパディング)

```json
{
  "score": <quality.overall と同値の 0-100>,
  "quality": {
    "overall": <0-100 task と criteria への絶対適合度>,
    "breakdown": {"<criteria 項目1 (固定キー)>": <0-100>, "<criteria 項目2 (固定キー)>": <0-100>}
  },
  "plan_implementation": {
    "overall": <0-100 plan の Changes が実装された割合>,
    "notes": "<未実装項目があればメモ>"
  },
  "feedback": "<task の本来の目的への適合を最優先で具体的な改善指示。合格でも残る改善余地を記載>",
  "passed": <score >= threshold>,
  "evaluator_skill": "assign-eval-loop-evaluator"
}
```

### Step 5: 完了報告

保存したファイルパスとスコアを報告する。

## ルール

- **`project_dir` のファイルを変更しない。** 観察と判定のみ。書き込みは `turns_dir` への評価 JSON のみ。
- **全項目を採点する。** plan の Acceptance Criteria も criteria の項目も省略しない。
- **具体的なフィードバックを書く。** 何がどう良い/悪いか、どう改善すべきか。
- **甘くしない。** 合格ラインに達していなければ正直に低い点をつける。
- **feedback は Planner が読む。** 次イテレーションで Planner がこの feedback を基に修正計画を立てる。戦略レベルの示唆も含めること。
