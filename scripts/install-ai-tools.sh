#!/usr/bin/env bash
# このリポジトリの開発環境へ AI CLI（claude / gemini / agy / codex）を導入する。
# 引数は取らず、未導入のもの、または版の下限より古いものを無条件に導入する。
# 導入対象を選べる --with-claude / --with-gemini / --with-copilot は、生成物側の
# packages/devcontainer-bootstrap/bootstrap.sh のフラグであり、本スクリプトとは無関係。
set -euo pipefail

# 版の比較。`sort -V` は BSD 系に無い版があるので使わない。3 つの数へ分けて
# 桁ごとに比べる。
#
# 読めない綴りは「古い」として扱う（fail-closed）。入れ替えは冪等で副作用が
# 小さい一方、読めないまま通すと、要件を満たさない CLI で回り続けることになる。
# プレリリースの印（"2.1.314-beta.1" の "-beta.1"）が付いた版は、同じ番号の正式版
# より前のものなので、番号が下限と同じなら「古い」とする。
ai_cli_version_is_old() {
  local have="$1" want="$2"
  awk -v have="$have" -v want="$want" '
    function num(s, part) { split(s, a, "."); return a[part] + 0 }
    BEGIN {
      if (have !~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/) { exit 0 }   # 読めない → 古い扱い
      pre = (have ~ /-/); sub(/-.*$/, "", have)
      for (i = 1; i <= 3; i++) {
        h = num(have, i); w = num(want, i)
        if (h > w) { exit 1 }
        if (h < w) { exit 0 }
      }
      exit pre ? 0 : 1
    }'
}

# CLI の `--version` の出力から、版の綴りを取り出す。出力は CLI ごとに
# "2.1.296 (名前)" や "名前 0.162.1" のように違い、"v1.3.5" や "0.66.0-preview.1"
# の形もありうるので、最初に現れる数の 3 つ組を、プレリリースの印ごと取る
# （前置の v は落とす。印は ai_cli_version_is_old が見る）。
# 取れなければ空を返す（呼び出し側が古い扱いにする）。
ai_cli_version() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' | head -1 || true
}

# npm 配布の CLI を導入する。第 3 引数に版の下限を渡すと、在るときも版を見る。
#
# 下限が無ければ「PATH に在れば飛ばす」だけ。下限があるときは、古い版が先に入って
# いる環境が更新されず黙って残ることを避けるため、下限未満なら @latest で入れ替え、
# 入れたあとも下限未満なら失敗にする。入れ替えるときは、名前・今の版・下限を出す。
install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  local min="${3:-}"
  local have=""
  if command -v "$cmd" >/dev/null 2>&1; then
    if [[ -z "$min" ]]; then
      echo "[install-ai-tools] $cmd already installed, skipping"
      return 0
    fi
    have="$(ai_cli_version "$cmd")"
    if ! ai_cli_version_is_old "$have" "$min"; then
      echo "[install-ai-tools] $cmd ${have} already installed (>= $min), skipping"
      return 0
    fi
    echo "[install-ai-tools] $cmd ${have:-（版を読めません）} は $min 未満です。入れ替えます ..."
  else
    echo "[install-ai-tools] installing $pkg ..."
  fi

  if [[ -z "$min" ]]; then
    npm install -g "$pkg" || return 1
    echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
    return 0
  fi

  # 呼び出し側が `|| ...` で包んでも set -e が効かなくなるので、失敗は明示で返す。
  npm install -g "${pkg}@latest" || return 1
  # 入れ替える前の場所をシェルが覚えていると、古い本体を読み直してしまう。
  hash -r
  have="$(ai_cli_version "$cmd")"
  if ai_cli_version_is_old "$have" "$min"; then
    echo "[install-ai-tools] error: 導入後も $cmd の版が $min 未満です（実際: ${have:-不明}、$(command -v "$cmd" || echo 'PATH に無い')）" >&2
    echo "                   npm の導入先（$(npm prefix -g 2>/dev/null || echo '不明')/bin）より前に別の $cmd があるか、導入先が PATH に無い可能性があります。" >&2
    return 1
  fi
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd") (${have})"
}

