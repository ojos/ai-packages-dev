# devhost — SSH で届く外部の機械に置く入口の道具

SSH で届く外部の機械（Linux + systemd が前提）に置き、**端末から 1 コマンドで
devcontainer を起こし、入る**ための道具一式です。どのプロジェクトにも依存しません。
名前・パス・ホスト名は外部の機械の設定ファイルに置き、ここには書きません（`scripts/check-neutrality.sh` で検査しています）。

| ファイル | 置き場所（外部の機械 / 端末） | 役割 |
|---|---|---|
| `dev.sh` | `~/.local/bin/dev`（外部の機械） | 入口の道具。`ls` / `up` / `attach` / `supervise` / `rebuild` / `doctor` / `restart` / `stop` / `logs` / `enable` / `disable` / `exec` / `self-update` / `help` |
| `dev-up@.service` | `~/.config/systemd/user/`（外部の機械） | 起動時と、コンテナが止まったときに起こし直すユニット |
| `projects.example` | `~/.config/dev/projects`（外部の機械） | 設定ファイルの雛形（名前 → パス） |
| `ssh_config.plain.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: 素の SSH） |
| `ssh_config.cloudflared.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: Cloudflare Access） |
| `ssh_config.tailscale.example` | 端末の `~/.ssh/config` | ssh の入口の断片（経路: Tailscale） |
| `termux/shortcut.example` | スマホの `~/.shortcuts/` | Termux:Widget のボタン 1 つ分 |
| `selftest.sh` | （置かない） | 偽の道具で回す自己試験 |

## 外部の機械の前提

**Linux + systemd を前提とします。** `dev-up@.service` はユーザーの systemd ユニットなので、
systemd を持たない OS（macOS や、systemd を使わない Linux ディストリビューション）には
導入できません。端末側（ssh で繋ぐ側）は macOS / Linux / Termux のいずれでも、同じ書式の
`ssh_config` で使えます。

**ネイティブ Linux の Docker Engine でワークスペースへ書き込めない場合**は、
devcontainer-bootstrap（DCB）の README の「ネイティブ Linux の Docker でのワークスペースの所有者」に
従ってください。`updateRemoteUserUID` が既定で UID/GID を揃えるため、devhost 側で追加の対処はしません
（devhost は DCB のリリースへ同梱されて配布されるため、この README と DCB の README は配布先で
階層が変わります。相対リンクにはしません）。

**ネイティブ Linux の Docker Engine で codex のサンドボックスを使うには、コンテナの AppArmor と
seccomp の既定の制限を両方外す必要があります**（seccomp は Docker Desktop でも止めます）。DCB の `--with-codex` の生成物は、`compose.yaml` に
`security_opt: [apparmor=unconfined, seccomp=unconfined]` を入れてあるので、そのままで動きます。
`--with-codex` を使わずに codex を後から入れた場合や、それより前の DCB で生成した場合は、
DCB の README の「コンテナの中での codex のサンドボックス」に従って足してください。
AppArmor だけを外しても、seccomp が先に止めるので動きません（Ubuntu 26.04 の実機で実測）。

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

### devhost を入手する

devhost は独立したリリースを持たず、**devcontainer-bootstrap（DCB）のリリースに同梱されています。**
`RELEASE-MANIFEST.json` と `PACKAGE_ARCHIVE.tar.gz` を取得し、マニフェストが記録した archive のハッシュと照合してから取り出します。
手順の詳細と検証の意味は DCB の README の「devhost」の節を参照してください。

```bash
TAG=v0.17.0   # DCB の最新安定リリース（devhost を同梱したのは v0.14.0 以降）
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"

curl -sSL "${BASE}/RELEASE-MANIFEST.json" -o RELEASE-MANIFEST.json
curl -sSL "${BASE}/PACKAGE_ARCHIVE.tar.gz" -o PACKAGE_ARCHIVE.tar.gz

# sha256sum は GNU coreutils のコマンドで、macOS には無い。shasum へ分岐する。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
# マニフェストの checksums には SHA256SUMS の行もあるが、devhost に要るのは archive だけ。
# その行だけを抜き出して照合する（SHA256SUMS を取得していないので、全行を渡すと落ちる）。
jq -r '.checksums["PACKAGE_ARCHIVE.tar.gz"] + "  PACKAGE_ARCHIVE.tar.gz"' RELEASE-MANIFEST.json | $sha256c -c -

# archive の中の名前は ./devhost/... なので、./ を付けて指定する（GNU tar は devhost/ だと一致しない）。
tar -xzf PACKAGE_ARCHIVE.tar.gz ./devhost
ls devhost/
```

