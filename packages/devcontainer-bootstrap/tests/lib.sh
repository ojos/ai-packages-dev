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

# ── 終了 ──────────────────────────────────────────────────────────────────────

exit_with_result() {
  printf '  %s 件中 %s 件失敗\n\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
