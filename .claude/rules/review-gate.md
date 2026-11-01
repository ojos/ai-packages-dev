---
paths:
  - "scripts/loop-gate.sh"
  - "scripts/second-opinion-*.sh"
  - "scripts/second-opinion-schema.json"
  - "scripts/verify.sh"
  - "scripts/acceptance.sh"
  - ".github/workflows/ci.yml"
  - ".github/workflows/identity-guard.yml"
  - ".github/workflows/second-opinion-gate.yml"
  - ".ai-playbook/review-workflow.md"
  - ".ai-playbook/loop-workflow.md"
  - ".claude/skills/land/SKILL.md"
  - "tests/test-review-options.sh"
  - "tests/test-ci-mirror.sh"
---

地図（`.github/project-ai-rules.md`）の「レビューとゲート」の詳細です。ゲートの回し方の要点（`loop-gate.sh`・却下の記録・`post`）は地図が常時持ちます。

## レビューの起動方法

共通規範「レビューワークフロー」（`.ai-playbook/review-workflow.md`）のクロスモデル二段ゲートと、「ループ運用」（`.ai-playbook/loop-workflow.md`）のローカル事前ゲートを、このリポジトリで具体化します。

下記 1 の主レビューの前に、共通規範「品質整理（任意の前段）」（`.ai-playbook/review-workflow.md`）を置けます。ここでいう「受け入れ条件を満たした後」は、手元で `scripts/verify.sh` が緑になった後を指します。下記 2 の受け入れ検証は、整理後の差分に対して `loop-gate.sh` が改めて通します。位置・回数・非ゲートの制約は同節に従い、ここでは起動手段と対象範囲だけを定めます。

- **起動手段**: Claude Code の `/simplify` を、受け入れ条件を満たした後・主レビューの前に 1 回だけ実行します。`loop-gate.sh` には含めません。
- **対象はコードに限ります。** このリポジトリでは `*.sh`（`scripts/` / `tests/` / `packages/` / `.ai-playbook/templates/` 配下を含む）と、`.github/workflows/` の YAML が該当します。
- **Markdown は対象外です。** `.sh` の中にヒアドキュメントで埋め込まれ、配布先へ文書として書き出される本文も文章として扱い、対象から外します。規範の理由文が簡素化で削られるのを防ぐためです。`/simplify` がこれらへ触れる修正を出したら取り込みません。

push / PR 作成の前に、次の 3 段を通します。

1. **主レビュー**: Claude Code の `/code-review`（セキュリティに関わる差分は `/security-review` も）でステージ済み差分をレビューし、その場で修正します。
2. **受け入れ検証**: `scripts/verify.sh` が受け入れ条件を機械判定します。
3. **第二意見**: 別ベンダーのモデル（`scripts/second-opinion-review.sh`）でクロスチェックします。

2 と 3 は**単一入口** `scripts/loop-gate.sh` が直列化します。push / PR 作成の前にこれを通します。

```bash
bash scripts/loop-gate.sh
```

