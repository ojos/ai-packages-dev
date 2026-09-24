# リリース履歴（正本）

配布リポジトリの世代と公開バージョンの正本です。過去の詳細記録は [archive/](../archive/) に保存しています。

## 現行世代（正本）

2026-07-17 に配布リポジトリ 2 つを削除・同名再作成し、クリーンな履歴で v0.1.0 から配布をやり直しました。
**現行の正本はこの世代の v0.1.0 以降です。**

| パッケージ | リポジトリ | 現行バージョン | 配布形態 |
|---|---|---|---|
| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v0.12.0 | GitHub Release + 資産 5 点（配布スクリプト 2: `bootstrap.sh` / `doctor.sh`、生成物 3: `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz`） |
| ai-playbook | `ojos/ai-playbook` | v0.4.0 | git タグのみ |

### 新世代の版更新

| パッケージ | 版 | 公開日 | 要点 |
|---|---|---|---|
| devcontainer-bootstrap | v0.12.0 | 2026-09-24 | **移植性の静的検査と衛生検査を配布物へ入れた**（#330 / #332 / #343 / #346 / #327）。「この環境では通るが BSD 系（macOS）では落ちる」綴りと、読めない制御文字・表崩れを機械で落とす。**マージ確認フックを配り迂回経路を 3 件塞いだ**（#312 / #315 / #318 / #320）。`npm ci` 忘れの検出（#334）、生成物の由来記録と doctor の乖離診断（#321）、`land` スキルの配布（#311）、ローカル事前ゲートの identity 検査（#302）。**README の保証範囲を訂正した**（#339）。v0.11.0 までの README は「`SHA256SUMS` は改ざんを検出する」と誤って約束していた。**リリース資産へ artifact attestation を発行するようにした**（#340）。この版から効く。**この版は ai-playbook v0.4.0 以降を要求する**（雛形 3 本が必要）。破壊的変更は無く、既存フラグの挙動は変わらない |
| ai-playbook | v0.4.0 | 2026-09-24 | **レビュー運用の穴を 4 件塞いだ**（#301 / #303 / #306 / #308）。「Copilot が 1 行も読めていない PR」を緑で通す穴、大きい差分を拒否する制限、要求の間欠的な失敗、保証範囲の未明文化。**13 章へ「統合する側の実務」を足した**（#322。波及先の洗い出しを 3 方向で定義）。**`loop-workflow.md` へ「道具自体を見る検査の置き場所」を定めた**（#337）。**2 層目の雛形の空欄を既定値の提示へ書き直した**（#328。23 箇所のうち 11 を既定へ、12 は欄のまま残し既定の不在を宣言させる）。雛形 8 種 → **11 種**（`review-usable.sh` / `check-review-usable.sh` / `claude-skill-land.md`）。追加と明文化のみで後方互換 |
| devcontainer-bootstrap | v0.11.0 | 2026-08-13 | **委譲先エージェント定義を生成物へ配布するようにした**（#259）。`--with-claude` 指定時だけ `.claude/agents/explorer.md` と `implementer.md` を置く。雛形は規範パッケージが持ち、DCB は置き先だけを決める（intake 起点スキルと同じ経路）。目的は**モデルとツールを実行環境が読む機構で固定すること**で、指示文による呼びかけは迂回できるが frontmatter は迂回できない。読み取り専用ロールからは編集系ツールを外す（ただし調査に要るコマンド実行を残す以上、リダイレクト経由の書き込みは塞げない。境目は各定義に明記）。**この版は ai-playbook v0.3.0 以降を要求する**（雛形と、判定の導線を定めた 13 章が必要）。生成物のテストは**規範側に導線が実在すること**まで検査する（定義だけでは役割が選ばれないため）。衝突ポリシーは既定 `skip` で既存の生成先は上書きしない。機能追加のみで既存フラグの挙動は変わらない |
| ai-playbook | v0.3.0 | 2026-08-13 | **委譲判定を共有層へ置いた**（#259）。`shared-ai-rules.md` に 13 章「実装委譲パターン」を新設し、委譲の判定・「調査を委譲する条件」の 3 条件・「委譲の閾値」・「サブエージェントの戻り値」・「規範を読む範囲」・「並列実行時の作業分離」を定義。**これまで共有層に委譲の規範は 1 行も無く**、定義だけを配ると配布先で「判定から到達できない役割」を量産する状態だった。あわせて雛形 `claude-agent-explorer.md` / `claude-agent-implementer.md`（`model` / `tools` を frontmatter で固定）と `role-contracts/explorer.md` を追加。雛形は 6 種 → **8 種**。**目的はコスト削減ではない**: 当初のモデル配分による削減という前提は実測で否定され（利得の上限が数 %、親の文脈の約 9 割は散文と推論）、「迂回できない形で `model` / `tools` を固定すること」へ書き換えた。追加のみで後方互換だが、**13 章の挿入で「構成」が 14 章、「非目標」が 15 章へずれる**ため、章番号を数字で参照している利用側は追随が必要 |
| devcontainer-bootstrap | v0.10.1 | 2026-08-11 | **macOS で規範を配置する構成が使えなかった不具合を修正**（#285）。`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれでも `no rule files found in playbook source` で停止していた。取得も展開も成功しており、壊れていたのは最終の存在検査だけ。`set -o pipefail` 下の `find … | grep -q .` で、`grep -q` が最初のマッチでパイプを閉じ、まだ書き込み中の `find` が SIGPIPE で死んでパイプライン全体が非 0 になっていた（**grep は実際にはマッチしている**。`PIPESTATUS=141 0` を実測）。GNU find は EPIPE を握って 0 で終わるため **Linux では再現せず**、CI もローカル事前ゲートも緑のまま通っていた。`find … -print -quit` でパイプ自体を除去（`-quit` が BSD find でも使えることは macOS 実機で検証）。生成物には影響しない |
| ai-playbook | v0.2.1 | 2026-08-11 | **第二意見レビューの雛形が LGTM のときに限って偽の「指摘あり」を返す経路を塞いだ**（#285）。`grep -q` は**マッチしたときだけ**早期終了するため、指摘ありのときは正常に動き、通過すべき出力だけが反転していた。`-q` を外して `>/dev/null` へ回す（EOF まで読むので早期クローズが起きない）。**判定の意味論は変えていない**（#214 / #267 で二度直している箇所のため）。Linux では元から踏まないため実害なし。取り込み済みの利用側は雛形の再取得のみ必要 |
| devcontainer-bootstrap | v0.10.0 | 2026-08-10 | **Antigravity CLI（`agy`）を選べるようにした**（#271）。`--with-antigravity` を新設し、CLI の導入・永続化・テレメトリ無効化を配線する。ai-playbook v0.2.0 が配布した `second-opinion-review.sh --engine antigravity` は、生成器が `agy` を導入も永続化もしないため生成物では動かなかった。認証手段が違う（API キー / OAuth）ため `--with-gemini` には束ねず独立フラグにしている。**永続 volume は gemini と共有**し、どちらか一方でも指定すれば `/home/vscode/.gemini` の named volume が 1 つだけ作られる（両方指定でも重複しない）。volume 名も `gemini-storage` に寄せてあり、あとからフラグを足しても別 volume へ切り替わらない。テレメトリは環境変数によるオプトアウトが存在しない（`AGY_*` に該当なし・`DO_NOT_TRACK` 非対応。バイナリ実測）ため `settings.json` の `enableTelemetry` をマージで `false` にする（冪等・非破壊、jq 不在と壊れた JSON では非 0 で停止）。**無効化されるのは CLI のみで Antigravity IDE は別設定。** 機能追加のみで既存の生成物と既存フラグの挙動は変わらない |
| ai-playbook | v0.2.0 | 2026-08-10 | **破壊的変更**。第二意見レビューの雛形を `templates/gemini-review.sh` から **`templates/second-opinion-review.sh`** へ改名し、認証手段の異なる 2 つの CLI から選べるようにした（#268）。`--engine gemini\|antigravity`（既定は `gemini` 据え置き）。`antigravity`（`agy`）は Google アカウントの OAuth 認証で API キーに対応せず、API キーのクォータ切れや失効がそのままゲート停止になる状態を解消する。**旧名の shim は残していない**ため、取り込み済みの利用側は雛形の再取得・呼び出し側の差し替え・`.env` のキー名移行（`GEMINI_REVIEW_*` → `SECOND_OPINION_*`。旧名も実装は受理するが、機密検査が `.env.example` との不整合を `SECRETS_FAIL` として出す）が必要。**あわせて第二意見の通過判定を「出力の最後の行に置かれた判定トークン」へ変更した**（#267。挙動変更）。モデルが回答の前に作業ナレーションを 1 行出すだけで、指摘が 1 件も無くても「指摘あり」に分類され偽の赤が出ていた。**`--runs` を増やしても回避できない**（実測で 3 run すべてが同じ形で落ちた）。判定を緩めて「LGTM を含む」にすると v0.1.7 で塞いだ穴が開くため、`VERDICT:` 付きの専用トークンにして前置きだけを許す。判定ロジックはエンジン間で複製せず、違うのは CLI 名・認証・差分の渡し方の 3 点に閉じた。受け入れ条件の二層化（#244）、`review-gate.yml` の誤判定修正（#235）、`closer.md` へのマージ確認機構の追記（#241）を含む。雛形は 6 種のまま |
| ai-playbook | v0.1.8 | 2026-08-03 | **リモート最終ゲートが要求されないまま PR が通る穴を塞いだ**（#222）。`pull_request` の `opened` は GitHub 側の配信取りこぼしで届かないことがあり（実運用で連続する 2 日間に開いた 6 本のうち 2 本）、届かなければ自動要求のワークフローは起動せず、エラーも出ず、他のチェックは緑になるため、**最終ゲートだけが黙って抜ける**。`opened` を見る 2 本目では塞げない（届いていないのはイベント自体）ため、確認専用の雛形 `templates/review-gate.yml` を新設し、要求側と同じ契機に加えて PR 更新と**定期実行**を張り、判定を head コミットの status として出す。確認側は要求しない（「1 回だけ要求する」が 2 か所から壊れるため）。あわせて `templates/copilot-review.yml` へ要求失敗時の診断を追加した。**指摘が事実誤認だった場合の却下条件と記録要件も定めた**（#226）。従来の「解決済みとして扱ってよい」条件は CI 通過 / スコープ外 / 命名・可読性の好みの 3 つで、事実誤認を却下する根拠が無く、実際に本作業で 2 回踏んだ。条件だけを足すと主張だけの却下が抜け道になるため、再現手順と実測結果（および対照）を残すことを同時に要求する。雛形は 5 種 → **6 種**。規範の追加のみで後方互換だが、要求側だけを取り込んでいる利用側は `review-gate.yml` の追加取り込みが必要 |
| devcontainer-bootstrap | v0.9.1 | 2026-08-10 | **この版は ai-playbook v0.2.0 以降を要求する**（第二意見レビューの雛形が改名されたため。古い規範パッケージを指すと生成時に停止する）。利用プロジェクト 2 件の実装を配布物へ還流した（#234）。**機密混入検査を配布スクリプト `scripts/check-no-secrets.sh` として切り出し**、生成される `verify.sh` から直接呼ぶ（#239。`acceptance.sh` 雛形へ入れないのは、あちらがプロジェクトの所有物で書き換えのたびに検査が消える経路ができるため）。その検査が**パス名に改行を含むファイルを両経路で取りこぼしていた穴も塞いだ**（#263。列挙を NUL 区切りへ。`--untracked-files=all` で畳まれた未追跡ディレクトリ、`--no-renames` で改名の 2 パス形にも対処）。**マージ実行に確認を挟む PreToolUse フックを `--with-claude` 連動で配布**（#241）。`verify.sh` を CI で回すワークフロー雛形（#238）、`.env` の `GH_TOKEN` による gh 認証の PAT 固定経路（#237）、`review-gate.yml` の誤判定修正（#235）、生成物が素で shellcheck を通ること + 回帰テストと shellcheck の常時装備（#236）、`.gitignore` 管理セクションへの Claude 生成物と Terraform の追加（#240）、`loop-gate.sh` のレビュー範囲汚染の修正（#242）、`setup-git-identity.sh` の system スコープ credential.helper 可視化（#243）、雛形の `--with-copilot` 参照の現行化とフラグ名の機械照合（#245）。再生成しない限り既存の生成物は無影響だが、再生成時は旧名 `scripts/gemini-review.sh` を手で削除する必要がある |
| devcontainer-bootstrap | v0.9.0 | 2026-08-03 | **破壊的変更**。`--with-copilot` からリモートのレビュー機構を分離し、`--with-copilot-review` を新設した（#230）。`--with-copilot` は手元の開発ツール（CLI・拡張・永続 volume）だけを配線する。効く場所も前提条件も違うものを 1 つのフラグで束ねていたため、「リモートのレビューゲートだけ欲しい」構成を機構で表現できなかった。**`--with-copilot` だけで再生成するとワークフローが配置されなくなる**（移行は `--with-copilot-review` を足すだけ。再生成しない限り既存の生成物は無影響）。`--with-copilot-review` を規範の配置なしで指定した場合は、v0.4.2 の前例に揃えて**ファイルを 1 つも書かずに**エラー終了する。あわせてリモート最終ゲートを 2 本立て（要求側 + 確認側）にし（#222）、**この版は ai-playbook v0.1.8 以降を要求する**。生成される `verify-commit-identity.sh` が GitHub 由来のコミット（committer が `noreply@github.com` かつ author が `<login>@users.noreply.github.com`）を扱えるようになり、許可エントリへドメイン一括指定（`@example.com` / `*@example.com` の 2 形のみ）を追加した（#223。**許可範囲が広がる挙動変更**）。生成される `load-project-env.sh` が git worktree からメイン作業コピーの `.env` へ回り込むようになった（#227）。あわせて正本（`bootstrap.sh` 内ヒアドキュメント）と写し（開発リポジトリの `scripts/`）の同期検査を新設し、積み上がっていた追随漏れ 2 件を解消した（検査は開発リポジトリ側の機構で配布物には含まれない） |
| ai-playbook | v0.1.7 | 2026-07-31 | **第二意見レビューのゲートが両方向に壊れていたのを修正した**（#214 / #215。別プロジェクトの取り込み差分から報告）。`templates/gemini-review.sh` の通過判定が「出力全体が `LGTM` 一意」ではなく「`LGTM` 行を含む」で判定しており、ファイル別講評や末尾の `**LGTM**` に紛れた**致命バグの指摘をそのまま通していた**（#214）。あわせて判定対象をモデルの回答（stdout）だけに限定し、CLI の警告を混ぜないようにした。差分は stdin ではなく一時ファイルへ書いて `@<パス>` で参照させる形へ変更した（#215）。従来は差分本文中の `@` を CLI がファイル参照として展開し、モデルが壊れたテキストを読んで**実在しない誤りを致命バグとして報告**していた（3 run とも同じ幻を報告するため多数決でも落ちない）。**挙動変更を含む**（これまで通過していた出力の一部が指摘ありになる）ため、取り込み済みの利用側は雛形の再取得が必要 |
| devcontainer-bootstrap | v0.8.1 | 2026-07-31 | **macOS ホストで `bootstrap.sh` が落ちる経路を塞いだ**（#218）。BSD 系の `mktemp` はテンプレート引数を必須とし、素の `mktemp` / `mktemp -d` は GNU coreutils でしか動かない。同じファイルの中で `stat` の GNU / BSD 差分は分岐していたのに `mktemp` は素のままで、macOS 利用者は導入の最初の 1 回で踏む状態だった。開発リポジトリ全体で 6 ファイル 19 箇所を `${TMPDIR:-/tmp}/<用途>.XXXXXX` へ統一し、テンプレート無しの呼び出しを検出する検査を CI へ追加した（検査は開発リポジトリ側の機構で配布物には含まれない）。生成物の挙動は不変。後方互換 |
| devcontainer-bootstrap | v0.8.0 | 2026-07-30 | `--languages` に **`ruby` を第 6 の選択肢として追加**した（#206）。既存 5 言語と同等の生成・検査・診断・文書体験を提供する。`ghcr.io/devcontainers/features/ruby:1` を feature として配線し、`.gitignore` へ `Ruby` テンプレートを取り込み、`doctor.sh` と生成物 `post-rebuild-check.sh` の検査対象に含め、選択時のみ `Shopify.ruby-lsp` を配線する。`ruby` は feature 名と実行ファイル名が一致するため `rust`→`cargo` のような写像分岐は持たない。acceptance は Minitest / RSpec を決め打ちせず `bundle exec rake` で `Rakefile` の default タスクへ委譲する（マニフェストは `Gemfile`、ツール可用性は `bundle` で判定）。あわせて対応言語の README 追随漏れを機械で落とす**両方向の集合照合**を追加した（個別言語の取りこぼし検査は書いた言語しか守れないため）。後方互換 |
| ai-playbook | v0.1.6 | 2026-07-29 | 並列実装後の統合検証を規範へ追加した（#199）。レーン単体の受け入れ検証が緑でマージの衝突検査も無言のまま統合欠陥が残る構造（8 レーン並列で 3 件、3 レーン並列で 5 件の実測）に対し、統合ツリーで各レーンの受け入れ条件を再実行する工程を `review-workflow.md` へ明記。あわせて `shared-ai-rules.md` 12 章へ「文書が実装の一覧を書き写している箇所は実装の出力と機械照合できる形にする」判断軸を追加した。規範の追加のみで後方互換 |
| devcontainer-bootstrap | v0.7.4 | 2026-07-29 | 生成される `loop-gate.sh` で、**push 済みブランチ（HEAD == 上流）だと第二意見が一度も差分を見ないまま `GATE_PASS` になる**経路を塞いだ（#198）。v0.7.2 が塞いだ穴と同じ構造の残穴で、切り替え先の範囲が空になる場合を見ていなかった。範囲は「解決できたか」ではなく実際に差分があるかで選び、上流との差分が空なら既定ブランチの追跡枝との**分岐点**まで戻してブランチ全体を対象にする。分岐点まで戻しても差分が無い場合は `no reviewable diff` を明示したうえで通過する（空を一律 FAIL にすると差分の無い状態でのゲート実行が落ちる）。空ツリーへの後退は remote が無い場合に限定。後方互換 |
| devcontainer-bootstrap | v0.7.3 | 2026-07-28 | README と実装の乖離を解消（#170 / #171）。未記載だった `--dry-run` / `--force` / `-h`、実行前提コマンド、rust 対応を追加し、生成物一覧・doctor 節・リリース資産の説明を実装と一致させた。`bootstrap.sh` / `doctor.sh` の usage が開発リポジトリと公開配布物のどちらか一方でしか解決しないパスを示していた問題を修正（#174 / #182）。`LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加（#177）。**生成物への影響は `.ai-playbook/CHANGELOG.md` を取り込まなくなる 1 点のみ。** 後方互換 |
| ai-playbook | v0.1.5 | 2026-07-28 | **導入手順が新規プロジェクトで必ず失敗する不具合を修正**（#167。手順 2・4 の `cp` に `mkdir -p` が無かった）。配布先で解決しない参照を除去（#167）、構成表・命名規則・管理対象の自己不整合を解消（#168）、契約・雛形の内部不整合とベンダー中立違反を解消（#169）、`LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加（#177）。命名規則は分類定義のみ改め、**ファイル改名は行っていない**ため既存の取り込みは壊れない。後方互換 |
| devcontainer-bootstrap | v0.7.2 | 2026-07-27 | 生成される `loop-gate.sh` で、ステージ済み差分が空のときに第二意見が実質スキップされる経路を塞いだ（#152）。空のときだけ commit 済み範囲へ切り替える。既定ブランチ名は決め打ちせず、起点が無ければ空ツリーを使う（`HEAD` だと `git diff` が作業ツリー比較になり素通りが復活する）。git リポジトリでない場合は従来どおり引数なしで呼ぶ。**v0.7.1（#149）の内容を含む。** 後方互換 |
| devcontainer-bootstrap | v0.7.1（未公開） | — | **タグ未公開。v0.7.2 へ統合。** 生成される `verify-commit-identity.sh` で、許可 author email の解決からパス名展開（glob）を除去（#149）。クォートなしの配列代入により、許可 email に `*` / `?` が含まれると許可リストが検査対象リポジトリのファイル名で変わっていた。`read -r -a` へ改め、回帰テストで「ファイルの有無で判定が変わらないこと」を検証する。後方互換 |
| devcontainer-bootstrap | v0.7.0 | 2026-07-27 | **破壊的変更**。生成物からホスト資格情報の注入経路（`remoteEnv` の `${localEnv:...}`）を全廃し、認証をコンテナ内で行い named volume で永続化する構造へ移行（#129）。`--github-profiles` / `--gemini-key-env` と `GITHUB_TOKEN_*` 等の環境変数契約を撤去（#130）、永続 volume を gh/aws/gcloud へ拡張し実マウントを検査（#131）、所有権修復を `fix-mount-owner.sh` へ独立（#132）、credsStore 打ち消し・identity の `.env` 化・`credential.helper` の gh 固定・`.env.example` 追加（#133 / #141） |
| devcontainer-bootstrap | v0.6.0 | 2026-07-26 | 生成物に git identity ガード（適用・検証・CI の 3 層。#108）、プロジェクト `.env` 優先読み込み（#109）、`--with-claude` での Claude intake 起点スキル配置（#111）、`--with-copilot` でのリモート最終ゲート雛形配置（#113）、tmux 常時同梱（#115）を追加。あわせて `acceptance.sh` の生成既定を「存在する対象だけ検証し 0 件なら失敗」へ変更（**軽微な破壊的変更**。#112） |
| ai-playbook | v0.1.4 | 2026-07-27 | `templates/gemini-review.sh` に複数回実行と多数決を追加（#157）。第二意見は非決定的で、同一コミットへの 4 回の実行が LGTM 2 回・指摘あり 2 回に分かれた。`GEMINI_REVIEW_RUNS` で回数を増やし、指摘を報告した実行が過半数に達したときだけ落とす。既定 1 で従来と同一挙動。`review-workflow.md` へ「第二意見の非決定性」節を追加 |
| ai-playbook | v0.1.3 | 2026-07-26 | `REASON_CODES.md` に軽微修正の免除条件を追加（#110）、`review-workflow.md` のリモート最終ゲートを「1 回に限定される機構なら自動要求可」へ緩和し `templates/copilot-review.yml` を新設（#113）、Claude Code 向け intake 起点スキル雛形 `templates/claude-skill-intake.md` を追加し 8 章へ固定ファイル名の例外を追記（#111）、`templates/project-ai-rules.md` のレビュー節に loop-gate 単一入口とリモート最終ゲート欄を追加（#114）、`templates/gemini-review.sh` を `.env` ローダーへ追随（#109） |
| devcontainer-bootstrap | v0.5.1 | 2026-07-22 | 取り込んだ ai-playbook の出所を生成先 `.ai-playbook/VERSION` に記録（後方互換）。書き込みは規範と同じ衝突ポリシーに従う（自己診断 F-7） |
| ai-playbook | v0.1.2 | 2026-07-22 | 入口雛形 `templates/entry.md` から「導入時の調整」節を削除（生成物へのメタ指示残置を解消。自己診断 F-6） |
| devcontainer-bootstrap | v0.5.0 | 2026-07-22 | **破壊的変更**。Claude 認証を OAuth トークン注入から作業前 `/login` 既定へ変更（`--claude-token-env` / `CLAUDE_CODE_OAUTH_TOKEN` 自動注入を廃止）。あわせて AI ツール永続 volume の `root:root` 所有によるログイン不能を修正（`fix_owner` を postCreate に追加） |
| devcontainer-bootstrap | v0.4.2 | 2026-07-21 | バグ修正: playbook 取得失敗時に部分生成せず書き込み前にアトミック停止。`--playbook-version` の `v` 抜けヒント |
| devcontainer-bootstrap | v0.4.1 | 2026-07-21 | `--playbook-version <tag>` 追加（URL 冗長の解消）。ソース指定時は `--with-playbook` 省略可 |
| devcontainer-bootstrap | v0.4.0 | 2026-07-21 | **破壊的変更**。`--mode` を廃止し装備を `--with-*`（cloud/AI ツール）へ分解。docker 標準化・AI 永続化の mode 非依存化・自動導入廃止 |
| devcontainer-bootstrap | v0.3.1 | 2026-07-21 | ループコーディング支援（`verify.sh` / `acceptance.sh` / `loop-gate.sh`）を生成に追加。`--with-playbook` 取得元を ai-playbook v0.1.1 へ更新 |
| ai-playbook | v0.1.1 | 2026-07-21 | ループコーディング規範 `loop-workflow.md` / `loop-coding-guide.md` を追加、既存規範を追随更新 |

