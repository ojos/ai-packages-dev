# devcontainer-host Release Notes

devhost（SSH で届く外部の機械で devcontainer を保つ道具。コマンド `dev`、systemd のユニット `dev-up@`）のリリースノートです。

> このファイルは公開リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。
>
> 同じ理由で、issue 参照は `ojos/ai-packages-dev#NNN` の形で書いてください。裸の `#NNN` は GitHub のオートリンクが**配布先リポジトリの issue** として解決するため、配布後は存在しない issue や無関係な issue を指します。

## v0.5.1

### Summary
- **`dev doctor --runner <名前>` が、止まっている route のユニットを見逃していたのを直した**（ojos/ai-packages-dev#648）。`dev-route@<ラベル>`（または `dev-route-sync@<ラベル>.timer`）を有効にしたのに `~/.config/dev/routes` が無い（またはそのラベルの行が無い）と、ユニットは設定の誤りで止まるのに、doctor は route の行を 1 つも出さずに「判定: OK」を返していた。
  - そのランナーのラベルについて、route のユニットが有効（enabled・enabled-runtime などの `systemctl is-enabled` が真、または active・activating・failed）なのに、routes が無い・そのラベルの行が無いときは FAIL にする。直し方として、「routes に行を書いてユニットを起こし直す」か、「先に行を戻してから `disable --now` で変数を戻す（戻せなければ `gh variable set` で手で戻す）」を示す。
  - どのランナーの `labels=` にも無いラベルの route のユニットが有効なまま残っていれば、WARN で知らせる。
  - route のユニットがどれも有効でない機械では、今のとおり何も出さない。
- 手で行う移行の作業は無い（`dev self-update` か `install.sh` で追従する）。

## v0.5.0

### Summary
- **自前のランナーが動けるあいだだけ、Actions 変数 `ACTIONS_RUNS_ON` をランナーのラベルへ向け、動けないときは `ubuntu-latest` へ戻す機能を足した**（ojos/ai-packages-dev#621）。自前のランナーが止まっていると、`runs-on` がそのラベルを指すジョブは待ちのまま止まり続け、Actions には別のランナーへ自動で切り替える仕組みがないため、ワークフローが読む変数をランナーの機械の側から書き換える。
  - `dev runner route up|down|sync|show <ラベル>` を足した。対象は、設定ファイル `routes`（雛形 `routes.example`。1 行 =「ラベル 組織 group=<名前> [pat_file=<絶対パス>]」）で指すランナーグループの「使えるリポジトリ」（`selected` でなければ設定の誤り）。違うときだけ書き（冪等）、リポジトリごとに並列で書き、失敗した分だけやり直す。「動いている」の判定は、そのラベルを持つランナーが 1 台以上 `online` か。
  - ユニット `dev-route@.service`（起動で `up`、`ExecStopPost` で `down`）と、そろえ直しの `dev-route-sync@.service` / `dev-route-sync@.timer`（起動の 3 分後から 10 分おき。起動・停止のユニットが active のときだけ書く）を足した。
  - グループを読めないとき、キャッシュを使うのは `ubuntu-latest` へ戻す方向だけ。グループから外したリポジトリは、今の値がこのラベルなら `ubuntu-latest` へ戻す（別の値は触らない）。キャッシュは組織とラベルの組ごと。「動いている」はグループのランナーで数え、停止のとき、ほかの機械（`runners` の名前と完全一致しないもの）の同じラベルのランナーが `online` なら戻さない。そろえ直しは、居ないと判定したら 60 秒後に読み直す（ジョブの切れ目で登録し直すあいだを取り違えないため）。停止の上限は 300 秒。
  - PAT はランナーの登録用とは別にする（Variables: Read and write と、組織の Self-hosted runners: Read だけ）。引数にも出力にも出さない。
  - `dev doctor --runner <名前>` が、`routes` にそのランナーのラベルの行があれば、その行の PAT・グループ・ユニットとタイマー・`runners` との一致も点検する。
  - 新しいファイル `dev-route@.service`・`dev-route-sync@.service`・`dev-route-sync@.timer`・`routes.example` は個別の資産として添付され、`install.sh` が置く（`routes` は作らず、雛形を `routes.example` の名前で置く）。`dev self-update` はユニットの差を案内するだけで、書き換えない。
