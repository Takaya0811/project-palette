---
name: assign-debate-evaluator
template: core
description: debate 形式で成果物を採点する evaluator。run-eval-loop から呼ばれる (internal)。
user-invocable: false
context: fork
agent: general-purpose
model: opus
---

# assign-debate-evaluator

成果物を **Debate 形式** で評価する。Codex (GPT) が独立に評価し、Claude が独自に評価した後、両方の視点を統合して最終判定を下す。

出力 JSON は `assign-eval-loop-evaluator` の `score` / `quality` / `plan_implementation` / `feedback` / `passed` / `evaluator_skill` と互換。オーケストレーターは `score` と `passed` のみ読むため、追加の `debate` フィールドは無視される（上位互換）。

**新 schema 規約**:
- `score` = `quality.overall` と一意同値 (旧 plan_compliance との重み付き複合は廃止)
- `quality.breakdown` のキーは `criteria` 項目で iteration 間**固定** (新観点は `feedback` または `debate.unique_findings` に書き、`breakdown` のキーには足さない)
- `plan_implementation` は補助指標で score 算出に使わない

## コンテキスト (スキル読み込み時に自動展開)

```json
!`cat $ARGUMENTS`
```

## コンテキスト JSON のキー

| キー | 内容 |
|------|------|
| `project_dir` | 作業対象のプロジェクトディレクトリ (絶対パス) |
| `criteria` | 品質基準 |
| `threshold` | 合格スコア (0-100) |
| `plan` | Planner が作成した実行計画 (Markdown 全文) |
| `turns_dir` | ターンログの保存先ディレクトリ (絶対パス) |
| `iteration` | 現在のイテレーション番号 (0 = 初回) |
| `output_contract` | 出力先と JSON スキーマの仕様。`eval_file`(書き込み先パス)、`schema`(出力フォーマット)、`instructions`(評価指示) を含む |

## Codex 独立評価 (スキル読み込み時に自動展開)

```
!`CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT} bash ${CLAUDE_PLUGIN_ROOT}/skills/assign-debate-evaluator/scripts/codex-debate-eval.sh $ARGUMENTS`
```

## ワークフロー

### Phase 1: Codex 評価の確認

上記で事前展開された Codex の評価結果を読む。Codex がスキップされた場合（CLI未インストール等）は Phase 2 の Claude 単独評価 + Phase 3 で自ら対立見解を構築する。

### Phase 2: Claude 独自評価

Codex とは**独立に**、以下の手順で成果物を評価する。Codex の評価に引きずられないこと。

#### 2a. 成果物の検証（決定論的）

- **`project_dir` の実際のファイルを Read で読んで検証する。** Generator の自己申告を鵜呑みにしない。
- 非コードタスクの場合、成果物は `turns_dir/turn-{NNN}-output.md` にある可能性がある。`plan` の内容を確認し、`project_dir` と `turns_dir` の両方を検査すること。
- テストがあれば Bash で実行して結果を確認する。

#### 2b. Quality 評価 (主軸、score の拠り所)

`criteria` の**各項目について個別に**採点:

- 成果物の絶対品質で評価する（改善度ではない）
- 各項目 0-100 で採点し、根拠を明記
- `task` 原文と乖離した実装は、たとえ `plan` に沿っていても低くつける
- **breakdown キー安定化ルール**: `quality.breakdown` のキーは `criteria` 項目で iteration 間**固定**。新観点は `feedback` または `debate.unique_findings` に書き、`breakdown` のキーには足さない。これにより、イテレーション間でキーが安定し、収束速度が向上する。

#### 2c. Plan Implementation 評価 (補助、score 算出には使わない)

`plan` の Changes が実装されたかを進捗確認として記録:

- 実装率を 0-100 で `plan_implementation.overall` に
- 未実装項目は `plan_implementation.notes` に文字列で
- `plan` の Acceptance Criteria を「期待される答え」として読まない (確証バイアス回避)。それに沿うことを評価対象にすると、間違った方向の plan が高スコアになる

### Phase 3: Debate 統合

Codex 評価と Claude 評価を突き合わせ、**対立・合意を分析**する。

#### 3者構成 (Codex + Claude → Judge)

- **合意点**: 両者が同じ評価をした項目 → 確度が高い
- **相違点**: 評価が分かれた項目 → 両者の根拠を比較し、どちらが妥当か判断
- **片方のみが指摘した問題**: 独自の視点として重み付け

#### 2者構成 (Claude のみ、Codex スキップ時)

Claude が自ら **Advocate（肯定側）** と **Critic（否定側）** の両方の視点を構築する:

- **Advocate**: 成果物の強み、計画への準拠、良い設計判断を主張
- **Critic**: 成果物の弱み、見落とし、品質不足を主張
- 両方の主張を踏まえて最終判定

### Phase 4: 各側の採点

- **各側が独立に 0-100 で採点する。** 平均は取らない。
- Quality の breakdown と plan_implementation も各側が個別に出す。各側の `score` は **その側の `quality.overall` と一意同値** (新 schema 規約)。
- **各側の `quality.breakdown` のキーは `criteria` 項目で iteration 間固定。** 両側で同じキーを使うことで比較が可能になる。新たに発見した問題は `feedback` や `debate.unique_findings` に書き、`breakdown` に新しいキーとして追加しない。
- top-level の `score` / `quality` / `plan_implementation` には **side_b（Claude / Critic）の値を暫定で入れる。** オーケストレーターが debate メタデータを見て最終調整する (`score` は state.json の `latest_score` 上書きで反映)。

### Phase 5: 評価結果をファイルに保存

以下の JSON を **Write ツールで `output_contract.eval_file` に直接書き込む**:

(`output_contract` がない場合のフォールバック: `{turns_dir}/turn-{NNN}-eval.json`、`{NNN}` は `iteration` の3桁ゼロパディング)

```json
{
  "score": <side_b の quality.overall 0-100 (暫定、quality.overall と一意同値)>,
  "quality": {
    "overall": <side_b の quality 0-100>,
    "breakdown": {"<criteria 項目1 (固定キー)>": <0-100>, "<criteria 項目2 (固定キー)>": <0-100>}
  },
  "plan_implementation": {
    "overall": <side_b の plan 実装率 0-100 (補助指標、score 算出には使わない)>,
    "notes": "<未実装項目があればメモ>"
  },
  "debate": {
    "mode": "<3者構成: 'codex_vs_claude' / 2者構成: 'advocate_vs_critic'>",
    "scores": {
      "side_a": <Codex or Advocate の総合スコア 0-100 (= side_a の quality.overall)>,
      "side_b": <Claude or Critic の総合スコア 0-100 (= side_b の quality.overall)>,
      "side_a_breakdown": {"<criteria 項目1>": <0-100>, "<criteria 項目2>": <0-100>},
      "side_b_breakdown": {"<criteria 項目1>": <0-100>, "<criteria 項目2>": <0-100>}
    },
    "consensus": ["<両者が合意した評価ポイント>"],
    "disagreements": [
      {
        "topic": "<争点>",
        "severity": "<high / medium / low>",
        "position_a": "<Codex or Advocate の主張>",
        "position_b": "<Claude or Critic の主張>"
      }
    ],
    "unique_findings": {
      "side_a_only": ["<Codex/Advocate のみが指摘>"],
      "side_b_only": ["<Claude/Critic のみが指摘>"]
    }
  },
  "feedback": "<3 軸 (high → medium → low) を畳み込んだ string サマリ。Debate の結論を踏まえる。新観点はここか debate.unique_findings に書き、breakdown キーには足さない>",
  "feedback_structured": {
    "high":   [{"area": "<criteria 項目キー>", "message": "<指摘 + 修正案 (generator が動ける粒度)>"}],
    "medium": [{"area": "...", "message": "..."}],
    "low":    [{"area": "...", "message": "..."}]
  },
  "passed": <score >= threshold (暫定)>,
  "evaluator_skill": "assign-debate-evaluator"
}
```

`feedback_structured` は他 evaluator と互換 (assign-multi-evaluator がアンサンブルで読む)。`area` は `quality.breakdown` のキーと整合させる。

### Phase 6: 完了報告

保存したファイルパスと両者のスコアを報告する。主要な争点があれば言及する。

## ルール

- **`project_dir` のファイルを変更しない。** 観察と判定のみ。書き込みは `turns_dir` への評価 JSON のみ。
- **全項目を採点する。** plan の Acceptance Criteria も criteria の項目も省略しない。
- **Codex 評価に迎合しない。** Codex と異なる結論に至った場合、自分の分析を優先し、相違点として明記する。
- **甘くしない。** 合格ラインに達していなければ正直に低い点をつける。Debate で合意された問題は特に厳しく。
- **feedback は Planner が読む。** 次イテレーションで Planner がこの feedback を基に修正計画を立てる。Debate の争点と結論を含めること。
- **debate フィールドは必須。** Codex スキップ時は Advocate/Critic の分析を記載する。

## Gotchas

（運用で発見された失敗パターンをここに追記する）
