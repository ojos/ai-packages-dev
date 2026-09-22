#!/usr/bin/env bash
# lib.sh — テスト共通のアサーションとフィクスチャ
#
# bash 3.2 互換を維持する（連想配列・mapfile・${var^^} を使わない）。

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# テスト対象と、テスト用の規範ソース
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BOOTSTRAP="$PKG_DIR/bootstrap.sh"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd)"
PLAYBOOK_SRC="$REPO_ROOT/.ai-playbook"

# 各テストが使う一時領域。run-tests.sh が最後に掃除する。
: "${TEST_TMP_ROOT:?TEST_TMP_ROOT must be set by the runner}"

# ── 実行環境からの隔離 ────────────────────────────────────────────────────────
#
# 生成物のスクリプトは、ここに挙げた環境変数を実行時に読む。テストは生成物を
# 起動して挙動を検査するため、実行者の環境にこれらが設定されていると、テストが
# 設定したつもりの無い値を生成物が拾い、判定が変わる。
#
# 実測では GEMINI_REVIEW_RUNS=3 を設定した状態でスイートを回すと 4 ファイル 21
# ケースが落ちた。CI はこれらの変数を持たないため常に緑で、失敗はローカル実行
# だけに現れる。ローカルゲートの赤が「変更のせい」なのか「環境のせい」なのかを
# 実行者が区別できず、CI の予行演習という位置づけが成立しなくなる。
#
# 個々のテストで env -u するのではなくここで一括して落とすのは、新しいテストを
# 足すたびに隔離を書き忘れる余地を無くすため。値を設定したいテストは、従来どおり
# 自身のサブシェルや env で明示的に渡す（ここでの unset はテストプロセスの環境を
# 空にするだけで、テストが子プロセスへ渡す値には干渉しない）。
#
# GIT_CONFIG_GLOBAL はここに含めない。git 自身が読む変数で、テストが一時的な
# global 設定へ向けるために意図的に設定する経路がある。
#
# GH_TOKEN / GITHUB_TOKEN を含める理由: 生成される on-attach.sh は、gh が読む
# 環境変数トークン（GH_TOKEN -> GITHUB_TOKEN の順）の有無で案内を出し分ける。
# 実行者のシェルが .env の autoload や CI から値を持っていると、「どちらも空の
# とき」を検証するケースが環境変数モードの分岐へ落ちる。実行者がトークンを
# 持っているかどうかでテスト結果が変わり、片方の環境でだけ緑になる。
# gh を実際に呼ぶテストは無く（すべてスタブ）、落としても副作用が無い。
TEST_ISOLATED_ENV_VARS="GEMINI_API_KEY GEMINI_REVIEW_RUNS GEMINI_REVIEW_MODEL SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL ALLOWED_AUTHOR_EMAILS GH_TOKEN GITHUB_TOKEN GIT_IDENTITY_NAME GIT_IDENTITY_EMAIL LOOP_GATE_REVIEW_CMD VERIFY_ACCEPTANCE PROJECT_ENV_FILE"

# 語分割で 1 つずつ落とす。bash 3.2 互換のため配列を使わない。
for __isolated_var in $TEST_ISOLATED_ENV_VARS; do
  unset "$__isolated_var"
done
unset __isolated_var

# ── 出力 ──────────────────────────────────────────────────────────────────────

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

pass() {
  printf '  ok   %s\n' "$CURRENT_TEST"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$CURRENT_TEST" >&2
  printf '       %s\n' "$1" >&2
}

# ── アサーション ──────────────────────────────────────────────────────────────

assert_eq() {
  local actual="$1" expected="$2" what="${3:-value}"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "$what: expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  if [[ -f "$1" ]]; then pass; else fail "file not found: $1"; fi
}

assert_file_absent() {
  if [[ ! -e "$1" ]]; then pass; else fail "file should not exist: $1"; fi
}

assert_mode() {
  local path="$1" expected="$2"
  local actual
  actual="$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null || echo '?')"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "mode of $path: expected $expected, got $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" what="${3:-output}"
  case "$haystack" in
    *"$needle"*) pass ;;
    *) fail "$what does not contain '$needle'. got: $(printf '%s' "$haystack" | head -c 200)" ;;
  esac
}