# agy（Antigravity CLI）は npm 配布ではないため install_if_missing の同型に乗らない。
# 配布元のインストーラ（curl で取って bash へ渡す形）は実行せず、そのインストーラと
# 同じ手順を自分で行う。マニフェストを取り、本体を落とし、SHA-512 を照合してから
# ~/.local/bin/agy へ置く。照合が通らないものは、何も置かずに失敗にする。
#
# 配布元の URL とマニフェストの形（version・url・sha512 のキー）は、配布元の
# インストーラを読んで確かめたもの。変われば、導入は理由を出して止まる。
#
# 認証は OAuth のみで、API キーには対応しない。導入だけでは使えず、初回に
# 対話で `agy` を起動して Google アカウントへログインする必要がある。資格情報は
# ~/.gemini/antigravity-cli/ 配下に置かれ、この devcontainer では ~/.gemini が
# named volume（gemini-storage）なので rebuild しても消えない。
AGY_MIN_VERSION="1.3.4"
AGY_DOWNLOAD_BASE_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"

# 配布元のインストーラと同じ判定で、プラットフォーム名を標準出力へ返す。
# 配布元が用意する組（下の表）に無いものは、理由を標準エラーへ出して 1 を返す。
agy_platform() {
  local os arch platform
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)
      # Android は Bionic 版が要るが、この導入は対応しない（表に無い）。
      if [[ "$(uname -o 2>/dev/null || true)" == "Android" ]]; then os="android"; else os="linux"; fi
      ;;
    *)
      echo "[install-ai-tools] error: agy が対応しない OS です: $(uname -s)" >&2
      return 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "[install-ai-tools] error: agy が対応しないアーキテクチャです: $(uname -m)" >&2
      return 1
      ;;
  esac
  platform="${os}_${arch}"
  if [[ "$os" == "linux" ]]; then
    # musl の検出。パイプの後ろに grep -q を置かない（pipefail で誤って落ちる）。
    if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]]; then
      platform="${platform}_musl"
    else
      case "$(ldd /bin/ls 2>&1 || true)" in
        *musl*) platform="${platform}_musl" ;;
      esac
    fi
  fi
  case "$platform" in
    linux_amd64|linux_arm64|linux_amd64_musl|linux_arm64_musl|darwin_amd64|darwin_arm64)
      printf '%s' "$platform"
      ;;
    *)
      echo "[install-ai-tools] error: agy の配布に無いプラットフォームです: $platform（対応: linux_amd64 / linux_arm64 / linux_amd64_musl / linux_arm64_musl / darwin_amd64 / darwin_arm64）" >&2
      return 1
      ;;
  esac
}

# マニフェスト（JSON）の最上位の、文字列のキーの値を返す。JSON として読めない・
# 最上位がオブジェクトでない・キーが無い・文字列でないときは、空を返して 1 を返す
# （形が変わったマニフェストを、文字列の拾い読みで通さないため）。jq は
# disable_agy_telemetry と同じく前提にする（呼び出し側が有無を確かめる）。
agy_manifest_value() {
  printf '%s' "$1" | jq -er --arg k "$2" \
    'if type == "object" and (.[$k] | type) == "string" and .[$k] != "" then .[$k] else error("missing") end' 2>/dev/null
}

# ファイルの SHA-512（16 進、小文字）を返す。
# どちらの道具も無ければ、理由を出して 1 を返す（「一致しない」と取り違えさせない）。
agy_sha512() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | cut -d' ' -f1
  else
    echo "[install-ai-tools] error: SHA-512 を計算する道具（sha512sum か shasum）がありません" >&2
    return 1
  fi
}

