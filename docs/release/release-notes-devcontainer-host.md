# devcontainer-host Release Notes

devhost（SSH で届く外部の機械で devcontainer を保つ道具。コマンド `dev`、systemd のユニット `dev-up@`）のリリースノートです。

> このファイルは公開リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。
>
> 同じ理由で、issue 参照は `ojos/ai-packages-dev#NNN` の形で書いてください。裸の `#NNN` は GitHub のオートリンクが**配布先リポジトリの issue** として解決するため、配布後は存在しない issue や無関係な issue を指します。

## 次の版（未リリース）

### Summary
- **自前のランナーの登録先のランナーグループを、`runners` の `group=<名前>` で指定できるようにした**（ojos/ai-packages-dev#576）。組織単位で登録したランナーは、グループを指定しないと組織の既定のグループに入り、組織のどの非公開のリポジトリでも `runs-on` にラベルを書けば外部の機械でコードを走らせられる。**ラベルは安全の境界にならず、使えるリポジトリを絞るのはグループ。**
  - `group=` を書いた行だけ、`config.sh` に `--runnergroup <名前>` を渡す。名前に使えるのは英数字と `.` `_` `-` だけ（それ以外は設定の誤りで、終了コード 2）。書かない行の動きは変わらない。
  - `dev runner run` は、コンテナを起こす前に組織のランナーグループの一覧で有無を確かめる。無いとき、と一覧を読む権限が無いとき（401 / 403 / 404）は 78 で終わり（ユニットは起こし直さない）、API の 429・5xx や通信の失敗は 1（起こし直す）。登録の時点でグループが消えていた場合（`config.sh` が「Could not find any self-hosted runner group named」で失敗したとき）も 78。それ以外の `config.sh` の失敗は 1。既定のグループへは黙って入らない。
  - `dev doctor --runner <名前>` が、`group=` を書いたランナーについて組織のランナーグループの一覧を引き、あれば OK、無ければ FAIL、読めなければ WARN にする。PAT の値は出さない。
  - グループの作成と、使えるリポジトリの設定は GitHub 側（利用側の組織）で行う。`dev` は作らない。

### 移行
- `dev self-update` で `dev.sh` を更新する。`group=` を書かない既存の `runners` は、そのまま動く。グループを使うには、GitHub 側でグループを作ってから、`runners` に `group=<名前>` を足してユニットを起こし直す。

## v0.2.0

### Summary
- **外部の機械で GitHub Actions の自前のランナーを、ジョブごとに使い捨てのコンテナとして常駐させる**（ojos/ai-packages-dev#547）。private リポジトリの CI を、GitHub がホストするランナーの課金枠を使わずに回すため。
  - 新しいファイル: ユニット `dev-runner@.service`、ランナーのイメージの `runner.Dockerfile`（公式のランナーのイメージを版を固定して使い、gh を足す。入れる道具は、devcontainer-bootstrap v0.20.0 の README「配るワークフローの実行先（`ACTIONS_RUNS_ON`）」の一覧（ojos/ai-packages-dev#546）を満たす）、設定ファイルの雛形 `runners.example`。いずれも個別の資産として添付され、`SHA256SUMS` とマニフェストの `checksums` の対象になる。
  - `dev runner build` がイメージを外部の機械の上で作り、`dev runner run <名前>`（ユニットの ExecStart）が、(1) PAT で組織の登録用のトークンを取得し、(2) `--ephemeral` のランナーを `--rm` のコンテナで動かし、(3) ジョブが 1 つ終わってコンテナが止まったら抜ける（ユニットが新しいコンテナで起こし直す）。並列数は、名前を変えたインスタンスを増やして上げる。ユニットを止めると、コンテナを止めて、登録中のランナーを組織から外す。
  - 設定ファイル `${XDG_CONFIG_HOME:-~/.config}/dev/runners`（名前 → 組織・ラベル・Docker を渡すか）。PAT は別のファイルに置き、group / other に権限があれば（644 など）起動を拒む（600 や 400 は通す）。PAT は fine-grained で、組織の「Self-hosted runners: Read and write」だけを持たせる。PAT はコマンドラインの引数・コンテナの環境変数・ログに出さず、コンテナへは登録用のトークン（1 時間で切れる）だけを渡す。
  - **Docker のソケットは、設定で `docker=yes` にしたランナーにだけ渡す（既定は渡さない）。渡すと、ジョブがホストの Docker を自由に操作できる。外部からの PR を受けるリポジトリでは使わない。**
  - `dev doctor --runner <名前>` で、イメージの有無・PAT ファイルの権限・ユニットの状態を点検できる。
  - `install.sh` が、追加した 3 つのファイルを取得してマニフェストと照合し（1 つでも外れたら何も置かない）、ユニットと Dockerfile を置いて、`runners` が無ければ雛形から作る（あれば上書きしない）。`dev self-update` は、置いてあるランナーのユニット・Dockerfile がリリースと違うとき、`install.sh` の再実行を案内する（書き換えない）。

- リリースの資産に `dev-runner@.service`・`runner.Dockerfile`・`runners.example` が加わり、個別の資産は 7 つになった。`SHA256SUMS` と `RELEASE-MANIFEST.json` の `checksums` も、この 7 つのハッシュを持つ。

### 移行
- `dev self-update` で `dev.sh` を更新したうえで、ランナーを使う外部の機械では `install.sh` をもう一度実行し、`dev-runner@.service`・`runner.Dockerfile`・`runners`（無いときだけ）を置く。`dev self-update` はユニットと Dockerfile の差を案内するだけで、書き換えない。
- ランナーを使わない場合は、`dev.sh` の更新だけで足りる。既存の `dev-up@` の動きは変わらない。

