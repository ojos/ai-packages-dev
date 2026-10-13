# devhost — SSH で届く外部の機械に置く入口の道具

SSH で届く外部の機械（Linux + systemd が前提）に置き、**端末から 1 コマンドで
devcontainer を起こし、入る**ための道具一式です。どのプロジェクトにも依存しません。
名前・パス・ホスト名は外部の機械の設定ファイルに置き、ここには書きません（`scripts/check-neutrality.sh` で検査しています）。

| ファイル | 置き場所（外部の機械 / 端末） | 役割 |
|---|---|---|
| `dev.sh` | `~/.local/bin/dev`（外部の機械） | 入口の道具。`ls` / `up` / `attach` / `supervise` / `rebuild` / `doctor` / `runner` / `restart` / `stop` / `logs` / `enable` / `disable` / `exec` / `self-update` / `version` / `help` |
| `dev-up@.service` | `~/.config/systemd/user/`（外部の機械） | 起動時と、コンテナが止まったときに起こし直すユニット |
| `projects.example` | `~/.config/dev/projects`（外部の機械） | 設定ファイルの雛形（名前 → パス） |
| `dev-runner@.service` | `~/.config/systemd/user/`（外部の機械） | 自前のランナーを使い捨てのコンテナで常駐させるユニット（「自前のランナー」） |
| `runner.Dockerfile` | `~/.config/dev/runner.Dockerfile`（外部の機械） | ランナーのイメージ（公式のイメージに道具を足す）。`dev runner build` が作る |
| `runners.example` | `~/.config/dev/runners`（外部の機械） | ランナーの設定ファイルの雛形（名前 → 組織・ラベル・Docker を渡すか） |
| `ssh_config.plain.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: 素の SSH） |
| `ssh_config.cloudflared.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: Cloudflare Access） |
| `ssh_config.tailscale.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: Tailscale） |
| `termux/shortcut.example` | スマホの `~/.shortcuts/` | Termux:Widget のボタン 1 つ分 |
| `install.sh` | （置かない。導入・更新のときに実行する） | 取得・照合して dev・ユニット・ランナーのファイルを置くインストーラー（「外部の機械への導入」） |
| `selftest.sh` | （置かない） | 偽の道具で回す自己試験 |

## 3 パッケージの関係

<!-- package-relations:begin -->
ai-playbook・devcontainer-bootstrap（DCB）・devcontainer-host（devhost）は、それぞれ単体で使えます。DCB を中心に組み合わせると、効果が最大になります。

| パッケージ | 単体での用途 | 配布先 |
|---|---|---|
| ai-playbook | AI 運用の規範（ルール）だけを、プロジェクトへ入れる | ojos/ai-playbook |
| DCB | プロジェクトの devcontainer を 1 コマンドで生成する | ojos/devcontainer-bootstrap |
| devhost | 任意の `devcontainer.json` を持つプロジェクトを、SSH で届く外部の機械で常駐させる | ojos/devcontainer-host |

**DCB が中心です。** DCB は、ほかの 2 つが着地する場所（プロジェクトの devcontainer）を作ります。ai-playbook の規範はその中に置かれ（DCB が配布機構で、正本は ai-playbook です）、devhost はそのコンテナを外部の機械で動かし続けます。

- **DCB と ai-playbook**: DCB が、生成先のプロジェクトへ規範を配置します（`--playbook-version` などで取得元を指定する。新しい版へ移るときは、`--upgrade` に新しい `--playbook-version` を渡す）。DCB は規範の内容を持ちません。
- **DCB と devhost**: DCB の生成物には、devhost が前提にする、または助かるもの（tmux、compose の `init: true`、codex のサンドボックスの設定（`--with-codex` のとき）、UID の合わせ込み）が入っています。devhost は DCB の生成物でなくても使えますが、DCB の生成物ならこれらが最初から揃います。理由と意味は devhost の README の「DCB と一緒に使うと揃うもの」にあります。
- **ai-playbook と devhost**: 今は直接の関係がありません。

**入れ方は 2 段です。** 置く場所と単位が違うため、DCB のオプションでは devhost は入りません（DCB が書き込むのは生成先のプロジェクトの中だけで、外部の機械のホームやユーザーの systemd には書き込みません）。

1. プロジェクトごとに、プロジェクトの中へ DCB で devcontainer（と、必要なら規範）を生成する。
2. 外部の機械ごとに、外部の機械のホームへ devhost を入れ、設定ファイル（`projects`）にそのプロジェクトを 1 行足す。
<!-- package-relations:end -->

## 外部の機械の前提

**Linux + systemd を前提とします。** `dev-up@.service` はユーザーの systemd ユニットなので、
systemd を持たない OS（macOS や、systemd を使わない Linux ディストリビューション）には
導入できません。端末側（ssh で繋ぐ側）は macOS / Linux / Termux のいずれでも、同じ書式の
`ssh_config` で使えます。

**コンテナの中に tmux が要ります。** `dev attach`（コンテナの中の tmux に入る）と、`dev ls` の TMUX の列（tmux のセッションの有無）が、コンテナの中の tmux を使うためです。tmux が無いコンテナでは、`dev attach` が入れず、`dev ls` の TMUX は常に none になります。DCB で作った devcontainer には、tmux が常に入っています（下の「DCB と一緒に使うと揃うもの」）。DCB を使わない devcontainer では、各自で tmux を入れてください。

**ネイティブ Linux の Docker Engine でワークスペースへ書き込めない場合**は、
devcontainer-bootstrap（DCB）の README の「ネイティブ Linux の Docker でのワークスペースの所有者」に
従ってください。`updateRemoteUserUID` が既定で UID/GID を揃えるため、devhost 側で追加の対処はしません
（devhost は DCB とは別のリポジトリで配布されるため、DCB の README へは相対リンクにしません）。

**ネイティブ Linux の Docker Engine で codex のサンドボックスを使うには、コンテナの AppArmor と
seccomp の既定の制限を両方外す必要があります**（seccomp は Docker Desktop でも止めます）。DCB の `--with-codex` の生成物は、`compose.yaml` に
`security_opt: [apparmor=unconfined, seccomp=unconfined]` を入れてあるので、そのままで動きます。
`--with-codex` を使わずに codex を後から入れた場合や、それより前の DCB で生成した場合は、
DCB の README の「コンテナの中での codex のサンドボックス」に従って足してください。
AppArmor だけを外しても、seccomp が先に止めるので動きません（Ubuntu 26.04 の実機で実測）。

## DCB と一緒に使うと揃うもの

devhost は、`devcontainer.json` を持つプロジェクトなら DCB の生成物でなくても使えます。DCB（devcontainer-bootstrap）で作った devcontainer なら、次のものが最初から入っていて（codex のサンドボックスの設定は `--with-codex` を指定したとき）、devhost の前提を満たしたり、devhost が見る不具合を防いだりします。DCB の生成物は、DCB の README と、DCB の `bootstrap.sh` が出す雛形で確かめられます（DCB は別のリポジトリで配布されるため、相対リンクにはしません）。

| DCB の生成物 | DCB が入れる理由 | devhost にとっての意味 |
|---|---|---|
| tmux（`devcontainer.json` の feature として常に入る。`--with-*` では増減しない） | DCB の標準装備（common-utils・ripgrep・shellcheck・tmux・github-cli）の 1 つ | `dev attach` と `dev ls` の TMUX の列が使う。単体で使うときは、各自で入れる必要がある（「外部の機械の前提」） |
| compose の `init: true`（`compose.yaml` の `app`） | PID 1 の `sleep infinity` は孤児になったプロセスを回収しない。これが無いと、ゾンビが溜まり、数日でプロセス数の上限に達して `docker exec` もコンテナ内のセッションも止まる | ゾンビの蓄積を防ぐ。`dev doctor` が見る pids の上限（pids.current / pids.max）とゾンビの数に効く。既存の生成先は、DCB の `--upgrade` で取り込んだあと、`dev rebuild` でコンテナを作り直すと効く |
| codex のサンドボックスの設定（`--with-codex` のとき、`compose.yaml` の `security_opt: [apparmor=unconfined, seccomp=unconfined]`） | codex のサンドボックス（bwrap）は namespace を作って mount する。Docker の既定の seccomp が namespace の作成を、ネイティブ Linux では AppArmor が mount を止める | 外部の機械はネイティブ Linux の Docker Engine なので、これが無いと codex のサンドボックスが動かない。隔離は弱まる。詳しくは「外部の機械の前提」と DCB の README の「コンテナの中での codex のサンドボックス」 |
| UID の合わせ込み（`devcontainer.json` の `updateRemoteUserUID`。生成物は書かず、既定の有効に任せる） | ネイティブ Linux では bind mount の所有者が数値の UID のまま通り、ホストの利用者の UID が 1000 でないとワークスペースへ書き込めない | 外部の機械の利用者の UID が 1000 でなくても、devcontainer CLI がコンテナを作るときに合わせる。`false` にしないこと |

## 層と、この道具が戻すもの

| 層 | 落ちたとき | 戻し方 |
|---|---|---|
| ① 電源・OS | 何も届かない | **範囲外**（物理的な対処） |
| ② 外部の機械への SSH の入口（経路そのもの） | ssh が通らない | **範囲外**（経路の構築・運用。下記「SSH の経路」） |
| ③ devcontainer | `dev ls` の CONTAINER が running でない | **自動**（`dev-up@<名前>`）。待てないときは `dev up <名前>` |
| ③' devcontainer（動いているのに入れない） | CONTAINER は running だが `dev attach` が通らない | **手で**（`dev doctor <名前>` で切り分け、`dev rebuild <名前>` で作り直す） |
| ④ tmux とその中のエージェント | `dev ls` の TMUX が none | **手で**（`dev attach <名前>`。指示の無いエージェントを自動で起こしても作業は進まない） |

**特定のクラウドへの認証（AWS など）は devhost に組み込みません。** 認証は `dev attach` で
コンテナへ入ってから、コンテナの中でプロジェクトが使う CLI を直接叩いて行います。

## 外部の機械への導入

### install.sh で入れる

`install.sh` が、取得・照合・`dev` の設置・ユニットの設置までを 1 つにまとめています。
**取得した `install.sh` は、照合してから実行してください。** `curl ... | bash` の形は勧めません（照合を挟めないため）。
マニフェストと `install.sh` を取得し、`install.sh` のハッシュをマニフェストと照合して、通ったときだけ実行します。

```bash
TAG=v0.2.0   # devcontainer-host の最新安定リリース
BASE="https://github.com/ojos/devcontainer-host/releases/download/${TAG}"

