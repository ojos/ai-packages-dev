# セキュリティの報告

このリポジトリと、ここから配布しているパッケージの脆弱性を見つけたときは、**公開の issue ではなく、GitHub の非公開の報告から**知らせてください。

## 報告のしかた

1. このリポジトリの [Security タブ](https://github.com/ojos/ai-packages-dev/security) を開きます。
2. **Report a vulnerability** から報告します。内容は管理者だけが読めます。

書いていただきたいこと:

- 影響を受ける場所（ファイル、配布物の名前とバージョン）
- 再現の手順と、確かめた日時・環境（OS・アーキテクチャ）
- 想定される影響（何ができてしまうか）

**公開の issue・PR・SNS には書かないでください。** 直す前に広まると、利用者が危険にさらされます。

## 対象

- このリポジトリのコードと文書
- ここから公開しているパッケージ: ai-playbook（[ojos/ai-playbook](https://github.com/ojos/ai-playbook)）と DevContainer Bootstrap（[ojos/devcontainer-bootstrap](https://github.com/ojos/devcontainer-bootstrap)）。GitHub Release の資産も含みます。公開先のリポジトリで見つけた場合も、このリポジトリへ知らせてください（公開先は配布用の写しで、正本はここにあります）

対象にしないもの:

- パッケージを導入した利用側のリポジトリや環境に固有の問題（利用側の管理者へ知らせてください）
- 依存している外部の道具（Docker・devcontainer CLI・各 AI ツールなど）そのものの脆弱性（それぞれの提供元へ知らせてください）
- 大量のリクエストやソーシャルエンジニアリングで確かめる試み

## 対応の目安

**受け取ったことの返信は、7 日以内を目安にします。** 直し方と公開の時期は、報告者と相談して決めます。

## In English

Please report vulnerabilities **privately** via [Security → Report a vulnerability](https://github.com/ojos/ai-packages-dev/security), not in public issues. In scope: this repository and the packages published from it (ai-playbook and DevContainer Bootstrap, including their release assets). We aim to acknowledge reports within 7 days.
