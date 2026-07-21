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
	if [[ -d "$WORK_DIR" ]]; then
		find "$WORK_DIR" -depth -delete
	fi
}
trap cleanup EXIT

wait_for_server() {
	local attempt
	for ((attempt = 0; attempt < 50; attempt++)); do
		if ! kill -0 "$SERVER_PID" 2>/dev/null; then
			sed -n '1,160p' "$SERVER_LOG" >&2
			return 1
		fi
		if command -v lsof >/dev/null 2>&1; then
			if lsof -nP -a -p "$SERVER_PID" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
				return 0
			fi
		elif command -v ss >/dev/null 2>&1; then
			if ss -H -ltn "sport = :$PORT" | grep -q .; then
				return 0
			fi
		else
			echo "Waiting for the Haxe compiler server requires lsof or ss." >&2
			return 1
		fi
		sleep 0.1
	done
	echo "Haxe compiler server did not become ready on port $PORT within 5 seconds." >&2
	sed -n '1,160p' "$SERVER_LOG" >&2
	return 1
}

cp -R "$REPO_ROOT/src" "$WORK_DIR/src"
cp -R "$TEST_ROOT" "$WORK_DIR/test"

"$HAXE_BIN" --wait "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
wait_for_server

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