curl -fsSL "${BASE}/RELEASE-MANIFEST.json" -o RELEASE-MANIFEST.json
curl -fsSL "${BASE}/install.sh" -o install.sh

# sha256sum は GNU coreutils のコマンドで、macOS には無い。shasum へ分岐する。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
# 照合と実行を && でつなぐ。照合に失敗したら実行しない（行を分けると、失敗しても次の行が走る）。
jq -r '.checksums["install.sh"] + "  install.sh"' RELEASE-MANIFEST.json | $sha256c -c - \
  && bash install.sh --version "${TAG}"
```

`bash install.sh --dry-run` は、何も書かずに計画だけを出します（取得と照合は行います）。`--version` を省くと最新を入れます。
`install.sh` がすることは次のとおりです。

1. 同じ版の `RELEASE-MANIFEST.json`・`dev.sh`・`dev-up@.service`・`dev-runner@.service`・`runner.Dockerfile`・`projects.example`・`runners.example` を取得し、マニフェストの `checksums` と照合します。
   **1 つでも食い違えば、何も置かずに非 0 で止まります。** `dev.sh` は devhost の `dev.sh` の形か（1 行目が bash の shebang、2 行目が `# dev — ` で始まる）と構文も確かめます。
2. `dev` を `~/.local/bin/dev` へ**写しで**置きます。置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の `dev.sh` でないファイルなら、
   `dev self-update` と同じく置き換えずに止まります。
3. `dev-up@.service` と `dev-runner@.service` を `~/.config/systemd/user/` へ置き、`systemctl --user daemon-reload` を呼びます。
   `runner.Dockerfile` は `~/.config/dev/runner.Dockerfile` へ置きます（イメージは自動では作りません。「自前のランナー」）。
4. `~/.config/dev/projects` と `~/.config/dev/runners` が無ければ、それぞれ `projects.example` / `runners.example` から作ります。**あれば決して上書きしません。**
5. devcontainer CLI・docker・systemd の有無を確かめ、足りないものを案内します。**自動では入れません。**
   `loginctl enable-linger` と、プロジェクトごとの `systemctl --user enable --now dev-up@<名前>.service` も、案内だけです
   （`sudo` が要る・どのプロジェクトを常駐させるかは利用者が決めるため）。

再実行しても壊れません（冪等）。新しい版なら、`dev`・ユニット・`runner.Dockerfile` を更新します。
すでに動いているユニットは、起こし直すまで古い `dev` のまま動くので、`dev restart <名前>` などで起こし直します。
`dev self-update` は `dev` だけを更新し、ユニットや `runner.Dockerfile` が古いときは `install.sh` の再実行を案内します
（「dev を置く」と `dev self-update` の説明を参照）。

この取得の手順は、マニフェストと `install.sh` を同じ取得元から取ります。取得元ごと差し替えられた場合まで防ぐには、
次の「devhost を入手する」の attestation の検証を先に通してください。

以降の「devhost を入手する」「devcontainer CLI を入れる」「dev を置く」「ユニットを入れる」は、`install.sh` を使わずに**手で入れる**手順です。

### devhost を入手する

devhost は、独自の版を持つ公開リポジトリ `ojos/devcontainer-host` のリリースで配られます
（以前は devcontainer-bootstrap（DCB）のリリースに同梱していましたが、同梱は外しました）。
各リリースには `RELEASE-MANIFEST.json`・`SHA256SUMS`・`PACKAGE_ARCHIVE.tar.gz`（このリポジトリのツリー一式）に加えて、
`dev.sh`・`dev-up@.service`・`dev-runner@.service`・`runner.Dockerfile`・`install.sh`・`projects.example`・`runners.example` が個別の資産として付きます（ランナーの 3 つは v0.2.0 から）。`RELEASE-MANIFEST.json` の `checksums` が
`PACKAGE_ARCHIVE.tar.gz` / `SHA256SUMS` と、個別の資産 7 つのハッシュを持つので、取得したものを照合してから使います。

```bash
TAG=v0.2.0   # devcontainer-host の最新安定リリース
BASE="https://github.com/ojos/devcontainer-host/releases/download/${TAG}"

curl -sSL "${BASE}/RELEASE-MANIFEST.json" -o RELEASE-MANIFEST.json
curl -sSL "${BASE}/PACKAGE_ARCHIVE.tar.gz" -o PACKAGE_ARCHIVE.tar.gz

# sha256sum は GNU coreutils のコマンドで、macOS には無い。shasum へ分岐する。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
# マニフェストの checksums には SHA256SUMS などの行もあるが、ここで使うのは archive だけ。
# その行だけを抜き出して照合する（ほかのファイルを取得していないので、全行を渡すと落ちる）。
# archive の中身は、リポジトリのルートそのもの（dev.sh などがルート直下に並ぶ）。専用のディレクトリへ展開する。
# 再実行できるよう mkdir -p を使う（前回の展開物が残っていれば上書きされる。版を変えるときは devhost/ を消してから）。
# 照合と展開を && でつなぐ。照合に失敗したら展開しない（行を分けると、失敗しても次の行が走る）。
jq -r '.checksums["PACKAGE_ARCHIVE.tar.gz"] + "  PACKAGE_ARCHIVE.tar.gz"' RELEASE-MANIFEST.json | $sha256c -c - \
  && mkdir -p devhost && tar -xzf PACKAGE_ARCHIVE.tar.gz -C devhost && ls devhost/
```

`dev.sh` だけが要るときは、個別の資産を取得して、同じマニフェストのハッシュと照合します
（`dev self-update` もこの形で更新します）。

```bash
curl -sSL "${BASE}/dev.sh" -o dev.sh
# 照合に失敗したら、取得した dev.sh を消したうえで非 0 で終わる（未検証のものを残さない。
# `|| rm -f dev.sh` だけだと rm が成功して 0 になり、失敗が成功として扱われる）
jq -r '.checksums["dev.sh"] + "  dev.sh"' RELEASE-MANIFEST.json | $sha256c -c - \
  || { rm -f dev.sh; echo "dev.sh: 照合に失敗しました" >&2; false; }
```