> 注: 新世代 DCB は v0.1.0 で初回公開後、v0.2.0 / v0.3.0 / v0.3.1 / v0.4.0 / v0.4.1 / v0.4.2 / v0.5.0 / v0.5.1 を経て v0.6.0 に至る（README のバージョン固定が正本）。v0.4.0 は `--mode` 廃止、v0.5.0 は Claude 認証 login-first 化の破壊的変更。v0.5.1 は非破壊の機能追加（playbook 出所記録）。v0.6.0 は機能追加（identity ガード / `.env` 優先読み込み / Claude skill / Copilot 雛形 / tmux）に加え `acceptance.sh` 生成既定の軽微な破壊的変更を含む。

- 再作成の理由: コミット作者情報に別アカウントが混入した痕跡を、GitHub 内部キャッシュも含め完全に除去するため。
- 新世代 v0.1.0 の機能は、旧世代の最終版（DCB v0.3.1 / 旧 ai-playbook v0.1.0）の内容をすべて含みます。
- **旧世代のタグ・Release・固定 URL・コミット SHA はすべて無効です。** 利用側は取得手順の `TAG` と固定 SHA を新世代へ更新してください。

## 旧世代の記録（メモ）

旧世代（リポジトリ作成 2026-04-09 〜 削除 2026-07-17）の公開バージョンの要約です。