- **`loop-gate.sh` は、上の 3 段の手前で commit identity の検証（`scripts/verify-commit-identity.sh`）を挟みます。** 許可外の identity が混じったコミットを、他のどの段よりも安く・早く（判定は数 ms）検知するためです。ここでいう「3 段」は規範が定める段（主レビュー / 受け入れ検証 / 第二意見）を指し、`loop-gate.sh` 内部の実行順（commit identity → verify → 第二意見という実装上の step 1/2/3）とは別の軸です。両者を混同しないでください。
- 終了コード 0 = `GATE_PASS`（push 可） / 1 = `GATE_FAIL`（いずれかの段が未通過、または実行不能）。
- **レビューする範囲がエージェントの設定・フック（対象の一覧は `packages/devcontainer-bootstrap/README.md`「危険な git の設定の検査」）に触れるときは、そのパスの一覧を出力し、第二意見の依頼文にも重点的に見るよう添えます**（`SECOND_OPINION_AGENT_CONFIG_PATHS`）。任意のコードの実行や権限に関わるのに、差分の中では埋もれるためです。判定は変えません（#671）。
- 第二意見コマンドは環境変数 `LOOP_GATE_REVIEW_CMD` で差し替え（任意のコマンド）・無効化（空文字）できます。未設定のときは `scripts/second-opinion-review.sh` があれば実行し、無ければスキップします。
- **`LOOP_GATE_REVIEW_CMD` で差し替えたコマンドへは、解決した範囲を環境変数 `LOOP_GATE_REVIEW_RANGE` で渡します。** ステージ済み差分が空のときだけ commit 済み範囲（`<起点>..HEAD`）が入り、ステージ済みがあるとき・レビュー対象が無いときは空です。差し替えたコマンドが範囲を受けないと、commit 済みのブランチでは空のステージ済み差分を見て「対象なし」で 0 を返します。`loop-gate.sh` は、レビュー対象が実在するのにその出力（`[second-opinion] no diff to review`）を見たときは、レビューされていないので **`GATE_FAIL` にし、記録も残しません**。レビュー対象が本当に無いと解決したときは、差し替えたコマンドを実行せず、記録なしで通過します（既定の経路と同じ）。
- **限界として、loop-gate が「レビューしていない」と判定できるのは、差し替えたコマンドが `[second-opinion] no diff to review` を出力したときだけです。** 範囲を使わず、この文言も出さない任意のコマンド（例: `true`）は、何もレビューしていなくても `GATE_PASS` と記録が出ます。差し替えるコマンドは、範囲を `LOOP_GATE_REVIEW_RANGE` で受け取るか、自分で範囲を決めて自分で記録を残してください。
- **エンジンだけを変えたいときは、範囲を受ける形で `--engine` を CLI 引数で渡します。**

  ```bash
  LOOP_GATE_REVIEW_CMD='bash scripts/second-opinion-review.sh --engine antigravity ${LOOP_GATE_REVIEW_RANGE:+--range "$LOOP_GATE_REVIEW_RANGE"}' bash scripts/loop-gate.sh
  ```

  - 範囲の受け口（`${LOOP_GATE_REVIEW_RANGE:+--range "$LOOP_GATE_REVIEW_RANGE"}`）を省くと、commit 済みのブランチでは何もレビューされないため、`GATE_FAIL` になります。
  - **環境変数 `SECOND_OPINION_ENGINE=...` を前置する方法は使いません。** `scripts/second-opinion-review.sh` は `scripts/load-project-env.sh` 経由で `.env` を読み、`.env` の値が既存の環境変数を上書きします（優先順位は CLI 引数 > `.env` > 環境変数 > 既定）。`.env` に `SECOND_OPINION_ENGINE` があると、前置した値は無視されます。
  - 差し替えたコマンドが自分で範囲を決める場合は、従来どおり自分で記録を残します（`scripts/second-opinion-record.sh save`）。
- ステージ済み差分が空のときは、`loop-gate.sh` が第二意見の対象を commit 済み範囲へ自動で切り替えます。commit 後にゲートを回すと第二意見が実質スキップされ、偽の緑が出るためです。
- **既定の対象は PR 全体です。** 起点は、`origin/HEAD` → `origin/main` → `origin/master` の順で解決した既定ブランチと HEAD の分岐点（merge-base）にします。ステージ済み差分があるときは `--base <起点>`（起点から索引まで）、空のときは `--range <起点>..HEAD` を渡します（上流があっても上流からではありません）。差分しか見えないエンジンに、修正分だけの小さな差分を渡すと、差分に現れない既存のコードについて誤った前提を立てて落ちるためです。入力が増える分、トークンの消費は増えます。
- 既定ブランチの追跡枝を解決できないときだけ、従来の決め方に戻ります（ステージ済みがあれば reviewer の既定、空なら上流との分岐点 → HEAD。上流が無いとき、または上流との差分が空のとき（push 済みなど）は空ツリー → HEAD。差分が空なのに「対象なし」で通すと、偽の緑になるためです）。追跡枝は fetch しないので、手元が古ければ起点も古くなります。
- 起点と HEAD に差分が無いときは、`no reviewable diff` を出力したうえで `GATE_PASS` とします。空を一律 `GATE_FAIL` にすると、差分の無い状態でのゲート実行が落ちるためです。
- 両段（主レビュー・第二意見）とも対象は致命バグ・脆弱性・型エラー・エッジケースの見落としに限ります。修正は 1 イテレーションで完結させます。

### 指摘の却下