# ── フィクスチャ ──────────────────────────────────────────────────────────────

# 一意な作業ディレクトリを作って標準出力へパスを返す。
new_workdir() {
  mktemp -d "$TEST_TMP_ROOT/wd.XXXXXX"
}

# 規範ソースの tar.gz を作り、パスを返す。公開アーカイブと同じく
# トップレベルディレクトリを 1 段挟む（ai-playbook-<ver>/.ai-playbook/...）。
make_playbook_tarball() {
  local stage archive
  stage="$(mktemp -d "$TEST_TMP_ROOT/tar.XXXXXX")"
  # 実配布と同じ構造にする。配布リポジトリのルート = .ai-playbook の中身なので、
  # GitHub の archive tarball はバージョン名ディレクトリ直下に規範が並ぶ
  # （ai-playbook-<ver>/shared-ai-rules.md）。ここで .ai-playbook/ を内包させると
  # 実配布と乖離し、検出の不具合を素通りさせてしまう。
  mkdir -p "$stage/ai-playbook-test"
  cp -R "$PLAYBOOK_SRC/." "$stage/ai-playbook-test/"
  archive="$stage/playbook.tar.gz"
  tar -czf "$archive" -C "$stage" ai-playbook-test
  printf '%s' "$archive"
}

# ラッパーディレクトリを持たないフラットな tarball を作る。手製アーカイブなど、
# 展開すると直下に規範ファイルとサブディレクトリがそのまま並ぶ構造。ラッパー 1 個を
# 決め打ちする検出だと、直下の最初のサブディレクトリ（例: intake/）を誤認する。
make_flat_playbook_tarball() {
  local stage archive
  stage="$(mktemp -d "$TEST_TMP_ROOT/tar.XXXXXX")"
  mkdir -p "$stage/content"
  cp -R "$PLAYBOOK_SRC/." "$stage/content/"
  archive="$stage/playbook.tar.gz"
  tar -czf "$archive" -C "$stage/content" .
  printf '%s' "$archive"
}

# ローカル HTTP サーバでファイルを配信し、URL を返す。
# ネットワークに出ずに URL 経路を検証するために使う。
# 呼び出し側は stop_http_server で必ず停止すること。
#
# 供給元は環境によって異なる（python3 が最小構成で stdlib を欠く環境もある）。
# どれも使えない場合は黙ってスキップせず、明示的に失敗させる。URL 経路は
# v0.2.0 のリグレッションが起きた場所であり、検証されないまま通してはならない。
HTTP_SERVER_PID=""
HTTP_SERVER_KIND=""

http_server_available() {
  if python3 -c 'import http.server, socketserver' >/dev/null 2>&1; then
    HTTP_SERVER_KIND="python"; return 0
  fi
  if command -v node >/dev/null 2>&1; then
    HTTP_SERVER_KIND="node"; return 0
  fi
  HTTP_SERVER_KIND=""
  return 1
}

serve_file() {
  local file="$1"
  local dir base port_file
  dir="$(dirname "$file")"
  base="$(basename "$file")"

  http_server_available || {
    echo "error: no local HTTP server available (need python3 with stdlib, or node)." >&2
    echo "       URL 経路を検証できないため失敗させます。" >&2
    return 1
  }

  port_file="$(mktemp "$TEST_TMP_ROOT/port.XXXXXX")"

  case "$HTTP_SERVER_KIND" in
    python)
      python3 - "$dir" > "$port_file" 2>/dev/null <<'PY' &
import sys, http.server, socketserver, threading, os
os.chdir(sys.argv[1])
httpd = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY
      HTTP_SERVER_PID=$!
      ;;
    node)
      node -e '
        const http=require("http"),fs=require("fs"),path=require("path");
        const dir=process.argv[1];
        const s=http.createServer((req,res)=>{
          const f=path.join(dir,decodeURIComponent(req.url.slice(1)));
          fs.readFile(f,(e,d)=>{ if(e){res.writeHead(404);res.end();} else {res.writeHead(200);res.end(d);} });
        });
        s.listen(0,"127.0.0.1",()=>{ process.stdout.write(String(s.address().port)+"\n"); });
      ' "$dir" > "$port_file" 2>/dev/null &
      HTTP_SERVER_PID=$!
      ;;
  esac

  local port i=0
  while [[ $i -lt 50 ]]; do
    port="$(head -1 "$port_file" 2>/dev/null || true)"
    [[ -n "$port" ]] && break
    sleep 0.2
    i=$((i + 1))
  done

  if [[ -z "$port" ]]; then
    stop_http_server
    echo "error: $HTTP_SERVER_KIND http server did not report a port" >&2
    return 1
  fi

  printf 'http://127.0.0.1:%s/%s' "$port" "$base"
}