- **`dev runner route` の端のケースを 2 つ塞いだ**（ojos/ai-packages-dev#623）。(1) 対象の一覧をロックの外で読んでから書くまでにグループが変わると、古い一覧で書いていた。ロックを取ったあと（そろえ直しは active の再確認のあと）に読み直し、違えば読み直した一覧で書く。読み直せなければ、起動・そろえ直しは何も書かず 1、停止は今までどおりキャッシュで戻す。online の判定と読み直しの待ちはロックの外のまま。(2) dev-route を持たない版（v0.4.0 以前）を `install.sh` で入れると、置いてある dev-route のユニットが残り、route を知らない古い `dev` で停止の処理が失敗して変数をラベルに残していた。`install.sh` は、そのような版を入れるとき `dev-route@*.service` か `dev-route-sync@*.timer` が enabled か、動作中（停止の途中を含む）なら、何も置かずに非 0 で止まり、先に `systemctl --user disable --now dev-route@<ラベル>.service dev-route-sync@<ラベル>.timer` で止める手順を案内する（`systemctl` の一覧に加えて `*.wants/` の有効のリンクも見る。dev-route のユニットのファイルがあるのに `systemctl --user` に問い合わせられないときも止まる。迂回のオプションは無い）。
- **`dev up` / `dev attach` が、端末が付いているときだけ、devhost の新しい安定版を知らせ、yes なら `install.sh` で追従するようにした**（ojos/ai-packages-dev#626）。古い版のまま気づかずに使い続けないため。標準入力・標準出力・標準エラーのすべてが端末のときだけ、GitHub の最新の安定版（プレリリースを除く。認証なしの公開 API を数秒のタイムアウトで 1 回）と `dev` の版を比べ、新しければ今の版と最新の版を示して「追従しますか？ [y/N]」と聞く。配布先の `CHANGELOG.md`（最新の版のもの）を読み、今の版の次から最新の版までに移行の節を持つ版があれば、その版を挙げて目立たせる（公開しているリリースの本文はリリースノートを含まないため。読み取れなければ、判定できないと伝えてリリースノートへ案内する）。追従するのは `~/.local/bin/dev` から動いている `dev` だけ（`install.sh` がそこへ置くため）。y なら、最新の `RELEASE-MANIFEST.json` と `install.sh` を取得し、`install.sh` のハッシュを照合してから `bash install.sh --version <最新の版>` を実行する（残りの資産は `install.sh` が照合する）。動いているユニットの起こし直し（`dev restart`・`dev runner build`・`systemctl --user restart`）は案内だけで、今回の `up` / `attach` は更新前の `dev` のまま続ける。
  - 問い合わせは 1 日 1 回（失敗した日も 1 回に数える）。N と答えた版は、その版のあいだ聞かない。記録は `~/.cache/dev/update-check`（`XDG_CACHE_HOME` があればその下）。オフライン・API の失敗は黙って通す。端末が付いていない呼び出し（`dev supervise`・systemd のユニット・スクリプト・AI エージェント）では、何も聞かず、何も出さず、何も取得しない。
  - 既定で有効。止めるには、環境変数 `DEV_UPDATE_CHECK=off`、または `~/.config/dev/update-check`（`XDG_CONFIG_HOME` があればその下）に `off` と 1 行書く（環境変数が優先する）。

### 移行

- 自前のランナーを使う機械で、この機能を使うなら、`install.sh` をもう一度実行してユニットと雛形を置く。**導入の順序がある**（README の「自前のランナー」の「変数の切り替え」）: 変数を先に `ubuntu-latest` へ逃がし、ランナーのラベルと `group=` を設定して起こし直し、`routes` と PAT を置いて `dev runner route show` で読めるか確かめてから、`dev-route@<ラベル>` とタイマーを有効にする。逆にすると、変数が指すラベルのランナーがまだ居ないので、ジョブが待ちのまま止まる。
- 使わない機械では、何も変わらない（`routes` が無ければ、`dev doctor --runner` も route の点検を出さない）。
- 機械そのものが止まったとき（停電・回線断）は、この機能では戻せない。
- 利用側の runner-route（`runner-route@<ラベル>`）から移るときは、古いユニットを止めて（変数が `ubuntu-latest` に戻る）から、`dev-route@<ラベル>` とタイマーを有効にする。PAT は `routes` の `pat_file=` で今のファイルを指せる。
- この版から、`dev up` / `dev attach` が新しい版を知らせる（端末が付いているときだけ。1 日 1 回）。止めるには `DEV_UPDATE_CHECK=off` か `~/.config/dev/update-check` に `off`。

## v0.4.0