事実誤認の指摘を却下する条件と記録要件は `.ai-playbook/review-workflow.md`「指摘の却下」に従います。このリポジトリでの具体化は次のとおりです。

- **記録の置き先は PR 本文またはその PR へのコメント**です。主レビュー・第二意見のいずれの指摘でも同じ場所へ残します。差分と却下の判断を同じ画面で追えるようにするためです。
- 記録には、実行したコマンドと出力をそのまま含めます。要約だけを書きません。
- **第二意見を却下したうえで `GATE_PASS` を得るときは、記録を残してから `LOOP_GATE_REVIEW_CMD=` で無効化して回します。**

  ```bash
  LOOP_GATE_REVIEW_CMD= bash scripts/loop-gate.sh
  ```

  この経路を使ったことも PR へ記録します。記録の無い無効化は、ゲートを通したのか迂回したのかを区別できなくします。
- **却下できるのはレビュー指摘だけです。** 受け入れ検証（`scripts/verify.sh`）や CI の失敗は却下の対象外で、`VERIFY_ACCEPTANCE` の差し替えで迂回しません。あちらは人の判断を挟まずに合否を生む機械ゲートで、迂回できないことがゲートたる理由だからです。

### 受け入れ検証（verify / acceptance）

```bash
bash scripts/verify.sh
```

- 終了コード 0 = `VERIFY_PASS` / 1 = `VERIFY_FAIL`（未達、または受け入れ条件が未定義）。
- 受け入れ条件の実体は `scripts/acceptance.sh`（プロジェクトが所有・編集します）。環境変数 `VERIFY_ACCEPTANCE` で差し替えられます（例: `VERIFY_ACCEPTANCE=scripts/acceptance-fast.sh bash scripts/verify.sh`）。
- `scripts/acceptance.sh` は `.github/workflows/ci.yml` の 8 ジョブと `.github/workflows/identity-guard.yml` を完全ミラーします。「ローカルが緑なら CI も緑」を保つための構成で、部分ミラーは採りません。
- identity 検査は `scripts/verify-commit-identity.sh` を引数なしで呼び、同スクリプトの既定範囲解決（`origin/main..HEAD`、解決できなければ HEAD の全履歴）に委ねます。CI の 2 系統（`pull_request` の base..head / `push`(main) の `--full`）とそのまま対応します。
- **`ci.yml` / `identity-guard.yml` を変更したら `scripts/acceptance.sh` も同じ内容へ追随させます。** 追随漏れを機械で検知する仕組みは無く、食い違うとローカルゲートは CI の予行演習でなくなります。

### 第二意見（クロスモデル）

```bash
bash scripts/second-opinion-review.sh                          # ステージ済み差分
bash scripts/second-opinion-review.sh --range main..HEAD       # 範囲指定
bash scripts/second-opinion-review.sh --runs 3                 # 実行回数
bash scripts/second-opinion-review.sh --engine antigravity     # エンジン切り替え
bash scripts/second-opinion-review.sh --engine codex           # エンジン切り替え（codex）
```

| オプション | 環境変数 | 既定 | 意味 |
|---|---|---|---|
| `--range <git-range>` | — | ステージ済み差分 | レビュー対象の差分範囲 |
| `--base <rev>` | — | — | 索引と `<rev>` の差（コミット済みとステージ済みの両方）をレビュー対象にする。`--range` と併用できない。`loop-gate.sh` は、ステージ済み差分があるとき既定ブランチとの分岐点を渡す |
| `--engine <name>` | `SECOND_OPINION_ENGINE` | `codex` | レビューを実行する CLI（`gemini` / `antigravity` / `codex`）。どちらでも指定せず `gemini` か `agy` が PATH にあるときは、既定の codex を使う旨を stderr に知らせる（判定は変えない）。どちらでも指定せず codex が使えない（CLI が無い・未ログイン）ときは、移行の案内を stderr に出して止まる（gemini へ自動で切り替えない） |
| `--model <name>` | `SECOND_OPINION_MODEL` | 各 CLI の既定 | 使用モデル |
| `--runs <n>` | `SECOND_OPINION_RUNS` | `1` | 実行回数（1 以上の整数。不正値は実行前に停止） |
| — | `SECOND_OPINION_AGENT_CONFIG_PATHS` | 未設定 | `loop-gate.sh` が渡す、レビュー範囲のうちエージェントの設定・フックに当たるパスの一覧（改行区切り）。空でなければ依頼文の末尾に、重点的に見るよう添える |

