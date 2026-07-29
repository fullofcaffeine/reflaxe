#!/usr/bin/env bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REFLAXE_TEST_REPO_ROOT:-$(cd "$SCRIPT_ROOT/.." && pwd)}"
HAXE_BIN="${HAXE_BIN:-haxe}"
PORT="${REFLAXE_TEST_SERVER_PORT:-$((20000 + $$ % 20000))}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reflaxe-server-revisions.XXXXXX")"
SERVER_LOG="$WORK_DIR/server.log"
SERVER_PID=""
COMMON_ARGS=(-D reflaxe.dont_output_metadata_id -D reflaxe_program_revision_probe)

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

prepare_tree() {
	local name="$1"
	mkdir -p "$WORK_DIR/$name"
	cp -R "$REPO_ROOT/src" "$WORK_DIR/$name/src"
	cp -R "$SCRIPT_ROOT" "$WORK_DIR/$name/test"
	find "$WORK_DIR/$name/test/testlang" -depth -delete
	mkdir -p "$WORK_DIR/$name/test/testlang"
}

run_clean_build() {
	(
		cd "$WORK_DIR/clean/test"
		"$HAXE_BIN" Test.hxml "${COMMON_ARGS[@]}"
	)
}

run_server_build() {
	(
		cd "$WORK_DIR/server/test"
		if ! "$HAXE_BIN" --connect "$PORT" Test.hxml "${COMMON_ARGS[@]}"; then
			sed -n '1,200p' "$SERVER_LOG" >&2
			return 1
		fi
	)
}

assert_trees_equal() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if ! diff -ru "$expected" "$actual"; then
		echo "$label generated different complete target trees" >&2
		return 1
	fi
}

field_value() {
	local root="$1"
	local field="$2"
	sed -n "s/^${field}=//p" "$root/ProgramRevision.testout"
}

edit_subject() {
	local root="$1"
	perl -0pi -e 's/var input = 1;/var input = 41;/' "$root/ProgramRevisionSubject.hx"
	grep -F 'var input = 41;' "$root/ProgramRevisionSubject.hx" >/dev/null
}

prepare_tree clean
prepare_tree server

run_clean_build
cp -R "$WORK_DIR/clean/test/testlang" "$WORK_DIR/clean-baseline"

"$HAXE_BIN" --wait "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
wait_for_server

run_server_build
assert_trees_equal "cold server versus clean process" "$WORK_DIR/clean-baseline" "$WORK_DIR/server/test/testlang"
cp -R "$WORK_DIR/server/test/testlang" "$WORK_DIR/server-baseline"

BASELINE_PROGRAM="$(field_value "$WORK_DIR/server-baseline" program)"
BASELINE_MODULES="$(field_value "$WORK_DIR/server-baseline" modules)"
BASELINE_FUNCTIONS="$(field_value "$WORK_DIR/server-baseline" functions)"
BASELINE_UNCHANGED="$(shasum -a 256 "$WORK_DIR/server-baseline/haxe_Log.testout" | awk '{print $1}')"
if [[ -z "$BASELINE_PROGRAM" || -z "$BASELINE_MODULES" || -z "$BASELINE_FUNCTIONS" ]]; then
	echo "the complete-program probe omitted required revision evidence" >&2
	exit 1
fi
grep -F '"wasCached": false' "$WORK_DIR/server-baseline/_GeneratedFiles.json" >/dev/null

run_server_build
assert_trees_equal "unchanged warm server versus cold server" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"

edit_subject "$WORK_DIR/server/test"
edit_subject "$WORK_DIR/clean/test"
run_server_build
EDITED_PROGRAM="$(field_value "$WORK_DIR/server/test/testlang" program)"
EDITED_MODULES="$(field_value "$WORK_DIR/server/test/testlang" modules)"
EDITED_FUNCTIONS="$(field_value "$WORK_DIR/server/test/testlang" functions)"
EDITED_UNCHANGED="$(shasum -a 256 "$WORK_DIR/server/test/testlang/haxe_Log.testout" | awk '{print $1}')"
if [[ "$BASELINE_PROGRAM" == "$EDITED_PROGRAM" ]]; then
	echo "a real body edit did not change the complete program revision" >&2
	exit 1
fi
if [[ "$BASELINE_MODULES" != "$EDITED_MODULES" || "$BASELINE_FUNCTIONS" != "$EDITED_FUNCTIONS" ]]; then
	echo "a body-only edit changed complete target membership" >&2
	exit 1
fi
if [[ "$BASELINE_UNCHANGED" != "$EDITED_UNCHANGED" ]]; then
	echo "a body-only edit changed an unrelated generated module" >&2
	exit 1
fi
cp -R "$WORK_DIR/server/test/testlang" "$WORK_DIR/server-edited"

find "$WORK_DIR/clean/test/testlang" -depth -delete
mkdir -p "$WORK_DIR/clean/test/testlang"
run_clean_build
assert_trees_equal "edited warm server versus edited clean process" "$WORK_DIR/clean/test/testlang" "$WORK_DIR/server-edited"

cp "$SCRIPT_ROOT/ProgramRevisionSubject.hx" "$WORK_DIR/server/test/ProgramRevisionSubject.hx"
touch -t 202001010103.03 "$WORK_DIR/server/test/ProgramRevisionSubject.hx"
run_server_build
assert_trees_equal "restored A-to-B-to-A server request" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"

echo "COMPLETE_PROGRAM_SERVER_CONTRACT:PASS"