# マニフェストを取り、本体を落として SHA-512 を照合し、~/.local/bin/agy へ置く。
# どこかで失敗したら、理由を出して何も置かずに 1 を返す。一時ファイルは引数の
# ディレクトリ（呼び出し側が mktemp -d で作り、終わったら消す）の配下に作る。
# trap を使わないのは、スクリプトの EXIT の trap を上書きしないため。
agy_install_from_manifest() {
  local tmp="$1"
  local platform manifest version url sha512 payload actual target_dir target staged
  platform="$(agy_platform)" || return 1

  if ! manifest="$(curl -fsSL "$AGY_DOWNLOAD_BASE_URL/manifests/$platform.json" 2>/dev/null)" || [[ -z "$manifest" ]]; then
    echo "[install-ai-tools] error: agy のマニフェストを取得できません: $AGY_DOWNLOAD_BASE_URL/manifests/$platform.json" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "[install-ai-tools] error: jq が無いため agy のマニフェストを読めません。jq を導入してから再実行してください" >&2
    return 1
  fi
  version="$(agy_manifest_value "$manifest" version)" || version=""
  url="$(agy_manifest_value "$manifest" url)" || url=""
  sha512="$(agy_manifest_value "$manifest" sha512)" || sha512=""
  if [[ -z "$version" || -z "$url" || -z "$sha512" ]]; then
    echo "[install-ai-tools] error: agy のマニフェストの形が想定と違います（version・url・sha512 のキーを読めません）" >&2
    return 1
  fi
  if ai_cli_version_is_old "$version" "$AGY_MIN_VERSION"; then
    echo "[install-ai-tools] error: マニフェストの agy の版 $version が下限 $AGY_MIN_VERSION 未満（または読めない綴り）です" >&2
    return 1
  fi
  case "$url" in
    https://*) ;;
    *)
      echo "[install-ai-tools] error: agy のマニフェストの url が https ではありません: $url" >&2
      return 1
      ;;
  esac

  payload="$tmp/payload"
  if ! curl -fsSL -o "$payload" "$url"; then
    echo "[install-ai-tools] error: agy の本体を取得できません: $url" >&2
    return 1
  fi
  actual="$(agy_sha512 "$payload")" || return 1
  if [[ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" != "$(printf '%s' "$sha512" | tr 'A-F' 'a-f')" ]]; then
    echo "[install-ai-tools] error: agy の本体の SHA-512 がマニフェストと一致しません。何も置かずに中止します" >&2
    return 1
  fi

  staged="$payload"
  case "$url" in
    *.tar.gz*)
      if ! tar -xzf "$payload" -C "$tmp" antigravity 2>/dev/null; then
        echo "[install-ai-tools] error: agy のアーカイブから本体（antigravity）を取り出せません" >&2
        return 1
      fi
      staged="$tmp/antigravity"
      ;;
  esac

  # 置く前に、取り出した本体そのものの版を確かめる。SHA-512 はマニフェストとの一致しか
  # 示さず、本体が動くことや下限以上であることは示さない。PATH に ~/.local/bin が
  # 無い環境では、置いたあとに PATH から確かめることもできない。
  chmod +x "$staged" 2>/dev/null || true
  actual="$(ai_cli_version "$staged")"
  if ai_cli_version_is_old "$actual" "$AGY_MIN_VERSION"; then
    echo "[install-ai-tools] error: 取り出した agy の本体の版が $AGY_MIN_VERSION 未満か、読めません（実際: ${actual:-不明}）。何も置かずに中止します" >&2
    return 1
  fi

  target_dir="$HOME/.local/bin"
  target="$target_dir/agy"
  if ! mkdir -p "$target_dir"; then
    echo "[install-ai-tools] error: $target_dir を作れません" >&2
    return 1
  fi
  # 同じディレクトリへ一時の名前で置いてから mv で差し替える（動いている本体を
  # 上書きして「text file busy」になることを避け、途中で切れても半端な本体を残さない）。
  if ! cp "$staged" "$target.new.$$" || ! chmod +x "$target.new.$$" || ! mv -f "$target.new.$$" "$target"; then
    rm -f "$target.new.$$"
    echo "[install-ai-tools] error: agy を $target へ置けません" >&2
    return 1
  fi
  if [[ "$platform" == darwin_* ]]; then
    xattr -d com.apple.quarantine "$target" 2>/dev/null || true
  fi
  # 配布元のインストーラと同じく、PATH の設定などを agy 自身に任せる。配布元も
  # この終了コードで止めないので、導入は失敗にしない。ただし黙って捨てず、知らせる。
  if ! "$target" install; then
    echo "[install-ai-tools] warning: 'agy install'（PATH の設定など）が非 0 で終わりました。~/.local/bin が PATH にあるかを確かめてください" >&2
  fi
}