## v0.1.0

### Summary
- **devhost を、devcontainer-bootstrap（DCB）のリリースへの同梱から独立させ、このリポジトリ（`ojos/devcontainer-host`）のリリースで配る**（ojos/ai-packages-dev#486）。この版が最初の版。以前は DCB の `PACKAGE_ARCHIVE.tar.gz` の `devhost/` に入っていた（DCB v0.14.0 以降）。
- **リリースの資産は DCB と同じ形**: `RELEASE-MANIFEST.json`・`SHA256SUMS`・`PACKAGE_ARCHIVE.tar.gz`（このリポジトリのツリー一式）に加えて、**`dev.sh`・`dev-up@.service`・`install.sh`・`projects.example` を個別の資産**として添付する。`SHA256SUMS` と `RELEASE-MANIFEST.json` の `checksums` が、この 4 つのハッシュを持つ。`SHA256SUMS` は `PACKAGE_ARCHIVE.tar.gz` のハッシュも持ち、artifact attestation が付く（attestation の検証が通れば、アーカイブまで辿れる。ojos/ai-packages-dev#491）。
- **`dev` に restart / stop / logs / enable / disable / exec を足した**（ojos/ai-packages-dev#482。DCB v0.17.0 に同梱されていた `dev` から新しく増えたサブコマンド）。`dev restart` は作り直さずに起こし直す（ユニットが動いていれば先に止め、止めたときだけ起こし直す）。`dev stop` はユニットを止めてからコンテナを止める（compose のプロジェクト全体。再起動の後は戻る）。`dev enable` / `dev disable` はユニットの有効・無効（`disable` はコンテナも止める。戻すのは `dev enable`）。`dev logs` はユニットのログ、`dev exec` は tmux を介さずにコンテナの中でコマンドを 1 つ実行する。
- **`dev version`（`dev --version` も同じ）で dev の版を出せる**。公開した版の値は、リリースの手順が `dev.sh` へ書き込む。
- **`dev self-update` の取得先を、このリポジトリのリリースにした**。マニフェストの `checksums["dev.sh"]` と照合した `dev.sh` を直接取得して置き換える（アーカイブを取って取り出す方式はやめた）。置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の `dev.sh` の形でないときと、照合が合わないときは、何も置き換えずに止まる。`dev.sh` の 2 行目の接頭辞 `# dev — ` は、これまでと同じく版をまたいで変えない約束。
- **外部の機械へ 1 コマンドで入れるインストーラー `install.sh` を、個別の資産として添付する**（ojos/ai-packages-dev#495）。取得したら、README の手順でマニフェストの `checksums["install.sh"]` と照合してから実行する（`curl | bash` は勧めない。照合を挟めないため）。同じ版の `dev.sh`・`dev-up@.service`・`projects.example` を取得してマニフェストと照合し、1 つでも食い違えば何も置かずに非 0 で止まる。通れば、`dev` を `~/.local/bin/dev` へ写しで置き（置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の `dev.sh` でないときは止まる）、ユニットを `~/.config/systemd/user/` へ置いて `systemctl --user daemon-reload` を呼び、`~/.config/dev/projects` が無ければ雛形から作る（あれば上書きしない）。devcontainer CLI・docker・systemd の不足と、`loginctl enable-linger`・プロジェクトごとの `enable --now` は案内だけで、自動では行わない。`--version` で版を指定でき、`--dry-run` は何も書かず計画だけを出す。再実行は冪等で、新しい版なら `dev` とユニットのファイルを更新する。
- **`dev self-update` が、ユニットのファイルの更新を案内する**（ojos/ai-packages-dev#495）。`dev.sh` を置き換えたあと、置いてある `~/.config/systemd/user/dev-up@.service` を、同じリリースのマニフェストの `checksums["dev-up@.service"]` と比べ、違えば `install.sh` の再実行を案内する（ユニットは書き換えない）。また、動いているユニットは起こし直すまで古い `dev` のまま動き続けることと、起こし直す手段（`dev restart <名前>`、または `systemctl --user restart dev-up@<名前>.service`）を案内する。版を上げるときに動くのは手元の古い版の `self-update` なので、最初の版から入れている。
- **単体でも、DCB と組み合わせても使える**（ojos/ai-packages-dev#494）。`devcontainer.json` を持つプロジェクトなら、DCB の生成物でなくても使える。前提として、**コンテナの中に tmux が要る**（`dev attach` と `dev ls` の TMUX の列が使う）。DCB の生成物には、tmux・compose の `init: true`・codex のサンドボックスの設定（`--with-codex` のとき）・UID の合わせ込みが最初から入っていて、devhost の前提が揃う。README の「DCB と一緒に使うと揃うもの」と「3 パッケージの関係」に書いた。

### 移行（DCB に同梱されていた古い `dev` を使っている場合）
- 古い `dev` の `dev self-update` は、取得先が DCB のリリースです。DCB が同梱をやめた版からは、更新できず、何も置き換えずに止まります（終了コード 1）。
- **手で 1 度だけ入れ直してください。** README の「devhost を入手する」の手順で取得して、`dev.sh` を `~/.local/bin/dev` へ置き直します。以降の `dev self-update` はこのリポジトリのリリースから更新できます。`dev version` が版を出せば、移り終えています。