### Summary
- **自前のランナーのイメージに、展開の道具 `xz-utils`・`zstd`・`bzip2` を足した**（ojos/ai-packages-dev#603）。GitHub がホストするランナーにはあり、公式のランナーのイメージには無い道具で、無いとワークフローが道具を `.tar.xz` などで落として展開する段（`curl ... | tar -xJ` など）が、自前のランナーでだけ `xz: Cannot exec` で落ちていた。`zstd` は actions/cache も使う（無いと gzip に落ちる）。README の「イメージ」に apt で入れるものの一覧を置き、`selftest.sh` が `runner.Dockerfile` の一覧と照合するようにした。**適用には `install.sh` で更新したあと、`dev runner build` でイメージを作り直し、ランナーのユニットを起こし直す。**
- **`dev doctor --runner <名前>` が、ランナーの版の期限を点検するようにした**（ojos/ai-packages-dev#604）。自動更新を止めた自前のランナーは、新しい版が出てから 30 日を過ぎると GitHub からジョブを渡されなくなり、ユニットは動いたままジョブが待ち続ける。doctor はイメージのラベルの版を actions/runner の公開済みの版（プレリリースと下書きを除く。PAT は要らない）と比べ、新しい版なしは OK、期限内は WARN（期限の日付と残りの日数）、期限切れは FAIL、一覧を読めない・ラベル無しは WARN にする。これに合わせて `dev runner build` は、版を必ず確定させ（`DEV_RUNNER_VERSION` > `runners` の `runner_version=` > Dockerfile の既定値）、`--build-arg` とイメージのラベル（`devhost.runner-version`）の両方へ渡す。**既存のイメージはラベルを持たないので、更新後に `dev runner build` で作り直す。** 点検は自動では走らないので、定期に打つ。
- **`dev.sh` と `selftest.sh` が、既定の重大度の shellcheck を通るようにした**（ojos/ai-packages-dev#589 / ojos/ai-packages-dev#590）。`dev.sh` は、ランナーの一覧を読むループの中で求めていた設定の置き場所（`dirname`）を、ループの前で求めるようにした（SC2094 の誤検出。挙動は変わらない）。`selftest.sh` の 13 件は意図した書き方なので、理由を書いて抑止した。開発リポジトリの CI で、配布する `.sh` の全体を既定の重大度の shellcheck に掛けるようにした。

### 移行

- **自前のランナーを使っている場合は、更新後に `dev runner build` でイメージを作り直し、ランナーのユニットを起こし直す**（`systemctl --user restart dev-runner@<名前>.service`）。作り直すまでは、イメージに展開の道具が入らず、`dev doctor --runner` は「版のラベルがありません」の WARN を出す。
- 版の点検は `dev doctor --runner <名前>` を打ったときだけ行う（自動では走らない）。定期に（たとえば週に 1 回）打ち、WARN のうちに `runners` の `runner_version=` を上げる。

## v0.3.0

### Summary
- **自前のランナー（`docker=no`）を専用の Docker ネットワークで動かし、外部の機械の LAN・外部の機械自身・リンクローカルへの出口を止めるようにした**（ojos/ai-packages-dev#560 / ojos/ai-packages-dev#572）。インターネット（GitHub、パッケージの取得）への出口は残す。
  - `dev runner run` は、ランナー専用のネットワーク `dev-runner`（ブリッジ名 `dev-runner0`、IPv6 は無効）が無ければ作り、そこでコンテナを動かす。既存のネットワークのブリッジ名か IPv6 の設定が違えば、設定の誤り（78）で止まる。
  - 規則は root で入れる。`dev runner net script` が規則のスクリプト（`/usr/local/sbin/dev-runner-net`。`apply` / `clear` / `rules` / `unmark`）を、`dev runner net unit` が systemd のシステムのユニット（`dev-runner-net.service`）を標準出力へ出すので、利用者が `sudo` で入れる。規則は iptables で、`DOCKER-USER` から `10/8`・`172.16/12`・`192.168/16`・`169.254/16`・`100.64/10` への新しい接続を拒否し、`INPUT` でランナーのブリッジから外部の機械自身への新しい接続を拒否する。入れ直しは 1 回の取り込みで行い、制限の無い瞬間を作らない。
  - ユニットは Docker の起動・再起動に合わせて規則を入れ直し、入れ終えたら印（`/run/dev-runner-net/ready`）を置く。停止のときは印だけを消し、規則は消さない。規則を外すのは、利用者が `dev-runner-net clear` を打つときだけ。
  - **`dev runner run` は、印が無ければコンテナを起こさない**（登録用のトークンを取る前に確かめる）。印が無ければ一時的な失敗（1）で抜け、systemd が起こし直す。印の中身が違えば 78。
  - `runners` に `lan=allow|deny` を足した（既定は `deny`）。`lan=allow` のランナーは、従来どおり既定のブリッジで動き、印も確かめない。
  - 上流の DNS が LAN の帯にある構成のために、`/etc/default/dev-runner-net` の `DEV_RUNNER_NET_ALLOW_DNS` で、指定した宛先の 53 番だけを通せる。既定では何も通さない。
  - 限界:
    - `docker=yes` のランナーには効かない（ホストの Docker のソケットを渡しているので、ジョブは `--network host` のコンテナを起こして規則を迂回できる）。
    - 印は「規則を入れた」ことを示すだけで、規則が今も効いていることまでは保証しない。
    - Docker が iptables を使わない構成（nftables のバックエンド、`--iptables=false`）では使えない（`FORWARD` から `DOCKER-USER` への飛び先が無ければ、印を置かずに失敗する）。
