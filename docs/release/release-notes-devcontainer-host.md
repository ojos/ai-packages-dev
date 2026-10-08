# devcontainer-host Release Notes

devhost（SSH で届く外部の機械で devcontainer を保つ道具。コマンド `dev`、systemd のユニット `dev-up@`）のリリースノートです。

> このファイルは公開リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。
>
> 同じ理由で、issue 参照は `ojos/ai-packages-dev#NNN` の形で書いてください。裸の `#NNN` は GitHub のオートリンクが**配布先リポジトリの issue** として解決するため、配布後は存在しない issue や無関係な issue を指します。

## v0.1.0

### Summary
- **devhost を、devcontainer-bootstrap（DCB）のリリースへの同梱から独立させ、このリポジトリ（`ojos/devcontainer-host`）のリリースで配る**（ojos/ai-packages-dev#486）。最初の版は v0.1.0 を予定している。以前は DCB の `PACKAGE_ARCHIVE.tar.gz` の `devhost/` に入っていた（DCB v0.14.0 以降）。
- **リリースの資産は DCB と同じ形**: `RELEASE-MANIFEST.json`・`SHA256SUMS`・`PACKAGE_ARCHIVE.tar.gz`（このリポジトリのツリー一式）に加えて、**`dev.sh`・`dev-up@.service`・`install.sh`・`projects.example` を個別の資産**として添付する。`SHA256SUMS` と `RELEASE-MANIFEST.json` の `checksums` が、この 4 つのハッシュを持つ。`SHA256SUMS` は `PACKAGE_ARCHIVE.tar.gz` のハッシュも持ち、artifact attestation が付く（attestation の検証が通れば、アーカイブまで辿れる）。
- **`dev version`（`dev --version` も同じ）で dev の版を出せる**。公開した版の値は、リリースの手順が `dev.sh` へ書き込む。
- **`dev self-update` の取得先を、このリポジトリのリリースにした**。マニフェストの `checksums["dev.sh"]` と照合した `dev.sh` を直接取得して置き換える（アーカイブを取って取り出す方式はやめた）。置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の `dev.sh` の形でないときと、照合が合わないときは、何も置き換えずに止まる。`dev.sh` の 2 行目の接頭辞 `# dev — ` は、これまでと同じく版をまたいで変えない約束。
- **外部の機械へ 1 コマンドで入れるインストーラー `install.sh` を、個別の資産として添付する**（ojos/ai-packages-dev#495）。取得したら、README の手順でマニフェストの `checksums["install.sh"]` と照合してから実行する（`curl | bash` は勧めない。照合を挟めないため）。同じ版の `dev.sh`・`dev-up@.service`・`projects.example` を取得してマニフェストと照合し、1 つでも食い違えば何も置かずに非 0 で止まる。通れば、`dev` を `~/.local/bin/dev` へ写しで置き（置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の `dev.sh` でないときは止まる）、ユニットを `~/.config/systemd/user/` へ置いて `systemctl --user daemon-reload` を呼び、`~/.config/dev/projects` が無ければ雛形から作る（あれば上書きしない）。devcontainer CLI・docker・systemd の不足と、`loginctl enable-linger`・プロジェクトごとの `enable --now` は案内だけで、自動では行わない。`--version` で版を指定でき、`--dry-run` は何も書かず計画だけを出す。再実行は冪等で、新しい版なら `dev` とユニットのファイルを更新する。
- **`dev self-update` が、ユニットのファイルの更新を案内する**（ojos/ai-packages-dev#495）。`dev.sh` を置き換えたあと、置いてある `~/.config/systemd/user/dev-up@.service` を、同じリリースのマニフェストの `checksums["dev-up@.service"]` と比べ、違えば `install.sh` の再実行を案内する（ユニットは書き換えない）。また、動いているユニットは起こし直すまで古い `dev` のまま動き続けることと、起こし直す手段（`dev restart <名前>`、または `systemctl --user restart dev-up@<名前>.service`）を案内する。版を上げるときに動くのは手元の古い版の `self-update` なので、最初の版から入れている。

### 移行（DCB に同梱されていた古い `dev` を使っている場合）
- 古い `dev` の `dev self-update` は、取得先が DCB のリリースです。DCB が同梱をやめた版からは、更新できず、何も置き換えずに止まります（終了コード 1）。
- **手で 1 度だけ入れ直してください。** README の「devhost を入手する」の手順で取得して、`dev.sh` を `~/.local/bin/dev` へ置き直します。以降の `dev self-update` はこのリポジトリのリリースから更新できます。`dev version` が版を出せば、移り終えています。