install_agy_if_missing() {
  local have=""
  if command -v agy >/dev/null 2>&1; then
    have="$(ai_cli_version agy)"
    if ! ai_cli_version_is_old "$have" "$AGY_MIN_VERSION"; then
      echo "[install-ai-tools] agy ${have} already installed (>= $AGY_MIN_VERSION), skipping"
      return 0
    fi
    echo "[install-ai-tools] agy ${have:-（版を読めません）} は $AGY_MIN_VERSION 未満です。入れ替えます ..."
  else
    echo "[install-ai-tools] installing agy (Antigravity CLI) ..."
  fi
  local tmp rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/agy-install.XXXXXX")" || {
    echo "[install-ai-tools] error: 一時ディレクトリを作れません" >&2
    return 1
  }
  agy_install_from_manifest "$tmp" || rc=$?
  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  hash -r

  # ~/.local/bin が PATH に無ければ、導入直後の同一シェルからは見えない。これは
  # 失敗ではないので、次に何をすればよいかを言うに留める。
  #
  # ただし「PATH に無いだけ」と「そもそも置かれていない」を取り違えない。実体の
  # 有無で分ける。取り違えると、導入に失敗しているのに成功として先へ進む。
  if command -v agy >/dev/null 2>&1; then
    have="$(ai_cli_version agy)"
    if ai_cli_version_is_old "$have" "$AGY_MIN_VERSION"; then
      echo "[install-ai-tools] error: 導入後も PATH 上の agy の版が $AGY_MIN_VERSION 未満です（実際: ${have:-不明}、$(command -v agy)）" >&2
      echo "                   ~/.local/bin より前にある古い agy が優先されています。" >&2
      return 1
    fi
    echo "[install-ai-tools] agy installed: $(command -v agy) (${have})"
  elif [[ -x "$HOME/.local/bin/agy" ]]; then
    echo "[install-ai-tools] agy installed to ~/.local/bin (PATH に無いため現シェルからは見えません)"
  else
    echo "[install-ai-tools] error: 導入は完了しましたが agy が見つかりません" >&2
    echo "                   ~/.local/bin/agy が存在しません。導入は失敗しています。" >&2
    return 1
  fi
  echo "[install-ai-tools] agy は OAuth のみです。初回は対話で 'agy' を起動してログインしてください。"
}

# agy のテレメトリ（利用統計・クラッシュログ・対話ログの送信）を既定で止める。
#
# 環境変数によるオプトアウトは存在しない（agy 1.1.11 のバイナリを実測。AGY_* は
# 自動更新・描画・認証まわりのみで、テレメトリ系は無い。DO_NOT_TRACK も非対応）。
# したがって設定ファイルへ書く以外の手段が無い。キーは enableTelemetry（既定 true）。
#
# 上書きではなくマージする。このファイルは agy 自身も書き込む（colorScheme /
# trustedWorkspaces 等）ため、丸ごと置き換えると利用者の設定が消える。
#
# 導入の有無に関わらず毎回通す。「導入したときだけ」にすると、先に手で入れた
# 環境や、既存コンテナへ後追いで適用したい場合にオプトアウトが効かない。
AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