- **エンジンの指定が無いまま既定の codex で回るとき、`gemini` か `agy` が見つかれば、`[second-opinion] notice:` で始まる 2 行を stderr に出します。** 複数を入れた構成で `.env` を写し忘れた作業ツリーが、黙って既定の codex で回るのを防ぐためです。終了コードと判定は変わらず、codex だけの構成では出しません。文面に `(engine=` の形を含めないのは、`loop-gate.sh` が出力の最初の `(engine=` から記録のエンジン名を読むためです。
- 優先順位は CLI 引数 > `.env` > 既定です。`.env` は既に設定済みの環境変数も上書きするため、環境変数でエンジンを前置しても `.env` に負けます（`--engine` を使います）。
- 環境変数の旧名 `GEMINI_REVIEW_MODEL` / `GEMINI_REVIEW_RUNS` も後方互換で受理します。新名が設定されていればそちらが勝ちます。ただし `GEMINI_REVIEW_MODEL` は gemini 用のモデル名なので、エンジンが `gemini` のときだけ引き継ぎます（`codex` / `antigravity` へ渡すと、そのエンジンでは実行できないためです）。それらのエンジンでは、`SECOND_OPINION_MODEL` も `--model` も無ければ、各エンジンの既定のモデルになります。`GEMINI_REVIEW_RUNS` はエンジンに依らず受理します。
- 判定は多数決です。指摘を報告した run が**過半数**（`floor(N/2)+1`）に達したときだけ落とします。既定の `1` では閾値も 1 で、従来と同じ挙動になります。
- 過半数に届かなかった指摘も出力に残ります。誤検出とは限らないため、内容を確認して採否を判断します。
- 通過判定はエンジンによって方式が違います。`gemini` は構造化出力を強制する旗を持たないため、モデル出力の**最後の行**に置かれた判定トークン `VERDICT: LGTM` で判定します（`.ai-playbook/review-workflow.md`「第二意見の非決定性」）。前置き（作業ナレーション）が付いても判定は変わりません。判定トークンが無い出力は指摘あり扱いとし、その旨を出力へ明示します。`antigravity` / `codex` は構造化出力を強制できるため、判定トークンの解析はせず **JSON スキーマ**（`scripts/second-opinion-schema.json`）で判定します。モデルには通過・不通過そのものを出させず、指摘の種別（`category`）が `bug` / `vulnerability` / `type-error` / `edge-case` のいずれかで 1 件以上あれば落とします。JSON として読めない回答・スキーマの形を満たさない回答・差分を読めなかったと答えた回答（`reviewed: false` または欠落）も、指摘の中身によらず同じ扱い（失敗）にします。読めなかったものを LGTM として通さないためです。
- **どのエンジンにも、反証を試みる立場で依頼し、指摘ごとに失敗の筋書き（入力 → 誤った結果）を求めます**（`.ai-playbook/review-workflow.md`「② 第二意見」）。JSON スキーマの方式では筋書き（`failure_scenario`）を必須の項目にし、ゲート対象の 4 種類で筋書きが空の回答は失敗にします。そのときは「失敗の筋書き（failure_scenario）がありません」と示し、形の崩れ（「JSON として読めませんでした」）や、差分を読めなかった回答（`reviewed: false`。こちらの検査が先です）と区別します。筋書きを書けない懸念は、捨てさせずに `other` で報告させます（`promise-mismatch` / `other` の筋書きは空でかまいません）。`gemini` では、書けない懸念を判定に数えない参考として書かせるよう依頼文で求めるだけで、判定は変えません。**限界として、`--runs` が 2 以上でも、筋書きの無い回答が 1 回出た時点で、多数決を待たずに失敗します**（形の崩れた回答と同じ扱いです）。
- 終了コード 0 = `LGTM`（指摘を報告した run が閾値未満） / 1 = 重大な指摘あり、または実行不能。
- エンジンごとに認証手段が違います。`gemini` は `GEMINI_API_KEY` が必要です（`scripts/load-project-env.sh` が `.env` から読み込みます）。`antigravity`（`agy`）は **OAuth のみ**で API キーに対応せず、`.env` へ資格情報を書き写す経路を持ちません。ログイン状態は `~/.gemini` 配下（named volume `gemini-storage`）に残るため rebuild しても消えません。`codex`（Codex CLI）は ChatGPT アカウントの OAuth 認証（または API キー）です。初回はコンテナの中で対話で `codex login` を通してください（資格情報をコンテナの外から注入する経路は持ちません）。ログイン状態は `~/.codex` 配下（named volume `codex-storage`）に残るため rebuild しても消えません。いずれの CLI も `scripts/install-ai-tools.sh` が導入します。
- **`codex` は、渡す環境変数・作業場所・ツールを最小にして起動します。** `.env` を読み込む前の環境から、許可リストの変数だけを `env -i` で渡すので、`.env` に書いたプロキシと `OPENAI_API_KEY` は届きません。`~/.codex/config.toml` も効きません（`--ignore-user-config`）。認証は `codex login` で保存した資格情報を使います。どのエンジンにもツールは使わせず、差分はプロンプトに埋め込んで渡します。
- **`agy` のテレメトリはプロビジョニングで無効化します。** `scripts/install-ai-tools.sh` が `~/.gemini/antigravity-cli/settings.json` へ `"enableTelemetry": false` をマージするため、コンテナを作り直した直後からオプトアウト済みになります。環境変数によるオプトアウトは存在せず、この設定ファイルが唯一の手段です。**効くのは CLI だけです**（Antigravity IDE を使う場合は IDE 側に別途同等の設定があります）。既存コンテナへ後追いで適用する場合は `agy` を終了してから `bash scripts/install-ai-tools.sh` を実行してください（起動中の `agy` はセッション終了時に設定を書き戻すことがあります）。
- **`antigravity` で `--model` に `claude` 系を選ばないでください。** このプロジェクトの実装モデルは Claude で、同じベンダーのモデルで第二意見を取ると「別ベンダーで独立にクロスチェックする」という前提が壊れます（`.ai-playbook/review-workflow.md`）。`agy models` には `claude-*` も並びます。
- **`codex` は版の下限があります。** 第二意見の既定モデル `gpt-6-sol` は、ある版から CLI の一覧に出るようになったため、`scripts/install-ai-tools.sh` が導入時に版を見て、古ければ入れ替えます（`CODEX_MIN_VERSION`）。
- このレビューは非決定的です。1 回の `LGTM` は重大な指摘が無いことの証明ではなく、主レビューを省略してよい根拠にもなりません。