### devcontainer-bootstrap（旧 v0.1.15 〜 v0.3.1）

| 版 | 公開日 | 要点 |
|---|---|---|
| v0.1.15 | 2026-04 | 初期安定ライン |
| v0.2.1 | 2026-07-14 | `.env` 自動読み込み、GitHub アカウント自動選択のフォールバック |
| v0.3.0 | 2026-07-16 | 規範パッケージ改名（dotfiles → ai-playbook）へ追随。`--with-playbook` / `.ai-playbook/` 配置 |
| v0.3.1 | 2026-07-16 | ai-playbook 配布 tarball の構造検出を修正（v0.3.0 のリグレッション） |

### ai-playbook（旧 v0.1.0）

| 版 | 公開日 | 要点 |
|---|---|---|
| v0.1.0 | 2026-07-16 | 初回公開。規範 18 件、タグのみ配布（Release・資産なし） |

### 旧世代で決着した設計原則（現行にも適用）

- 公開リポジトリ = 成果物置き場。CI / テスト / ビルドロジックを置かない（v0.2.1 の検証チェーン破壊の教訓）
- `SHA256SUMS` は利用者が実際にダウンロードするファイルのみを対象にする（`SUMS_TARGETS`）
- 公開済みバージョンは不変。やり直しは版を上げる
- リリースの恒久的操作は `scripts/release-packages.sh` を唯一の経路とする

詳細: [archive/RELEASE_PROCESS_RECORD.md](../archive/RELEASE_PROCESS_RECORD.md) /
[archive/release-notes-devcontainer-bootstrap.md](../archive/release-notes-devcontainer-bootstrap.md) /
[archive/RENAME_TO_AI_PLAYBOOK_PLAN.md](../archive/RENAME_TO_AI_PLAYBOOK_PLAN.md)
