# runner.Dockerfile — GitHub Actions の自前のランナーのイメージ（dev runner build が作る）。
#
# 公式のランナーのイメージ（版を固定）に、配るワークフローが使う道具を足す。外部の機械の上で
# `dev runner build` がビルドする（標準入力から読むので、ビルドの文脈（コンテキスト）は無い。
# 設定ディレクトリの PAT のファイルなどが、イメージへ入る道は無い）。COPY / ADD は書けない。
#
# ## 版を固定する理由
#
# ランナーの自動更新は、コンテナが使い捨てなので効かない（起動のたびに古い版へ戻る）。
# 一方、古すぎる版は GitHub が受け付けなくなる。したがって版は固定し、上げるのは手で行う。
# **このファイルは利用者が編集しない**（install.sh が配布の版で上書きする）。版を上げるには、
# 設定ファイル runners の `runner_version=X.Y.Z` か環境変数 DEV_RUNNER_VERSION を指定して
# `dev runner build` をやり直し（--build-arg で渡す。未指定ならここの既定値）、ユニットを起こし直す。
#
# ## Docker の CLI は足さない
#
# 公式のランナーのイメージは、docker の CLI と buildx を最初から持つ（公式の images/Dockerfile が
# docker の静的バイナリと docker-buildx を取り込み、runner ユーザーを docker グループへ入れる。v2.338.0 で確認）。
# 足すと二重になるので、Docker の apt リポジトリは追加しない。ホストのソケットを渡す設定（docker=yes）のジョブだけが使う。
#
# ## 入れる道具
#
# 【配るワークフローに要るもの】一覧の根拠は、devcontainer-bootstrap の README の
# 「配るワークフローの実行先（ACTIONS_RUNS_ON）」(配るワークフローが自前のランナーに要求する道具の確定版)。
#   - bash: 全ワークフローの run: と全スクリプト
#   - git: actions/checkout、verify-commit-identity.sh とその selftest、check-no-secrets.sh
#   - gh: copilot-review / review-gate / second-opinion-gate の gh api（--jq は gh に内蔵なので jq は要らない）
#   - GNU coreutils 相当: date -u -d、base64 -d、tr、mktemp、sort、comm など（BusyBox の date は不可）
#   - sed、grep
# 公式のイメージ(ubuntu ベース)が最初から持つのは bash・GNU coreutils・sed・grep・git で、足すのは gh だけ。
# (配るワークフローの外で足す道具は、下の【展開の道具】と【node】。外部の apt リポジトリは GitHub CLI と NodeSource の 2 つ)
#
# 【利用側の acceptance.sh のために入れておくもの】配るワークフローには要らない。利用側の acceptance.sh
# (プロジェクトが所有し、言語や検査で道具が変わる)が使うことが多いので残す: jq・shellcheck・curl・unzip・gawk。
# このうち jq・curl・unzip は公式のイメージにもある。ここでの明示は、公式のイメージが外したときに困らないための保険。
#
# 【展開の道具】xz-utils・zstd・bzip2。GitHub がホストするランナーには最初からあり、公式のランナーのイメージには無い。
# 無いと、ワークフローが道具を .tar.xz / .tar.zst / .tar.bz2 で落として展開する段（curl ... | tar -xJ など）が、
# 自前のランナーでだけ「xz: Cannot exec」で落ちる。zstd は actions/cache も使う（無いと gzip に落ちて遅くなる）。
# 【node】PATH 上の node。GitHub がホストするランナーにはあり、公式のランナーのイメージには無い（同梱の node は
# /home/runner/externals にあるだけで PATH に無い）。無いと、node のシバンを持つ道具や run: から呼ぶ node が、自前のランナーでだけ
# 「env: 'node': No such file or directory」（終了コード 127）で落ちる（例: hashicorp/setup-terraform の既定のラッパー）。
# uses: の JS アクションは同梱の node で動くので影響を受けない。NodeSource の署名つき apt リポジトリ（node_24.x）から入れる。
# 系列は 24.x に固定し、パッチはビルドのたびに追従する。
# 足りない道具は、この Dockerfile を編集せず、利用側で用意する(編集は install.sh の更新で上書きされる)。
ARG RUNNER_VERSION=2.338.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

USER root
# 配るワークフローに要るもの: git（公式にもある。明示）と gh（下で公式の apt リポジトリから足す）
# 利用側の acceptance.sh のために入れておくもの: jq・shellcheck・curl・unzip・gawk（ca-certificates は gh と node の取得に、gnupg は apt の署名の検証に使う）
# 展開の道具: xz-utils・zstd・bzip2
# node: nodejs（NodeSource の公式の鍵だけを signed-by で信頼する）
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bzip2 ca-certificates curl gawk git gnupg jq shellcheck unzip xz-utils zstd \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /etc/apt/keyrings/nodesource.asc \
    && chmod go+r /etc/apt/keyrings/nodesource.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_24.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh nodejs \
    && rm -rf /var/lib/apt/lists/*

USER runner
