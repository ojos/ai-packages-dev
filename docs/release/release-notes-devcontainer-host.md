# devcontainer-host Release Notes

devhost（SSH で届く外部の機械で devcontainer を保つ道具。コマンド `dev`、systemd のユニット `dev-up@`）のリリースノートです。

> このファイルは公開リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。
>
> 同じ理由で、issue 参照は `ojos/ai-packages-dev#NNN` の形で書いてください。裸の `#NNN` は GitHub のオートリンクが**配布先リポジトリの issue** として解決するため、配布後は存在しない issue や無関係な issue を指します。

## v0.1.0

### Summary
- **devhost を、devcontainer-bootstrap（DCB）のリリースへの同梱から独立させ、このリポジトリ（`ojos/devcontainer-host`）のリリースで配る**（ojos/ai-packages-dev#486）。最初の版は v0.1.0 を予定している。以前は DCB の `PACKAGE_ARCHIVE.tar.gz` の `devhost/` に入っていた（DCB v0.14.0 以降）。
- **リリースの資産は DCB と同じ形**: `RELEASE-MANIFEST.json`・`SHA256SUMS`・`PACKAGE_ARCHIVE.tar.gz`（このリポジトリのツリー一式）に加えて、**`dev.sh` と `dev-up@.service` を個別の資産**として添付する。`SHA256SUMS` と `RELEASE-MANIFEST.json` の `checksums` が、この 2 つのハッシュを持つ。`SHA256SUMS` は `PACKAGE_ARCHIVE.tar.gz` のハッシュも持ち、artifact attestation が付く（attestation の検証が通れば、アーカイブまで辿れる）。
- **`dev version`（`dev --version` も同じ）で dev の版を出せる**。公開した版の値は、リリースの手順が `dev.sh` へ書き込む。
- **`dev self-update` の取得先を、このリポジトリのリリースにした**。マニフェストの `checksums["dev.sh"]` と照合した `dev.sh` を直接取得して置き換える（アーカイブを取って取り出す方式はやめた）。置き換え先がリンク・git の作業ツリーの中・devhost の `dev.sh` の形でないときと、照合が合わないときは、何も置き換えずに止まる。`dev.sh` の 2 行目の接頭辞 `# dev — ` は、これまでと同じく版をまたいで変えない約束。

### 移行（DCB に同梱されていた古い `dev` を使っている場合）
- 古い `dev` の `dev self-update` は、取得先が DCB のリリースです。DCB が同梱をやめた版からは、更新できず、何も置き換えずに止まります（終了コード 1）。
- **手で 1 度だけ入れ直してください。** README の「devhost を入手する」の手順で取得して、`dev.sh` を `~/.local/bin/dev` へ置き直します。以降の `dev self-update` はこのリポジトリのリリースから更新できます。`dev version` が版を出せば、移り終えています。