stop_http_server() {
  if [[ -n "$HTTP_SERVER_PID" ]]; then
    kill "$HTTP_SERVER_PID" 2>/dev/null || true
    wait "$HTTP_SERVER_PID" 2>/dev/null || true
    HTTP_SERVER_PID=""
  fi
}

# アサーション失敗や中断でテストが stop_http_server へ到達しない場合に備え、
# 各テストファイルの終了時にも必ず停止させる。掴んだままのポートが残ると、
# 次の実行やこの環境自体に影響する。
trap stop_http_server EXIT

# 配置される規範ファイルの数を数える。配布ルート直下の README.md は
# パッケージ自身の説明であり配置対象外なので、除外して実装と一致させる。
count_rules() {
  find "$1" -type f -name '*.md' 2>/dev/null | grep -v '/README\.md$' | wc -l | tr -d ' '
}

# bootstrap.sh を最小構成で実行する。追加引数はそのまま渡す。
# --mode は廃止。装備は --with-* で選択する（既定は素の環境）。
run_bootstrap() {
  local out="$1"; shift
  bash "$BOOTSTRAP" \
    --project-name test --languages node \
    --output-dir "$out" "$@"
}

# ── 実装の抽出 ────────────────────────────────────────────────────────────────

# bootstrap.sh の引数解析 case 文が受理するフラグを 1 行 1 件で返す。
#
# テスト側に一覧を書き写すと、実装を変えても気づけない（写した一覧が古くなる
# だけ）。文書と実装の照合を書くテストが複数あるため、抽出そのものを 1 か所に
# 置く。2 か所で別々のアンカーを持つと、片方だけがアンカーの変更に追随して
# もう片方が黙って空を返す。
#
# 呼び出し側は、戻り値が空でないことを必ず先に検査すること。空のまま照合へ
# 進むと「空集合と比べて緑」になり、検査が死んだことに気づけない。
impl_flags() {
  sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done$/p' "$BOOTSTRAP" \
    | awk '
        # case のパターン行だけを拾う。先頭の非空白が - で始まる行が該当する。
        /^[[:space:]]*-/ {
          line = $0
          sub(/\).*$/, "", line)          # パターン部だけ残す
          gsub(/^[[:space:]]+/, "", line)
          n = split(line, a, "|")          # -h|--help のような複合パターンを分解
          for (i = 1; i <= n; i++) print a[i]
        }
      ' \
    | sort -u
}

# bootstrap.sh / doctor.sh に複製された DCB_VERSION="vX.Y.Z" の値を取り出す。
# `sed -n '...p' | head -1` にしない。head が最初の一致を得た時点で読み取りを打ち切り、
# 生産側（sed）がまだ書き込み中だと pipefail 下で SIGPIPE により判定が反転しうる
# （scripts/check-shell-portability.sh が検出する）。awk 単体で最初の一致だけを取れば
# パイプの早期終了が起きない。
dcb_version_of() {
  awk -F'"' '/^DCB_VERSION="/ { print $2; exit }' "$1"
}

# テストの期待値として sha256 を計算する。本番の実装（bootstrap.sh / doctor.sh の
# dcb_file_sha256）と同じフォールバック順（sha256sum → shasum → openssl）を持つ。
# ここを sha256sum / shasum だけに絞ると、その 2 つが無く openssl だけがある環境で
# 「正しく動いている実装」をテストの側が誤って落とす（PR #324 レビュー指摘）。
dcb_file_sha256_for_test() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print $NF}'
  else
    echo "error: テスト実行環境に sha256 計算コマンドが無い（sha256sum / shasum / openssl のいずれも無い）" >&2
    return 1
  fi
}

# ── 終了 ──────────────────────────────────────────────────────────────────────

exit_with_result() {
  printf '  %s 件中 %s 件失敗\n\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