以降の手順は、この `devhost/` を取り出したディレクトリで実行します
（リポジトリを取り込んでいる場合は `packages/devhost/` を同じ意味で読んでください）。

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
ハッシュと archive の照合）を通してから、`dev.sh` だけを置き換えます（既定は最新、`--version v0.17.0` で固定）。
置き換え先が devhost の `dev.sh` だと確かめられないとき（リンク、別の道具など）は、何も置き換えずに止まります。
`dev-up@.service` と `projects` は更新しません（ユニットを更新したときは「ユニットを入れる」の `install` を打ち直します）。

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
各プロジェクトで `unless-stopped` などにします）。作り直しは `dev rebuild <名前>` が
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
| `dev restart <名前>` | 作り直さずに再起動する |
| `dev stop <名前>` | 意図して止める（ユニットを先に止める。戻すのは `dev enable`） |
| `dev logs <名前> [-n <行数>]` | ユニットのログの末尾（既定 50 行） |
| `dev enable <名前>` / `dev disable <名前>` | ユニットを有効にして起こす / 無効にして止める（`disable` はコンテナも止める） |
| `dev exec <名前> -- <コマンド...>` | tmux を介さずにコンテナの中でコマンドを 1 つ実行する |
| `dev self-update [--version <vX.Y.Z>]` | dev 自身を DCB の公開リリースの版へ置き換える |
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
dev self-update — dev 自身を、DCB の公開リリースの版へ置き換える。

使い方:
  dev self-update [--version <vX.Y.Z>]

呼ぶ順序:
  1. 置き換え先（この dev）が、リンクでも git の作業ツリーの中でもなく、devhost の dev.sh であることを
     確かめる（1 行目が bash の shebang、2 行目が「# dev — 」で始まる）
  2. 公開リリースから RELEASE-MANIFEST.json と PACKAGE_ARCHIVE.tar.gz を取得する
     （既定は最新。--version でその版に固定する）
  3. マニフェストに記録された archive の SHA-256 と、取得した archive のハッシュを照合する
  4. archive から ./devhost/dev.sh を取り出し、1 と同じ形（bash の shebang と「# dev — 」）であることと構文を確かめる
  5. 同じディレクトリの一時ファイルへ写し、mv で置き換える
どれか 1 つでも外れたら、何も置き換えずに 1 で止まる。手動の入手（README の「devhost を入手する」）と
同じ照合。dev.sh だけを置き換える（dev-up@.service や設定ファイルには触らない）。
curl / jq / tar と、sha256sum または shasum が要る。

オプション:
  --version <vX.Y.Z>   取得する版（既定は最新）

終了コード: 0 = 置き換えた（すでに同じ版なら置き換えずに 0） / 1 = 失敗（取得・照合・置き換え先の確認・置き換え） / 2 = 使い方の誤り
```

### dev help

```text
dev help — サブコマンドの説明を出す。

使い方:
  dev help                  使い方の一覧
  dev help <サブコマンド>    ls / up / attach / supervise / rebuild / doctor /
                            restart / stop / logs / enable / disable / exec / self-update の説明

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
未登録の名前の拒否・設定ファイルの誤り・`rebuild` / `restart` / `stop` / `exec` / `doctor` / `self-update` の振る舞い・ユニットの要の行を見ます。
加えて、上の「コマンドの説明」の各ブロックが `dev help` の出力と一致すること、載せたサブコマンドの集合が
`dev` の受け付ける集合と一致することを照合します（説明の 1 行を書き換えた複製では落ちることも確かめます）。偽物を本物に合わせたところは `selftest.sh` の冒頭にあります。
`dev doctor` が読む /proc と cgroup の根は、環境変数 `DEV_PROC_ROOT` / `DEV_CGROUP_ROOT` で差し替えられます
（自己試験が偽の木を渡すためで、既定は本物の `/proc` と `/sys/fs/cgroup` です）。
`dev self-update` の置き換え先は環境変数 `DEV_SELF_PATH` で差し替えられます（自己試験が、偽の `curl` と
一時ディレクトリの偽の `dev` に対して回すためで、既定は実行中の `dev.sh` 自身です）。
