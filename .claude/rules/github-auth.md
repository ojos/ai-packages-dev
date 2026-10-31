---
paths:
  - ".env.example"
  - "scripts/on-attach.sh"
  - "scripts/load-project-env.sh"
  - "scripts/setup-git-identity.sh"
  - "infra/github/providers.tf"
---

地図（`.github/project-ai-rules.md`）の「Git identity と GitHub 認証」の詳細です。`GITHUB_TOKEN` を置かないこと、`GH_TOKEN` 設定中に `gh auth login` を実行しないことは地図が常時持ちます。

## GitHub 認証（gh CLI）

gh CLI の認証はコンテナ内で行い、その状態を named volume に残します。ホスト OS からトークンを持ち込みません。**ただし PAT を `.env` の `GH_TOKEN` へ置く経路だけは、下記の理由で認めます。**

順守事項:

- 認証は次のどちらかです。両方を満たす必要はありません。
  - **PAT モード（推奨）**: `.env` の `GH_TOKEN` に PAT を置きます。gh はこの環境変数を最優先で読みます。
  - **保存済み認証モード**: `GH_TOKEN` を空にし（かつ `GITHUB_TOKEN` も設定せず）、`gh auth login` をコンテナ内で 1 度実行します。状態は `gh-storage` volume（`/home/vscode/.config/gh`）に残り、リビルドを跨いで有効です。
- **`GH_TOKEN` だけは `.env` へ書き写します。** gh の OAuth App には「ユーザー × アプリ × scope あたり 10 トークン」の上限があり、上限に達した状態でどこかの環境が認証すると GitHub が既存のトークンを 1 本破棄します（理由コード `max_for_app`）。溜まる単位は環境ではなく認証の回数で、`gh auth login` も `gh auth refresh` も自分の古い枠を返しません。失効に気づいた環境が再認証し、それがまた別の環境を失効させる連鎖になるため、運用ルールでは回避できません。PAT は OAuth App の認可ではないため、この枠の外にあります。
- 名前は gh 自身が読む `GH_TOKEN` をそのまま使います。`GIT_IDENTITY_*` を別名にしているのと方針が逆に見えますが、理由が違います。git は自身が読む名前を環境へ置くと `user.useConfigOnly` の保護が無効になるため別名にします。gh には、環境変数を置くことで無効化される保護がありません。
- **PAT の種別は fine-grained を使います。** `.env` へ置くトークンには有効期限が要るためです（classic は無期限を選べてしまいます）。期限切れ時は再発行して `.env` を差し替えます。値をコミット・issue・PR 説明・ログへ混入させません。
- 必要な権限は、このリポジトリで現に行う操作から起こした次の対応とします。**Actions の行（手動実行）だけは実測済みで（下記）、ほかの行は実際に PAT を発行して確かめたものではありません。** 発行時に不足・過剰を確認し、この表を実測で置き換えてください。

  | 行う操作 | fine-grained PAT の repository permission |
  |---|---|
  | clone / push | Contents: Read and write |
  | PR の作成・コメント | Pull requests: Read and write |
  | issue の起票・コメント | Issues: Read and write |
  | `.github/workflows/` を含む push | Workflows: Read and write |
  | `gh run list` 等の CI 状態確認、`second-opinion-gate` の手動実行（`gh workflow run`。`second-opinion-record.sh post` と `/land` の再判定） | Actions: Read and write |
  | `second-opinion-gate` の commit status 確認 | Commit statuses: Read |
  | （必須・自動付与） | Metadata: Read |

  **Checks は fine-grained PAT では選べません。** 非公開リポジトリでは `commits/<sha>/check-runs` と `gh pr checks` が 403 になるため、CI の確認は上の Actions と Commit statuses で行います（`/land` の雛形もそうしています）。例の表は `packages/devcontainer-bootstrap/README.md`「資格情報の扱い」にもあります。

  **手動実行の権限（Actions: Read and write）は、2026-10-12 に実測で確かめました**（ojos/ai-packages-dev#545）。この表の権限だけを持つ fine-grained PAT で、Actions を Read and write にすると `gh workflow run` が通り、Read-only に下げると `HTTP 403: Resource not accessible by personal access token` で拒否されました（実行の一覧などの読み取りは、どちらでも通ります）。GitHub の公式ドキュメント（「Permissions required for fine-grained personal access tokens」の Actions の節。`POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches` は write）とも一致します。権限が足りないと `second-opinion-record.sh post` は、記録の投稿後に手動実行できなかったとして非 0 で終わり、手で起こすコマンドを示します。

- **`GH_TOKEN` を設定しているあいだ `gh auth login` を実行しません。** gh 2.96.0 で実測したところ、値が設定されているあいだ gh はログインを拒否します（`--with-token` / `--web` のいずれでも `The value of the GH_TOKEN environment variable is being used for authentication.` で終了し、通信もしません）。危ないのはその先で、拒否メッセージ（`first clear the value from the environment`）に従って値を空にしてログインすると上限枠を 1 つ消費し、上限に達していれば他環境のトークンが 1 本失効します。この拒否は制約ではなく安全装置として扱います。
- **`GITHUB_TOKEN` を恒久的に設定しません。** gh は `GH_TOKEN` → `GITHUB_TOKEN` の順に環境変数を読み、**空文字だけを読み飛ばします**。したがって `GH_TOKEN` を空にすることは `GITHUB_TOKEN` に対する盾になりません。gh 2.96.0 での実測: `GITHUB_TOKEN=" " gh api user` は `Bad credentials`、`GITHUB_TOKEN=" " GH_TOKEN="" gh api user` も `Bad credentials`（一方 `GITHUB_TOKEN="" gh api user` と `GH_TOKEN= gh api user` はどちらも保存済み認証で成功）。**手元のシェル・rc・`.env` のいずれにも `GITHUB_TOKEN` を置きません。**
- ワークフローの `env: GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` はこの話と別です。Actions のランナーに `.env` は無く、ジョブ限りのトークンなので上限枠も消費しません。**手元のシェルで `GITHUB_TOKEN` を設定してよい根拠にはなりません**（上記）。
- git の push 認証は `scripts/setup-git-identity.sh` が global の `credential.helper` を「空 → `!gh auth git-credential`」に固定して gh へ向けます。空文字がヘルパー一覧をリセットするため、`/etc/gitconfig` 側やエディタが注入したヘルパーは応答しません。
- `gh auth status --active` が失敗した場合、それが「資格情報が無効」なのか「GitHub へ到達できていない」のかは gh の出力から区別できません（到達できないときも `The token in GH_TOKEN is invalid.` と言います）。`scripts/on-attach.sh` はどちらとも断定せず、環境変数のトークン（`GH_TOKEN` / `GITHUB_TOKEN` のいずれかが非空）が効いているあいだは `gh auth login` を案内しません。PAT モードなら `.env` の `GH_TOKEN` と疎通を、保存済み認証モードならコンテナ内での `gh auth login` を確認します。
- Docker レジストリの資格情報も同様です。ホスト側 VS Code で `dev.containers.dockerCredentialHelper: false` を設定してください。`scripts/on-attach.sh` が接続ごとに `~/.docker/config.json` の `credsStore` と `credHelpers` の両方を除去します（前者はレジストリ横断、後者はレジストリ個別にホストのヘルパーを指すため、片方だけでは塞がりません）。ただし書き込み順序によっては間に合わないため、ホスト側の設定が本体で、この除去は多層防御の 1 枚です。