リリースの `SHA256SUMS` には、GitHub Actions が発行した artifact attestation（SLSA provenance）が付いています
（任意の検証。[GitHub CLI](https://cli.github.com/) が要ります）。`SHA256SUMS` は `dev.sh`・`dev-up@.service`・`dev-runner@.service`・`runner.Dockerfile`・`install.sh`・`projects.example`・`runners.example`・`PACKAGE_ARCHIVE.tar.gz` のハッシュを持ちます（ランナーの 3 つは v0.2.0 から）。
**attestation が保証するのは `SHA256SUMS` 自身だけです。** 取得したファイルまで辿るには、attestation の検証に続けて `SHA256SUMS` と取得物を照合します（`RELEASE-MANIFEST.json` だけの照合では、マニフェストごと差し替えられた場合を検出できません）。
**成功しても何も表示されません。判定は終了コードで行ってください**（0 = 成功、非 0 = 失敗）。

```bash
curl -sSL "${BASE}/SHA256SUMS" -o SHA256SUMS
OWNER="$(printf '%s' "$BASE" | sed -n 's#^https://github.com/\([^/]*\)/.*#\1#p')"   # 取得元の owner
if gh attestation verify SHA256SUMS --owner "$OWNER"; then echo "attestation: ok"; else echo "attestation: 検証に失敗しました" >&2; exit 1; fi

# 検証済みの SHA256SUMS と、取得したものだけを照合する（取得していないファイルは飛ばす。
# 全行を渡すと、取得していない dev.sh などが無いことで落ちる）
for f in PACKAGE_ARCHIVE.tar.gz dev.sh dev-up@.service dev-runner@.service runner.Dockerfile install.sh projects.example runners.example; do
  [ -f "$f" ] || continue
  awk -v f="$f" '$2 == f' SHA256SUMS | $sha256c -c - || { echo "$f: 照合に失敗しました" >&2; exit 1; }
done
```

以降の手順は、この `devhost/` を取り出したディレクトリで実行します
（リポジトリを取り込んでいる場合は `packages/devcontainer-host/` を同じ意味で読んでください）。

#### DCB 同梱の古い版から移るとき

DCB の v0.14.0 以降に同梱されていた `dev` の `dev self-update` は、取得先が DCB のリリースです。
DCB が devhost の同梱をやめたため、その古い版の `dev self-update` は更新できず、何も置き換えずに止まります（`archive から ./devhost/dev.sh を取り出せません` と出て終了コード 1）。
**手で 1 度だけ入れ直してください。** 上の手順で `devhost/` を取り出し、「dev を置く」の `install` を打つと、
以降の `dev self-update` は `ojos/devcontainer-host` から更新できます。`dev version` が版を出せば、移り終えています。

### devcontainer CLI を入れる

公式の導入スクリプトを使います。**Node.js を同梱して `~/.devcontainers/` に入る**ので、外部の機械に
Node を入れる必要がなく、ssh の非対話のコマンドや systemd のように `~/.profile` を読まない場面でも
版がずれません（`dev` が `~/.devcontainers/bin` を PATH の末尾へ足します）。

```bash
curl -fsSL https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh -o /tmp/devcontainer-install.sh
less /tmp/devcontainer-install.sh          # 中身を読んでから回す
sh /tmp/devcontainer-install.sh --version 0.89.0
~/.devcontainers/bin/devcontainer --version
```

npm の `@devcontainers/cli` でも動きますが、外部の機械に Node 20 以上が要ります（0.89.0 の `engines`）。

### dev を置く

```bash
install -D -m 0755 devhost/dev.sh ~/.local/bin/dev
mkdir -p ~/.config/dev
cp devhost/projects.example ~/.config/dev/projects   # 名前と絶対パスを書く
~/.local/bin/dev ls
```

**リンクではなく写しで置きます。** リンクにすると、そのリポジトリのブランチを切り替えただけで
外部の機械の道具が黙って変わるためです。道具を更新するには、同じ `install` をもう一度打つか、
`dev self-update` を使います。`dev self-update` は上の「devhost を入手する」と同じ照合（マニフェストの
ハッシュの照合）を通してから、`dev.sh` だけを置き換えます（既定は最新、`--version v0.2.0` で固定）。
置き換え先が devhost の `dev.sh` だと確かめられないとき（リンク、別の道具など）は、何も置き換えずに止まります。
ユニットのファイルと `projects` は書き換えません。更新のあとに、置いてあるユニットのファイルを同じリリースの
`dev-up@.service` と比べ、違えば `install.sh` の再実行（または「ユニットを入れる」の `install` の打ち直し）を案内します。
動いているユニットは、起こし直すまで古い `dev` のまま動くので、`dev restart <名前>` などで起こし直します。

### ユニットを入れる

```bash
install -D -m 0644 devhost/dev-up@.service ~/.config/systemd/user/dev-up@.service
systemctl --user daemon-reload
sudo loginctl enable-linger "$USER"        # ログインしていない間も、起動時からユーザーのユニットを動かす
systemctl --user enable --now dev-up@<名前>.service
systemctl --user status dev-up@<名前>.service
journalctl --user -u dev-up@<名前>.service -n 20
```

- **ユーザーのユニットにしています。** root のユニットにすると利用者の名前（`User=`）を書くことになり、
  docker グループの権限で足りるものに root を使うことになるためです。
- **`docker` グループへ足したのがユーザーのマネージャの起動より後なら**、マネージャは古いグループのまま
  なので、外部の機械を再起動するか `sudo systemctl restart user@$(id -u).service` で起こし直します。
- 起動の直後に Docker のデーモンが遅れても、`up` が失敗して 30 秒後にやり直します（回数の上限なし）。

## 自前のランナー

SSH で届く外部の機械（Linux + systemd + Docker）で、**GitHub Actions の自前のランナーを、ジョブごとに使い捨てのコンテナとして
常駐**させます。private リポジトリの CI を、GitHub がホストするランナーの課金枠を使わずに回すためです。
組織名・ラベルなどの固有の値は外部の機械の設定ファイル（`runners`）に置き、配布物には書きません。

**仕組み。** ユニット `dev-runner@<名前>.service` が `dev runner run <名前>` を起こします。1 回の起動で、(1) PAT で組織の
登録用のトークンを取得し、(2) `--ephemeral` のランナーを `--rm` のコンテナで動かし、(3) ジョブが 1 つ終わってコンテナが止まったら抜けます。
`Restart=always` が新しいコンテナで起こし直すので、ジョブごとにまっさらな環境になります。並列数は、`runners` に行を足して
（名前を変えて）インスタンスを複数有効にすることで増やします。ユニットを止める（`systemctl --user stop`・`disable --now`）と、
`dev` がコンテナを止めて、登録中のランナーを組織から外します（使い捨てのランナーが、登録だけ残る状態を作りません）。

**外部からの PR を受けるリポジトリでは使わないでください。** 自前のランナーはジョブのコードを外部の機械で実行します。
fork などの外部の PR が、その機械で任意のコードを走らせられるようになります（使い捨てのコンテナでも、`lan=allow` のランナーや
`docker=yes` のランナーは、ホストのネットワーク・渡したソケットに届きます）。信頼できる人だけが PR を出せる private リポジトリ・組織に限って使います。
出口の制限（「出口の制限」）は、信頼できないコードを動かしてよくするものではなく、信頼できるコードの事故が LAN に及ばないようにする層です。

### 導入の手順

```bash
# 1. install.sh で入れる（「install.sh で入れる」）。runner.Dockerfile・dev-runner@.service・runners の雛形が置かれる
# 2. 設定を書く（名前 組織 [labels=a,b] [docker=yes|no] [lan=allow|deny] [pat_file=絶対パス]）
$EDITOR ~/.config/dev/runners
# 2b. 出口の規則を root で入れる（下の「出口の制限」。入れないと dev runner run は起動しない）
dev runner net script | sudo install -m 755 /dev/stdin /usr/local/sbin/dev-runner-net
dev runner net unit | sudo install -m 644 /dev/stdin /etc/systemd/system/dev-runner-net.service
sudo systemctl daemon-reload && sudo systemctl enable --now dev-runner-net.service
# 3. PAT を、group / other に権限の無い別のファイルへ置く（既定は ~/.config/dev/runner-pat。値を runners に書かない）
install -m 600 /dev/null ~/.config/dev/runner-pat && $EDITOR ~/.config/dev/runner-pat
# 4. イメージを作る（外部の機械の上でビルドする）
dev runner build
# 5. 点検して、有効にする
dev doctor --runner <名前>
systemctl --user enable --now dev-runner@<名前>.service
journalctl --user -u dev-runner@<名前>.service -n 20
```

- **PAT は fine-grained で、組織の「Self-hosted runners: Read and write」だけ**を持たせます。リポジトリの権限は要りません。
  有効期限を設け、期限が切れたら再発行してファイルを差し替えます。
- **PAT は、group / other に権限があるファイル（644 など）では読みません。** `dev runner run` は拒んで 78 で終わります（`dev doctor --runner` も FAIL にします）。600 や 400 は通ります。
  設定の誤り・PAT の権限・イメージが無い・API が 401 / 403 / 404 を返す(PAT の失効・権限不足・組織名の誤り)、という直らない失敗(終了コード 2 と 78)では、ユニットは起こし直しません(`RestartPreventExitStatus`)。journal の理由を直してから `start` し直します。一時的な失敗（API の 429・5xx、通信の失敗など）は起こし直します。
- **同じ名前のランナーは 2 本同時に動きません。** 名前ごとのロック(`flock`)で 2 本目を拒み、動いているジョブのコンテナを消しません(終了コード 75)。
- **PAT は引数にも環境変数にもログにも出しません。** PAT で API を呼ぶ `curl` へは、設定を標準入力で渡します（`ps` に見えません）。
  コンテナへ渡すのは、登録用のトークン（1 時間で切れる）だけです。値は引数に書かず、環境変数として渡します。
- **Docker のソケットは、既定では渡しません。** `runners` で `docker=yes` にしたランナーにだけ、ホストの Docker のソケット
  （`/var/run/docker.sock`）とそのグループを渡します。**渡すと、ジョブがホストの Docker を自由に操作できるようになります**
  （任意のコンテナを特権で起こせるので、実質ホストの root と同じです）。ジョブがイメージのビルドなどに Docker を必要とする
  リポジトリだけのために、別の名前（別のラベル）のランナーとして用意してください。
- **出口の制限。** ジョブが外部の機械の LAN・機械自身・リンクローカルへ届かないよう、ランナーを専用の Docker ネットワークで動かし、
  そのブリッジから出る新しい接続を止めます。インターネット（GitHub、パッケージの取得）には届きます。
  - **専用ネットワーク。** `dev runner run` が、ネットワーク `dev-runner`（IPv6 無効、ブリッジ名 `dev-runner0` 固定）を無ければ作り、コンテナをそこで動かします。
    ブリッジ名を固定するのは、Docker が付ける `br-<ID>` がネットワークを作り直すたびに変わり、規則を書けなくなるためです。
  - **規則（root）。** 規則の追加には root が要ります。`dev` の本体とユーザーのユニットは root で動かないので、規則を入れる部分だけを別にし、
    `dev runner net script`（スクリプト）と `dev runner net unit`（systemd のシステムのユニット）が標準出力へ出します。上の手順 2b のとおり、利用者が `sudo` で入れます。
    ユニットは Docker の後に入れ（`After=docker.service`）、Docker の再起動のたびに入れ直します（`PartOf=docker.service`）。`PartOf` は停止と再起動しか伝えないので、Docker だけを停止してから起動した場合にも印が戻るよう、`[Install]` に `WantedBy=docker.service` も持ち、`systemctl enable` で Docker の起動に合わせて規則のユニットも起動されます。入れる規則は iptables で、`dev runner net script` の出力の `rules`
    （`/usr/local/sbin/dev-runner-net rules` で、`iptables-restore` に渡す文面を、何も実行せずに確かめられます）が正本です。入れ直しは `iptables-restore --noflush` の 1 回の取り込みで鎖の中身と飛び先を一度に入れ替えるので、入れ替えの途中に制限の無い瞬間はできません（失敗したときは何も変わらず、印も置きません）。
    - FORWARD（`DOCKER-USER` から飛ぶ）: ブリッジから `10.0.0.0/8`・`172.16.0.0/12`・`192.168.0.0/16`・`169.254.0.0/16`・`100.64.0.0/10` への新しい接続を `REJECT`
    - INPUT: ブリッジから外部の機械自身（ゲートウェイ、LAN 側のアドレス）への新しい接続を `REJECT`。`DOCKER-USER` は転送の鎖なので、機械自身への接続には INPUT の規則が別に要ります
  - **印のファイル。** 規則を入れ終えると、スクリプトが `/run/dev-runner-net/ready`（1 行 `bridge=dev-runner0`）を置きます。`dev runner run` は、これが無い・ブリッジ名が違うときは
    起動しません（規則が入っていないまま動くことを防ぎます）。印が無いときは、Docker の再起動の直後など規則のユニットが入れ直すまでの間を見込んで 30 秒まで待ち、それでも無ければ一時的な失敗（終了コード 1）で抜けて、ユニットが起こし直します（78 にすると `RestartPreventExitStatus` に当たって二度と起きないため）。印の確認は登録用のトークンを取る（API を呼ぶ）より前なので、起こし直しが API を消費しません。ブリッジ名が違うのは設定の誤りなので 78 です。
    **印は規則が今も効いていることまでは保証しません**（誰かが `iptables -F` で規則を消しても、印は残ります）。
  - **`lan=allow`。** `runners` で `lan=allow` にしたランナーは、専用ネットワークと印の確認を外し、従来どおり既定のブリッジで動きます。LAN のプロキシ・社内のパッケージ置き場に頼るジョブのためです。
    `lan=deny`（既定）なら制限されます。**LAN に頼るジョブは、`lan=allow` にしない限り動かなくなります。**
  - **名前解決。** Docker の内蔵の DNS（127.0.0.11）はコンテナの中で応答するので、INPUT の規則には掛かりません。ただし上流の DNS が LAN の帯（192.168.x.x など）にあると、
    その先への問い合わせが止まって名前が引けなくなります。その場合は `/etc/default/dev-runner-net` に `DEV_RUNNER_NET_ALLOW_DNS="192.168.1.1"`（空白区切りの IPv4）と書くと、その宛先の 53 番だけを通します。
    書いたら `sudo systemctl restart dev-runner-net.service` で入れ直します。
  - **限界。** `docker=yes` のランナーは、ホストの Docker のソケットを持つので、`--network host` のコンテナを起こして規則を迂回できます。制限が効くのは `docker=no`（既定）のランナーだけです。
    宛先の許可リスト（インターネット側の絞り込み）や IPv6 の規則は持ちません（ネットワークは IPv6 を無効にして作ります）。
    ユニットを止めても（Docker の停止を含む）消えるのは印だけで、規則は残ります（Docker の live-restore でコンテナが動き続けるあいだも制限が外れないようにするため）。規則を外すのは、利用者が明示して `sudo /usr/local/sbin/dev-runner-net clear` を打つときだけで、そのあいだ動いているランナーは制限が外れます。
  - **使えない構成。** Docker が nftables のファイアウォールのバックエンドを使う構成（`--iptables=false` を含む）では、Docker は FORWARD から `DOCKER-USER` への飛び先を作らないため、この規則は効きません。`apply` は FORWARD に `DOCKER-USER` への飛び先があることを確かめ、無ければ何も入れず、印も置かずに失敗します（制限が効かないまま ready にならないようにするため）。
- **イメージ。** 公式のランナーのイメージ（`ghcr.io/actions/actions-runner`）に、配るワークフローが使う道具（git・gh・jq・shellcheck など）を
  足したものです（`runner.Dockerfile`）。**公式のイメージの版は固定しています**（`ARG RUNNER_VERSION`）。コンテナが使い捨てなので
  ランナーの自動更新は効かず、古すぎる版は GitHub が受け付けなくなります。版を上げるのは手で行います。**`runner.Dockerfile` は編集しません**
  (`install.sh` が配布の版で上書きします)。`runners` に `runner_version=X.Y.Z` の行を書くか、環境変数 `DEV_RUNNER_VERSION` を付けて
  `dev runner build` をやり直し(`--build-arg` で渡します。未指定なら Dockerfile の既定値)、ユニットを起こし直します。公式のイメージは docker の CLI と buildx を
  最初から持つので、`runner.Dockerfile` は足しません。入れる道具の一覧は、devcontainer-bootstrap の README の「配るワークフローの実行先（ACTIONS_RUNS_ON）」の一覧が前提です
  （配るワークフローが自前のランナーに要る bash・git・gh・GNU coreutils 相当・sed・grep）。jq・shellcheck・curl・unzip・gawk は、
  利用側の `acceptance.sh` が使うことが多いので、配るワークフローには要らないが入れてあります。
- **更新。** 新しい版へは `install.sh` を再実行します（`runner.Dockerfile` が変わったら、`dev runner build` でイメージを作り直します）。
  `dev self-update` はユニットや `runner.Dockerfile` を書き換えず、古いときに案内だけを出します。

## VS Code の窓を閉じたときの停止（stopCompose）

devcontainer.json が `shutdownAction: stopCompose` のプロジェクトでは、外部の機械に繋いだ VS Code の窓を
閉じるとコンテナが止まります。**docker から見れば「意図した停止」で、異常終了ではありません。**
これをどう戻すかの比較です。

| 案 | VS Code を閉じた後 | docker kill の後 | 他の端末への影響 | 採否 |
|---|---|---|---|---|
| **A. ユニットの ExecStart が止まるまで待ち、止まったら 0 以外で抜ける**（`dev supervise`） | 30 秒後に戻る | 30 秒後に戻る | なし（プロジェクトの定義を触らない） | **採用** |
| B. タイマーで定期に `dev up` を打つ | 周期の分だけ遅れる | 同左 | なし | 不採用。動いている間も `up` を打ち続け、そのたびに postAttachCommand が走る |
| C. 外部の機械では VS Code から繋がない運用にする | 止まる | 戻らない（別の仕組みが要る） | なし | 不採用。導入とログインで VS Code が要り、約束は 1 度閉じれば破れる |
| D. devcontainer.json の shutdownAction を外部の機械だけ `none` にする | 止まらない | 戻らない（別の仕組みが要る） | 共通の定義を触る | 不採用。compose の `.env` は devcontainer.json に届かず、列挙値への置換が効くかは確かめられない。異常停止にはどのみち A が要る |
| E. compose に `restart: unless-stopped` | 戻らない（stop は除外される） | 戻る | 共通の定義を触る | 不採用。本件（意図した停止）を解かない |

**A は「止まった理由」を見ません。** `dev supervise` は `devcontainer up` の結果からコンテナの ID を取り、
`docker wait` で止まるまで待ち、止まったら 0 以外で抜けます。ユニットの `Restart=always` は
（0 以外で抜けるので `on-failure` でも）30 秒後に起こし直します。VS Code の停止も、docker kill も、
デーモンの再起動も同じ扱いです。

**引き換えに、意図して止めたいときはユニットを先に止めます。** 止めるだけなら `dev stop <名前>`
（ユニットを止めてからコンテナを止める。disable はしないので、ユニットが有効なら外部の機械の再起動の後は戻ります。
戻すのは `dev enable <名前>` です。`dev up <名前>` はコンテナを起こすだけで、止めたユニットは起き直りません）。
再起動の後も止めたままにするなら `dev disable <名前>`（ユニットを無効にして、同じ順番でコンテナも止める）、
作り直さずに再起動するなら `dev restart <名前>` を使います。`dev stop` / `dev disable` / `dev restart` の範囲は、
compose で動くプロジェクトならそのプロジェクトのコンテナ全体（DB などの別のサービスを含む。VS Code の
`stopCompose` と同じ。app のコンテナの label `com.docker.compose.project` で列挙し、compose ファイルは読みも
書き換えもしません）で、label が無ければコンテナ 1 つです。列挙の起点は app のコンテナなので、app の
コンテナだけが消えて DB などが残っている場合は見つけられません（`docker ps` で確かめて止めます）。また、
compose のサービスに `restart: always` があると、`dev disable` で止めても Docker デーモンの再起動で
そのコンテナは起き直ります（Docker の仕様。dev は compose を書き換えないので、止めたままにしたいサービスは
各プロジェクトで `unless-stopped` などにします）。`dev restart` は列挙したコンテナを 1 回の `docker restart` で
まとめて再起動するので、compose の `depends_on` の順序や DB の準備完了は待ちません。app が起動時に DB を
要して落ちても、ユニットが動いていれば起こし直しの `devcontainer up` が compose の順序で戻します。順序が要るときは
`dev rebuild` を使います。作り直しは `dev rebuild <名前>` が
ユニットの停止と起こし直しまで行います（止めずに作り直すと、30 秒後にユニットの `up` が作り直しの
途中に重なりえます。VS Code の Rebuild Container も同じなので、VS Code から作り直すときは先に
`systemctl --user stop dev-up@<名前>.service` で止め、終わったら `start` で戻します）。
作り直しを効かせる必要があるとき（例: compose の定義を変えたとき）も `dev rebuild` を使います。

## 使い方

| コマンド | 何をするか |
|---|---|
| `dev ls` | 登録したプロジェクトの状態を並べる |
| `dev up <名前>` | devcontainer を起こす |
| `dev attach <名前>` | コンテナの中の tmux に入る |
| `dev supervise <名前>` | 起こして止まるまで待つ（ユニットから使う） |
| `dev rebuild <名前> [--pull]` | コンテナを作り直す |
| `dev doctor <名前>` | 「動いているのに入れない」を見分ける |
| `dev doctor --runner <名前>` | 自前のランナーの点検（イメージ・PAT ファイルの権限・ユニット） |
| `dev runner build` / `dev runner run <名前>` | ランナーのイメージを作る / 使い捨てのランナーのコンテナを起こして止まるまで待つ（ユニットから使う） |
| `dev runner net script` / `dev runner net unit` | 出口の規則を入れる root のスクリプト / systemd のシステムのユニットを標準出力へ出す（`sudo` で入れる） |
| `dev restart <名前>` | 作り直さずに再起動する |
| `dev stop <名前>` | 意図して止める（ユニットを先に止める。戻すのは `dev enable`） |
| `dev logs <名前> [-n <行数>]` | ユニットのログの末尾（既定 50 行） |
| `dev enable <名前>` / `dev disable <名前>` | ユニットを有効にして起こす / 無効にして止める（`disable` はコンテナも止める） |
| `dev exec <名前> -- <コマンド...>` | tmux を介さずにコンテナの中でコマンドを 1 つ実行する |
| `dev self-update [--version <vX.Y.Z>]` | dev 自身を devcontainer-host の公開リリースの版へ置き換える |
| `dev version` | dev の版を出す（`dev --version` も同じ） |
| `dev help [サブコマンド]` | 説明を出す |

オプション・呼ぶ順序・終了コード・失敗したときの案内は、次の「コマンドの説明」にあります。
同じ内容を端末で `dev help <サブコマンド>` として読めます（説明文の正本は `dev.sh` で、
下のブロックは `dev help <サブコマンド>` の出力をそのまま載せたものです。`selftest.sh` が一致を照合します）。

## コマンドの説明

### dev ls

```text
dev ls — 登録したプロジェクトの状態を並べる。

使い方:
  dev ls

NAME / CONTAINER / UNIT / TMUX を 1 行ずつ出す。
  CONTAINER  docker の状態（running / exited など）。無ければ none
  UNIT       dev-up@<名前> の systemd のユニットの状態。systemctl が無ければ -
  TMUX       コンテナの中の tmux のセッションの有無（CONTAINER が running のときだけ）
CONTAINER が running でも入れないことがある。そのときは dev doctor <名前>。

終了コード: 0 = 成功 / 2 = 使い方か設定ファイルの誤り
```

### dev up

```text
dev up — devcontainer を起こす（在れば何もしない）。

使い方:
  dev up <名前>

devcontainer up --workspace-folder <パス> を呼ぶ。作り直しはしない（作り直すときは dev rebuild）。

終了コード: 0 = 成功 / 1 = 起動の失敗 / 2 = 使い方か設定ファイルの誤り（未登録の名前を含む）
失敗したとき: 経過の出力を読む。コンテナが戻らないときは dev doctor <名前>。
```

### dev attach

```text
dev attach — コンテナの中の tmux に入る（無ければ作る）。

使い方:
  dev attach <名前>

devcontainer exec で tmux new-session -A -s <セッション名> を呼ぶ。セッション名の既定は main で、
設定ファイルの tmux_session=<名前> で変えられる。コンテナは起こさない（ユニットが起こし直している
最中に 2 本目の up を重ねないため）。

終了コード: 0 = 成功 / 1 = コンテナが動いていない、または中へ入れなかった・セッションが異常終了した
            （この 2 つは区別できない。元の終了コードは案内の文面に出す） / 2 = 使い方か設定の誤り
失敗したとき:
  コンテナが動いていない  dev up <名前>（ユニットを有効にしていれば 30 秒ほどで戻る）
  入れなかった           dev doctor <名前> で切り分け、直らなければ dev rebuild <名前>
```

### dev supervise

```text
dev supervise — 起こして、止まるまで待つ（systemd のユニット dev-up@.service の ExecStart）。

使い方:
  dev supervise <名前>

devcontainer up で起こし、docker wait でコンテナが止まるまで待つ。止まった理由を問わず、
必ず 0 以外で終わる（ユニットの Restart=always が起こし直す）。人が直接使うものではない。
意図して止めたいときはユニットを先に止める（dev rebuild は自分で止めて起こし直す）。

終了コード: 1 = コンテナが止まった、または起こせなかった / 2 = 使い方か設定ファイルの誤り
```

### dev rebuild

```text
dev rebuild — コンテナを作り直す。

使い方:
  dev rebuild <名前> [--pull]

呼ぶ順序:
  1. --pull のときだけ git -C <パス> pull --ff-only。失敗したら、何も止めずに終わる
  2. ユニット dev-up@<名前> が inactive / failed / unknown（ユニットを入れていない）でなければ止める
     （起こし直しの待機中の activating も止める。止める必要の無いとき、または systemctl が無いときは
     触らない）。systemctl はあるのに状態の語が得られないとき（問い合わせの失敗）は、
     up と重なる危険を避けるため、何も作り直さずに 1 で止まる
     （確かめる: systemctl --user status dev-up@<名前>）
  3. devcontainer up --workspace-folder <パス> --remove-existing-container
  4. 2 で止めたときだけ、ユニットを起こし直す。3 が失敗しても、INT / HUP / TERM で中断されても
     （ssh の切断など）起こし直してから終わる（中断の終了コードは 130 / 129 / 143）
ユニットを先に止めるのは、作り直しの途中でユニットの up が重ならないようにするため。
各プロジェクトの compose や devcontainer.json は書き換えない。

オプション:
  --pull   作り直す前に git pull --ff-only する（利用者が明示したときだけ）

終了コード: 0 = 作り直した / 1 = 失敗（pull・ユニットの停止・作り直し） / 2 = 使い方か設定の誤り
失敗したとき: pull の失敗は手で解消してからやり直す。作り直しの失敗は出力を読み、dev doctor <名前>。
```

### dev doctor

```text
dev doctor — 「コンテナは動いているのに入れない」を見分ける。

使い方:
  dev doctor <名前>
  dev doctor --runner <名前>

出す項目: コンテナの有無と状態 / exec が実際に通るか / cgroup の pids.current と pids.max /
pids の上限に当たった回数 / ゾンビの数 / memory.events の oom_kill / ユニットの状態 / ユニットのログの末尾。
cgroup は /proc/<コンテナの PID>/cgroup から求める（cgroup v2）。
pids の上限は、コンテナの cgroup から根まで遡り、上限のある階層のうち現在値 / 上限 の比が最大のもので
判定して、その階層を表示する（systemd の slice の TasksMax などに当たっていても見逃さない）。
exec は 30 秒（環境変数 DEV_EXEC_TIMEOUT で変えられる。1 以上の整数）で返らなければ FAIL にする。
TERM を送っても止まらないときは、さらに 5 秒（DEV_EXEC_KILL_GRACE。1 以上の整数）後に KILL する。

判定:
  FAIL  exec が通らないか返らない / pids が上限の 90% 以上 / pids.max が 0 /
        コンテナが無いか動いていない
  WARN  pids の上限に当たった回数が 1 以上 / ゾンビが 100 以上 / oom_kill が 1 以上
  （読めない項目、pids.max が数でも max でもない値のときも WARN）

終了コード: 0 = 問題なし / 1 = FAIL がある / 2 = 使い方か設定ファイルの誤り / 3 = WARN だけ
失敗したとき: FAIL なら dev rebuild <名前> で作り直す。WARN だけなら原因を調べてから判断する。

--runner は自前のランナー（dev runner、設定ファイル runners の名前）の点検。プロジェクトの設定ファイルは読まない。
  FAIL  ランナーのイメージが無い / PAT ファイルが無い・group / other に権限がある・読めない /
        docker=yes なのに Docker のソケットが無い
  WARN  ユニット dev-runner@<名前> が active でも activating でもない
  （docker=yes の設定は、危険を知らせる INFO を出す。PAT の値は出さない）
```

### dev runner

```text
dev runner — GitHub Actions の自前のランナーを、使い捨てのコンテナで動かす。

使い方:
  dev runner build
  dev runner run <名前>
  dev runner net script|unit

build: ランナーのイメージ（公式のランナーのイメージに道具を足した runner.Dockerfile）を作る。
  Dockerfile は標準入力から渡す（ビルドの文脈を作らない）。Dockerfile は編集しない。公式のランナーの版を上げるときは、
  環境変数 DEV_RUNNER_VERSION か、設定ファイルの `runner_version=X.Y.Z` の行で指定する（--build-arg で渡す。未指定なら Dockerfile の既定値）。
run: ユニット dev-runner@<名前>.service の ExecStart。1 回の起動で次をする。
  0. 同じ名前のランナーがすでに動いていれば（ロックが取れなければ）、何も消さずに 75 で終わる
  1. 設定ファイル runners の PAT のファイルを調べる（group / other に権限があれば、読まずに拒んで 78 で終わる）
  2. PAT で組織の登録用のトークンを取得する（PAT は引数にも環境変数にも出さない）
  3. --ephemeral のランナーを --rm のコンテナで起こす。コンテナへ渡すのは登録用のトークンだけ
  4. ジョブが 1 つ終わってコンテナが止まったら抜ける（ユニットが新しいコンテナで起こし直す）
  3 の前（2 の API を呼ぶより前）に、出口の規則の印（/run/dev-runner-net/ready。ブリッジ名 dev-runner0 を含む）を確かめる。無いときは起動せず 1 で終わり（ユニットが起こし直す）、ブリッジ名が違うときは 78 で終わる
  （Docker の再起動に備え、無ければ 30 秒まで待つ）。印があれば、専用の Docker ネットワーク dev-runner（IPv6 無効、ブリッジ名 dev-runner0 固定）を
  無ければ作り、コンテナをそこで動かす。設定ファイルで lan=allow にしたランナーは、この確認を外し、既定のブリッジで動かす。
  コンテナを起こしたあと、正常に終わらなかったとき（止めたとき（ユニットの停止・TERM・INT・HUP）や失敗したとき）だけ、
  コンテナを止め、登録中のランナーを組織から外す（正常に終わったときは、GitHub 側で外れている）。
  Docker のソケットは、設定ファイルで docker=yes にしたランナーにだけ渡す（既定は渡さない。
  渡すと、ジョブがホストの Docker を自由に操作できる）。
設定ファイル: runners（既定は ~/.config/dev/runners（XDG_CONFIG_HOME があればその下）。環境変数 DEV_RUNNERS_FILE で差し替える。書式は runners.example）。
  1 行 1 ランナーで「名前 組織 [labels=a,b] [docker=yes|no] [lan=allow|deny] [pat_file=絶対パス]」。
  `runner_version=X.Y.Z` だけの行は、イメージに使う公式のランナーの版（共通の設定）。
net: 出口の規則を入れる root の部分を標準出力へ出す（dev 自身は何も入れない。sudo で入れる手順は、このパッケージの README の自前のランナーの節）。
  script  規則を入れるスクリプト（/usr/local/sbin/dev-runner-net）。apply / unmark / clear / rules を持つ
  unit    それを呼ぶ systemd のシステムのユニット（/etc/systemd/system/dev-runner-net.service）
  止める出口: 専用ブリッジから 10/8・172.16/12・192.168/16・169.254/16・100.64/10 と、機械自身への新しい接続。docker=yes のランナーはソケットで迂回できるので対象外。
点検は dev doctor --runner <名前>。curl と jq が要る。

終了コード: 0 = ジョブを終えて止まった（build は作れた） / 1 = 一時的な失敗（API の 429・5xx や通信の失敗、コンテナの失敗、出口の規則の印がまだ無い、など。ユニットは起こし直す） /
            2 = 使い方か設定ファイルの誤り / 75 = 同じ名前がすでに動いている / 78 = イメージが無い・PAT の権限が緩い・Docker のソケットが無い・出口の規則の印のブリッジ名が違う・API が 401 / 403 / 404（PAT の失効・権限不足・組織名の誤り）
            （2 と 78 は、ユニットが起こし直さない）
失敗したとき: dev doctor --runner <名前> で原因を見分ける。
```

### dev restart

```text
dev restart — 作り直さずにコンテナを再起動する。

使い方:
  dev restart <名前>

呼ぶ順序:
  1. 対象のコンテナを集める。無ければ、ユニットにも触らずに 1 で止まる（dev up <名前>）。
     docker の問い合わせが失敗したときも、何も変えずに 1 で止まる（「無い」とは区別する）
  2. ユニット dev-up@<名前> を、dev rebuild と同じ基準で止める（inactive / failed / unknown /
     systemctl が無い、のときは触らない。状態の語が得られないときは、何も変えずに 1 で止まる）
  3. docker restart <対象のコンテナ>
  4. 2 で止めたときだけ、ユニットを起こし直す。3 が失敗しても、INT / HUP / TERM で中断されても
     （ssh の切断など）起こし直してから終わる（中断の終了コードは 130 / 129 / 143）
範囲: コンテナ 1 つではなく、compose で動くプロジェクトならそのプロジェクトのコンテナ全体
（app のコンテナの label com.docker.compose.project で同じプロジェクトを列挙する。DB などの別のサービスも
含む。VS Code の stopCompose と同じ範囲）。label が無いものは、これまでどおりコンテナ 1 つ。
各プロジェクトの compose ファイルは読まず、書き換えない。
ユニットを先に止めるのは、再起動でコンテナが一瞬止まったときに、ユニットが up を重ねないようにするため。
作り直しはしない（定義を変えたときは dev rebuild）。各プロジェクトの compose や devcontainer.json は書き換えない。

終了コード: 0 = 再起動した / 1 = 失敗（コンテナが無い・ユニットの停止・docker restart） / 2 = 使い方か設定の誤り
失敗したとき: 出力を読み、dev doctor <名前>。直らなければ dev rebuild <名前>。
```

### dev stop

```text
dev stop — 意図してコンテナを止める。

使い方:
  dev stop <名前>

呼ぶ順序:
  1. ユニット dev-up@<名前> を、dev rebuild と同じ基準で先に止める
     （コンテナだけを止めると、ユニットが 30 秒後に起こし直すため）。止められなければ、コンテナには触らない
  2. 対象のコンテナを集めて docker stop する。無いときは何もしない。止まりきった状態
     （exited / created / dead）のコンテナは、コンテナごとに止めない（paused / restarting などは止める）。
     docker の問い合わせが失敗したときは、「無い」とせずに 1 で終わる（ユニットは止めたまま）
範囲: コンテナ 1 つではなく、compose で動くプロジェクトならそのプロジェクトのコンテナ全体
（app のコンテナの label com.docker.compose.project で同じプロジェクトを列挙する。DB などの別のサービスも
含む。VS Code の stopCompose と同じ範囲）。label が無いものは、これまでどおりコンテナ 1 つ。
各プロジェクトの compose ファイルは読まず、書き換えない。
ユニットは disable しない（有効なら、外部の機械を再起動すれば、ユニットが戻ってコンテナも戻る）。
戻すとき: dev enable <名前>。enable --now は、無効のユニットにも、有効のまま止まっているユニットにも効く。
dev up はコンテナを起こすだけで、止めたユニットは起き直らないので、戻すのには使わない。
再起動の後も戻したくないときは、dev disable <名前>（ユニットを無効にして、コンテナも止める）。

終了コード: 0 = 止めた（元から無い・止まっているときも 0） / 1 = 失敗（ユニットの停止・docker の問い合わせ・docker stop） / 2 = 使い方か設定の誤り
```

### dev logs

```text
dev logs — ユニットのログの末尾を出す。

使い方:
  dev logs <名前> [-n <行数>]

journalctl --user -u dev-up@<名前>.service -n <行数> --no-pager を呼ぶ。行数の既定は 50（1 以上の整数）。

オプション:
  -n <行数>   末尾から出す行数

終了コード: 0 = 成功 / 1 = journalctl が失敗した（または無い） / 2 = 使い方か設定の誤り
```

### dev enable

```text
dev enable — ユニットを有効にして起こす。

使い方:
  dev enable <名前>

systemctl --user enable --now dev-up@<名前>.service を呼ぶ。外部の機械の起動時から、
ユニットがコンテナを起こして保つようになる。ユニットを入れる手順は README の「ユニットを入れる」。

終了コード: 0 = 成功 / 1 = systemctl が失敗した（または無い） / 2 = 使い方か設定の誤り
```

### dev disable

```text
dev disable — ユニットを無効にして、コンテナも止める。

使い方:
  dev disable <名前>

呼ぶ順序（dev stop と同じ、ユニット → コンテナ）:
  1. systemctl --user disable --now dev-up@<名前>.service（ユニットを無効にして止める）。失敗したら、コンテナには触らない
  2. 対象のコンテナを docker stop する（範囲・止まりきった状態の扱い・docker の問い合わせの失敗の扱いは dev stop と同じ。
     compose で動くプロジェクトなら、そのプロジェクトのコンテナ全体）
外部の機械を再起動した後も、止めたままになる。戻すときは dev enable <名前>
（ユニットを有効にして起こす。コンテナも戻る）。コンテナだけを止めて再起動の後は戻したいときは dev stop <名前>。

終了コード: 0 = 無効にして止めた / 1 = 失敗（systemctl・docker の問い合わせ・docker stop） / 2 = 使い方か設定の誤り
```

### dev exec

```text
dev exec — tmux を介さずに、コンテナの中でコマンドを 1 つ実行する。

使い方:
  dev exec <名前> -- <コマンド...>

コンテナが動いていなければ、dev attach と同じく案内して 1 で止まる（自分では起こさない）。
動いていれば devcontainer exec --workspace-folder <パス> <コマンド...> を呼び、-- より後ろを
そのまま渡す。コマンドの先頭が - で始まるものは渡せない（devcontainer 自身のオプションと読まれるため）。
例: dev exec <名前> -- codex login --device-auth
ssh 越し（ssh -t <ホスト> .local/bin/dev exec ...）では、外部の機械のログインシェルが引数を
もう一度分割するので、ssh の引数のクォートが 1 段剥がれる。空白を含む引数や sh -c '...' は、
ssh のコマンド全体をクォートして、外側と内側の二重に包む。

終了コード: 0 = コマンドが成功 / 1 = コンテナが動いていない / 2 = 使い方か設定の誤り /
            それ以外 = コンテナの中のコマンドの終了コードをそのまま返す
```

### dev self-update

```text
dev self-update — dev 自身を、devcontainer-host の公開リリースの版へ置き換える。

使い方:
  dev self-update [--version <vX.Y.Z>]

呼ぶ順序:
  1. 置き換え先（この dev）が、リンクでもディレクトリでも git で追跡されているファイルでもなく、devhost の dev.sh であることを
     確かめる（1 行目が bash の shebang、2 行目が「# dev — 」で始まる）
  2. 公開リリースから RELEASE-MANIFEST.json を取得する（既定は最新。--version でその版に固定する）
  3. マニフェストの checksums に記録された dev.sh の SHA-256 を読み、同じリリースの dev.sh を取得して照合する
  4. 取得した dev.sh が 1 と同じ形（bash の shebang と「# dev — 」）であることと、構文を確かめる
  5. 同じディレクトリの一時ファイルへ写し、mv で置き換える
  6. 置いてあるユニットのファイル（~/.config/systemd/user/dev-up@.service と dev-runner@.service）と、ランナーの
     Dockerfile（~/.config/dev/runner.Dockerfile）を、同じリリースのマニフェストの checksums の同名の資産と比べる。
     違えば、install.sh を再実行して更新するよう案内する
     （ファイルを置いていない、マニフェストにハッシュが無いときは何も言わない）
  7. 置き換えたあと、動いているユニットは起こし直すまで古い dev のまま動き続けることを案内する
     （dev restart <名前>、または systemctl --user restart dev-up@<名前>.service）
どれか 1 つでも外れたら（1〜5）、何も置き換えずに 1 で止まる。手動の入手（README の「devhost を入手する」）と
同じ照合。dev.sh だけを置き換える。**ユニット・Dockerfile・設定ファイルは書き換えない**（6 は差の案内だけで、
更新は install.sh の再実行に任せる）。
curl と jq と、sha256sum または shasum が要る。

オプション:
  --version <vX.Y.Z>   取得する版（既定は最新）

終了コード: 0 = 置き換えた（すでに同じ版なら置き換えずに 0） / 1 = 失敗（取得・照合・置き換え先の確認・置き換え） / 2 = 使い方の誤り
```

### dev version

```text
dev version — dev の版を出す。

使い方:
  dev version
  dev --version

出力は `dev vX.Y.Z` の 1 行。公開した版のこの値は、リリースの手順が書き込む。
プロジェクトの設定ファイルは読まない。

終了コード: 0 = 成功 / 2 = 使い方の誤り
```

### dev help

```text
dev help — サブコマンドの説明を出す。

使い方:
  dev help                  使い方の一覧
  dev help <サブコマンド>    ls / up / attach / supervise / rebuild / doctor / runner /
                            restart / stop / logs / enable / disable / exec / self-update / version の説明

終了コード: 0 = 成功 / 2 = 知らないサブコマンド
```

## SSH の経路

**経路は差し替え可能な部品として扱います。** `dev` はどの経路で届いた ssh かを区別しません。
3 通りの `ssh_config` の雛形を用意しているので、外部の機械の置き場所と運用に合わせて選びます。

| 経路 | 雛形 | 公開範囲 | 構築の手間 |
|---|---|---|---|
| 素の SSH | `ssh_config.plain.example` | 最大（sshd のポートをそのままインターネットへ出す） | 最小（ポート転送か固定 IP だけ） |
| Cloudflare Access | `ssh_config.cloudflared.example` | Access のポリシーで絞る（sshd 自体は非公開） | Tunnel と Access の構築が要る |
| Tailscale | `ssh_config.tailscale.example` | 同じ tailnet の中だけ | tailnet への参加（`tailscale up`）だけ |

経路ごとの要点（どの経路でも共通の前提）:

- **鍵は端末ごとに分けます。** 他の端末の鍵は写さず、端末ごとに `ssh-keygen` で作り直します。
  紛失したら、外部の機械の `authorized_keys` からその 1 行を消せば失効します（下記「端末専用の鍵」）。
- **パスワード認証は無効にする前提で書いています。** 外部の機械の `sshd_config` で
  `PasswordAuthentication no` にしてください。この道具一式は sshd の設定そのものは変更しません。
- **事業者固有の構築手順（Tunnel の作成、Access のポリシー、tailnet への参加）は公式文書に従います。**
  この道具一式が決めるのは `ssh_config` の書き方だけで、構築の自動化は扱いません（親票の scope.out）。

### 端末専用の鍵

**この端末のためだけの鍵を作り、パスフレーズを付けます。** 他の端末の鍵は写しません。
紛失したら、外部の機械の `authorized_keys` からその 1 行を消せば失効します。

```bash
# 端末で
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/<鍵> -C "<見分けの付く名前>"   # パスフレーズを付ける
cat ~/.ssh/<鍵>.pub                                                      # この 1 行を外部の機械へ渡す
```

公開鍵は秘密ではないので、自分宛てのメモなどで外部の機械へ入れる端末から渡し、外部の機械で足します。

```bash
# 外部の機械で（既に入れる端末から）
umask 077 && mkdir -p ~/.ssh
printf '%s\n' '<公開鍵の 1 行>' >> ~/.ssh/authorized_keys
```

**失効させる**（外部の機械で。コメントの `<見分けの付く名前>` で行を引く）:

```bash
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
grep -vF '<見分けの付く名前>' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
grep -cF '<見分けの付く名前>' ~/.ssh/authorized_keys     # 0 であること
```

既存のファイルへの書き込みなので、`authorized_keys` の権限（600）はそのまま残ります。
失効の後、その端末からの ssh は `Permission denied (publickey)` で止まります。

## スマホ（Termux）

### 入れるもの

**Termux と Termux:Widget は同じ入手元（F-Droid か GitHub の Releases）から入れます。** 署名が入手元ごとに
違い、混ぜると連携しません。Google Play 版は更新が止まっていて、追加アプリとも連携しません。

経路に Cloudflare Access を選ぶ場合は `pkg install openssh cloudflared`、素の SSH や Tailscale を選ぶ場合は
`pkg install openssh`（Tailscale はさらに `pkg install tailscale` と `tailscale up` が要ります）。

### ssh の入口とショートカット

選んだ経路の `ssh_config.*.example`（本ディレクトリ直下）を `~/.ssh/config` に足し、
`termux/shortcut.example` を写して `~/.shortcuts/` にボタン 1 つにつき 1 ファイル置きます
（`chmod 700 ~/.shortcuts && chmod +x ~/.shortcuts/*`）。ホーム画面に Termux:Widget のウィジェットを
置くと、ファイル名がボタンになります。

- **ボタンを押すたびに鍵のパスフレーズを聞かれます。** 紛失時の守りなので、agent に常駐させません。
- Cloudflare Access を選んだ場合、**Access の認証が切れていると**、ssh の代わりに cloudflared が
  URL を出して待ちます。URL を長押しで開き、ブラウザで認証すると、そのまま ssh が続きます。
- ショートカットの `dev` は `.local/bin/dev` と書きます。ssh の非対話のコマンドでは外部の機械の
  `~/.profile` が読まれず、`~/.local/bin` が PATH に無いためです。

## AI エージェントについて

**devhost は tmux の中のエージェントを自動では起動しません。** 自動で戻すのはコンテナまで
（`dev-up@.service`）で、tmux とその中のエージェントは `dev attach` で利用者が手で起こします。
指示の無いエージェントを自動で起こしても作業は進まないためです。

## 試験

```bash
bash devhost/selftest.sh   # DEVHOST_SELFTEST_PASS
```

偽の devcontainer / docker / tmux / systemctl / git / ps / journalctl / curl を PATH に置き、組み立てるコマンド・
未登録の名前の拒否・設定ファイルの誤り・`rebuild` / `restart` / `stop` / `exec` / `doctor` / `self-update` / `runner` の振る舞い・ユニットの要の行を見ます。
`runner` では、PAT が引数・コンテナの環境変数・出力に現れないこと、権限が緩い PAT ファイルの拒否、Docker のソケットを渡す条件、
止めたときに登録を外す API を呼ぶことを、偽の `docker` / `curl`（GitHub の API には出ません）で確かめます。
加えて、上の「コマンドの説明」の各ブロックが `dev help` の出力と一致すること、載せたサブコマンドの集合が
`dev` の受け付ける集合と一致することを照合します（説明の 1 行を書き換えた複製では落ちることも確かめます）。偽物を本物に合わせたところは `selftest.sh` の冒頭にあります。
`dev doctor` が読む /proc と cgroup の根は、環境変数 `DEV_PROC_ROOT` / `DEV_CGROUP_ROOT` で差し替えられます
（自己試験が偽の木を渡すためで、既定は本物の `/proc` と `/sys/fs/cgroup` です）。
`dev self-update` の置き換え先は環境変数 `DEV_SELF_PATH` で差し替えられます（自己試験が、偽の `curl` と
一時ディレクトリの偽の `dev` に対して回すためで、既定は実行中の `dev.sh` 自身です）。