- **README の codex のサンドボックスの緩和の置き場所を、`devcontainer.json` の `securityOpt` に直した**（ojos/ai-packages-dev#543 / ojos/ai-packages-dev#573）。devcontainer-bootstrap の `--with-codex` が置き場所を移したのに合わせた。`compose.yaml` の `security_opt` には置かない（go などの feature が同じ値を足すと、Compose が重複を拒否して起動しないため）。
- **自前のランナーの登録先のランナーグループを、`runners` の `group=<名前>` で指定できるようにした**（ojos/ai-packages-dev#576）。組織単位で登録したランナーは、グループを指定しないと組織の既定のグループに入り、組織のどの非公開のリポジトリでも `runs-on` にラベルを書けば外部の機械でコードを走らせられる。**ラベルは安全の境界にならず、使えるリポジトリを絞るのはグループ。**
  - `group=` を書いた行だけ、`config.sh` に `--runnergroup <名前>` を渡す。名前に使えるのは英数字と `.` `_` `-` だけ（それ以外は設定の誤りで、終了コード 2）。書かない行の動きは変わらない。
  - `dev runner run` は、コンテナを起こす前に組織のランナーグループの一覧で有無を確かめる。無いとき、と一覧を読む権限が無いとき（401 / 403 / 404）は 78 で終わり（ユニットは起こし直さない）、API の 429・5xx や通信の失敗は 1（起こし直す）。登録の時点でグループが消えていた場合（`config.sh` が「Could not find any self-hosted runner group named」で失敗したとき）も 78。それ以外の `config.sh` の失敗は 1。既定のグループへは黙って入らない。
  - `dev doctor --runner <名前>` が、`group=` を書いたランナーについて組織のランナーグループの一覧を引き、あれば OK、無ければ FAIL、読めなければ WARN にする。PAT の値は出さない。
  - グループの作成と、使えるリポジトリの設定は GitHub 側（利用側の組織）で行う。`dev` は作らない。

### 移行
- `dev self-update` で `dev.sh` を更新する。`group=` を書かない既存の `runners` は、そのまま動く。グループを使うには、GitHub 側でグループを作ってから、`runners` に `group=<名前>` を足してユニットを起こし直す。
- **`docker=no` の既存のランナー（`lan=` を書いていないものを含む）は、`dev self-update` の後、出口の規則を入れるまで起動しなくなる。** 規則のスクリプトとユニットを入れて有効にする。
  ```bash
  dev runner net script | sudo install -m 755 /dev/stdin /usr/local/sbin/dev-runner-net
  dev runner net unit | sudo install -m 644 /dev/stdin /etc/systemd/system/dev-runner-net.service
  sudo systemctl daemon-reload && sudo systemctl enable --now dev-runner-net.service
  ```
- **LAN に頼るジョブ（LAN のプロキシ、社内のパッケージ置き場など）は、`lan=allow` にしない限り動かなくなる。** 該当するランナーの `runners` の行に `lan=allow` を足して、ユニットを起こし直す。
- ジョブの中で名前が引けなくなった場合（上流の DNS が LAN の帯にある構成）は、`/etc/default/dev-runner-net` に `DEV_RUNNER_NET_ALLOW_DNS` を書いて、`dev-runner-net.service` を起こし直す。

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
