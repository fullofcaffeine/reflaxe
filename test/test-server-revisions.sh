#!/usr/bin/env bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REFLAXE_TEST_REPO_ROOT:-$(cd "$SCRIPT_ROOT/.." && pwd)}"
TEST_ROOT="$REPO_ROOT/test"
HAXE_BIN="${HAXE_BIN:-haxe}"
PORT="${REFLAXE_TEST_SERVER_PORT:-$((20000 + $$ % 20000))}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reflaxe-server-revisions.XXXXXX")"
SERVER_LOG="$WORK_DIR/server.log"
SERVER_PID=""

cleanup() {
	if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cp -R "$REPO_ROOT/src" "$WORK_DIR/src"
cp -R "$TEST_ROOT" "$WORK_DIR/test"

"$HAXE_BIN" --wait "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.2
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
	cat "$SERVER_LOG"
	exit 1
fi

run_build() {
	if ! "$HAXE_BIN" --connect "$PORT" Test.hxml; then
		cat "$SERVER_LOG"
		exit 1
	fi
}

cd "$WORK_DIR/test"
touch -t 202001010101.01 MyClass.hx
run_build
FIRST_DIGEST="$(shasum -a 256 testlang/MyClass.testout | awk '{print $1}')"
cp testlang/MyClass.testout "$WORK_DIR/first-MyClass.testout"
grep -F 'Log.trace("Hello world."' testlang/MyClass.testout >/dev/null

perl -0pi -e 's/trace\("Hello world\."\);/trace("Hello server rebuild.");/' MyClass.hx
touch -t 202001010102.02 MyClass.hx
grep -F 'trace("Hello server rebuild.");' MyClass.hx >/dev/null
run_build
grep -F 'Log.trace("Hello server rebuild."' testlang/MyClass.testout >/dev/null

cp "$TEST_ROOT/MyClass.hx" MyClass.hx
touch -t 202001010103.03 MyClass.hx
run_build
FINAL_DIGEST="$(shasum -a 256 testlang/MyClass.testout | awk '{print $1}')"
if [[ "$FIRST_DIGEST" != "$FINAL_DIGEST" ]]; then
	echo "restored server build did not reproduce the original generated output" >&2
	diff -u "$WORK_DIR/first-MyClass.testout" testlang/MyClass.testout || true
	exit 1
fi

echo "SEMANTIC_SERVER_REVISION_CONTRACT:PASS"