disable_agy_telemetry() {
  local dir tmp current
  dir="$(dirname "$AGY_SETTINGS")"

  # jq が無い場合に「黙って未適用」で先へ進めない。オプトアウトが効いていない
  # ことに誰も気づけないまま、送信だけが続く状態になる。このリポジトリは
  # scripts/acceptance.sh でも jq を前提にしており、不在は環境側の欠陥として扱う。
  if ! command -v jq >/dev/null 2>&1; then
    echo "[install-ai-tools] error: jq が無いため agy のテレメトリを無効化できません" >&2
    echo "                   jq を導入してから再実行してください: bash scripts/install-ai-tools.sh" >&2
    return 1
  fi

  mkdir -p "$dir"
  if [[ ! -e "$AGY_SETTINGS" ]]; then
    printf '{}\n' > "$AGY_SETTINGS"
    chmod 600 "$AGY_SETTINGS"
  fi

  # 壊れた JSON を黙って {} で置き換えない。利用者の設定を捨てることになる。
  if ! jq -e . "$AGY_SETTINGS" >/dev/null 2>&1; then
    echo "[install-ai-tools] error: JSON として読めないため書き換えを中止しました: $AGY_SETTINGS" >&2
    echo "                   内容を修復するか退避してから再実行してください（オプトアウトは未適用です）" >&2
    return 1
  fi

  # 冪等。既に false なら書き込まない（mtime も動かさない）。
  #
  # `// empty` は使わない。jq の `//` は null だけでなく **false も** 代替側へ
  # 落とすため、既に false のときに「未設定」と区別できず、毎回書き込みが起きる
  # （実測で回帰テストが検出した）。値をそのまま出す（未設定なら null が出る）。
  current="$(jq -r '.enableTelemetry' "$AGY_SETTINGS")"
  if [[ "$current" == "false" ]]; then
    echo "[install-ai-tools] agy telemetry already disabled, skipping"
    return 0
  fi

  # 一時ファイルへ書いて mv で差し替える。`jq ... > 同じファイル` はリダイレクトが
  # 先に空へ切り詰めるため、設定が消える。一時ファイルは同じディレクトリに作る
  # （/tmp は別ファイルシステムのことがあり、その場合 mv が原子的にならない）。
  # テンプレートを明示するのは BSD 系の mktemp が必須とするため。
  tmp="$(mktemp "$dir/.settings.json.XXXXXX")"
  # jq が落ちたら一時ファイルを残さない。作成先が設定ディレクトリ直下なので、
  # 失敗のたびに .settings.json.XXXXXX が積み上がり、利用者の設定ディレクトリを
  # 汚し続ける（set -e で即座に抜けるため、後始末の機会もここしかない）。
  if ! jq '.enableTelemetry = false' "$AGY_SETTINGS" > "$tmp"; then
    rm -f "$tmp"
    echo "[install-ai-tools] error: settings.json の書き換えに失敗しました: $AGY_SETTINGS" >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$AGY_SETTINGS"
  echo "[install-ai-tools] agy telemetry disabled (enableTelemetry=false)"
}

# codex（Codex CLI）は npm 配布で、install_if_missing に版の下限を渡して導入する。
#
# 版が要件になる。第二意見レビューの既定モデル gpt-6-sol は、ある版から CLI の
# 一覧に出るようになった綴りで、それより古い CLI は引けない。下限が無いと、
# 「PATH に codex が在れば飛ばす」ので、古い版が先に入っている環境は更新されず、
# レビューのたびに失敗する。だから在るときも版を見る（版の比較は共通の関数）。
#
# 認証は ChatGPT アカウントの OAuth（または API キー）で、導入だけでは使えない。
# 初回に対話で `codex login` を通す必要がある。資格情報は ~/.codex/auth.json に
# 置かれ、この devcontainer では ~/.codex が named volume（codex-storage）なので
# rebuild しても消えない。
CODEX_MIN_VERSION="0.156.0"

install_codex_if_missing() {
  if ! install_if_missing codex "@openai/codex" "$CODEX_MIN_VERSION"; then
    echo "                   第二意見の既定のモデル gpt-6-sol を引けません。" >&2
    return 1
  fi
  echo "[install-ai-tools] codex は認証が別です。初回は対話で 'codex login' を通してください。"
}

install_if_missing claude "@anthropic-ai/claude-code" "2.1.314"
install_if_missing gemini "@google/gemini-cli" "0.64.0"
install_agy_if_missing
disable_agy_telemetry
install_codex_if_missing
echo "[install-ai-tools] done"