### リモート最終ゲート（置かない）

push / PR 作成後のリモート最終ゲートは、このリポジトリでは**置きません**（`.ai-playbook/review-workflow.md`「リモート最終ゲート（任意の層）」）。以前は要求側 `.github/workflows/copilot-review.yml` と確認側 `.github/workflows/review-gate.yml` の 2 本を採用していましたが、撤退しました。

- リモート最終ゲートの有無にかかわらず置く標準の機構層として、下記「第二意見（クロスモデル）」の記録と確認側（`.github/workflows/second-opinion-gate.yml`）、および CI（`ci.yml` / `identity-guard.yml`）の受け入れ検証の再実行を、標準の機構層とします。
- **失う性質**は、著者の操作なしに記録が作られること・記録を著者が消せないこと・内容が著者を通らないことの 3 つです（`.ai-playbook/review-workflow.md`「リモート最終ゲート（任意の層）」の表）。このリポジトリは外部からの PR を受け付けない方針（`CONTRIBUTING.md`）で、既定ブランチへ入るコミットの author は常に許可した identity に限られるため、この妥協を受け入れます。
- **push のたびに、記録を投稿します。** `scripts/loop-gate.sh` が第二意見の実行直後に記録（`save`）を自動で残しますが、PR へ投稿する `post` は push が終わり、PR を作ってからでないと打てません（記録は head SHA に紐づき、投稿先の PR が要るため）。

  ```bash
  bash scripts/second-opinion-record.sh post
  ```

  修正を push し直したら、そのたびに `post` も打ち直します。`.claude/skills/land/SKILL.md` の 2・7 がこれを手順に含めています。
- 指摘の打ち切りは `.ai-playbook/review-workflow.md` の収束規則に従います。2 巡目以降の軽微な指摘は人間が却下し、AI 同士を往復させません。

