#!/usr/bin/env bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REFLAXE_TEST_REPO_ROOT:-$(cd "$SCRIPT_ROOT/.." && pwd)}"
HAXE_BIN="${HAXE_BIN:-haxe}"
PORT="${REFLAXE_TEST_SERVER_PORT:-$((20000 + $$ % 20000))}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reflaxe-server-revisions.XXXXXX")"
SERVER_LOG="$WORK_DIR/server.log"
SERVER_PID=""
COMMON_ARGS=(-D reflaxe.dont_output_metadata_id -D reflaxe_program_revision_probe -D reflaxe_target_reuse_fixture)

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

run_clean_publication_hook_probe() {
	local output
	output="$(
		cd "$WORK_DIR/clean/test"
		"$HAXE_BIN" Test.hxml "${COMMON_ARGS[@]}" -D reflaxe_output_published_hook_probe 2>&1
	)"
	if ! grep -Fq "REFLAXE_OUTPUT_PUBLISHED_HOOK:PASS" <<<"$output"; then
		printf '%s\n' "$output" >&2
		echo "post-publication target hook did not observe the committed public output" >&2
		return 1
	fi
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

run_server_rtti_ineligibility() {
	(
		cd "$WORK_DIR/server/test"
		if ! "$HAXE_BIN" --connect "$PORT" Test.hxml "${COMMON_ARGS[@]}" -D reflaxe_rtti_reuse_probe; then
			sed -n '1,200p' "$SERVER_LOG" >&2
			return 1
		fi
	)
}

run_server_build_expect_failure() {
	local define="$1"
	if (
		cd "$WORK_DIR/server/test"
		"$HAXE_BIN" --connect "$PORT" Test.hxml "${COMMON_ARGS[@]}" -D "$define"
	); then
		echo "the injected output transaction failure unexpectedly succeeded" >&2
		return 1
	fi
}

run_server_build_with_metadata_id() {
	(
		cd "$WORK_DIR/server/test"
		"$HAXE_BIN" --connect "$PORT" Test.hxml -D reflaxe_program_revision_probe
	)
}

metadata_id() {
	node - "$WORK_DIR/server/test/testlang/_GeneratedFiles.json" <<'NODE'
const fs = require('fs')
const receipt = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (!Number.isInteger(receipt.id)) {
	throw new Error('generated-file receipt id is not an integer')
}
process.stdout.write(String(receipt.id))
NODE
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
run_clean_publication_hook_probe
assert_trees_equal "post-publication hook versus ordinary clean output" "$WORK_DIR/clean-baseline" "$WORK_DIR/clean/test/testlang"

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

run_server_build_expect_failure reflaxe_output_transaction_fail_on_complete
assert_trees_equal "failed target completion versus prior complete output" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"
if find "$WORK_DIR/server/test" -maxdepth 1 -name '.*.reflaxe-output-transaction' -print -quit | grep -q .; then
	echo "failed target completion left private transaction state" >&2
	exit 1
fi

run_server_build_expect_failure reflaxe_output_transaction_malformed_receipt
assert_trees_equal "malformed candidate receipt versus prior complete output" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"

run_server_build_expect_failure reflaxe_output_transaction_escape
assert_trees_equal "escaping output rejection versus prior complete output" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"
if [[ -e "$WORK_DIR/server/test/EscapedFailureProbe.testout" ]]; then
	echo "transactional output escaped its owned directory" >&2
	exit 1
fi

run_server_build_expect_failure reflaxe_output_transaction_backslash_escape
assert_trees_equal "backslash-escaping output rejection versus prior complete output" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"

run_server_build_expect_failure reflaxe_output_transaction_absolute
assert_trees_equal "absolute output rejection versus prior complete output" "$WORK_DIR/server-baseline" "$WORK_DIR/server/test/testlang"
if [[ -e "$WORK_DIR/server/test/AbsoluteFailureProbe.testout" ]]; then
	echo "transactional output wrote an absolute path" >&2
	exit 1
fi

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

run_server_rtti_ineligibility
cp "$WORK_DIR/server/test/testlang/TargetReuseEligibility.testout" "$WORK_DIR/rtti-eligibility-first.testout"
run_server_rtti_ineligibility
if ! cmp -s "$WORK_DIR/rtti-eligibility-first.testout" "$WORK_DIR/server/test/testlang/TargetReuseEligibility.testout"; then
	echo "unchanged RTTI requests did not report one stable target-reuse ineligibility reason" >&2
	exit 1
fi
grep -Fx "eligible=false" "$WORK_DIR/server/test/testlang/TargetReuseEligibility.testout" >/dev/null
grep -F "reflaxe:source-authority:haxe4-compiler-generated-rtti-warm-input-unstable" \
	"$WORK_DIR/server/test/testlang/TargetReuseEligibility.testout" >/dev/null

run_server_build_with_metadata_id
FIRST_METADATA_ID="$(metadata_id)"
run_server_build_with_metadata_id
SECOND_METADATA_ID="$(metadata_id)"
if [[ "$SECOND_METADATA_ID" -ne "$((FIRST_METADATA_ID + 1))" ]]; then
	echo "warm output transactions did not reload and increment the committed generated-file receipt" >&2
	exit 1
fi

echo "COMPLETE_PROGRAM_SERVER_CONTRACT:PASS"
