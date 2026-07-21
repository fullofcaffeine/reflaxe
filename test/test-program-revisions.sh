#!/usr/bin/env bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REFLAXE_TEST_REPO_ROOT:-$(cd "$SCRIPT_ROOT/.." && pwd)}"
HAXE_BIN="${HAXE_BIN:-haxe}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reflaxe-program-revisions.XXXXXX")"

cleanup() {
	if [[ -d "$WORK_DIR" ]]; then
		find "$WORK_DIR" -depth -delete
	fi
}
trap cleanup EXIT

prepare_case() {
	local name="$1"
	mkdir -p "$WORK_DIR/$name"
	cp -R "$REPO_ROOT/src" "$WORK_DIR/$name/src"
	cp -R "$SCRIPT_ROOT" "$WORK_DIR/$name/test"
	find "$WORK_DIR/$name/test/testlang" \( -name 'ProgramRevision.testout' -o -name 'ProgramRevisionSubject.testout' \) -delete
}

build_case() {
	local name="$1"
	shift
	(
		cd "$WORK_DIR/$name/test"
		"$HAXE_BIN" Test.hxml -D reflaxe_program_revision_probe "$@"
	)
	test -f "$WORK_DIR/$name/test/testlang/ProgramRevision.testout"
}

field_value() {
	local name="$1"
	local field="$2"
	sed -n "s/^${field}=//p" "$WORK_DIR/$name/test/testlang/ProgramRevision.testout"
}

prepare_case baseline
prepare_case perturbed
prepare_case changed

perl -0pi -e 's/var input = 1;/var input = 41;/' "$WORK_DIR/changed/test/ProgramRevisionSubject.hx"
grep -F 'var input = 41;' "$WORK_DIR/changed/test/ProgramRevisionSubject.hx" >/dev/null

build_case baseline
build_case perturbed -D reflaxe_perturb_program_local_ids
build_case changed

baseline_program="$(field_value baseline program)"
perturbed_program="$(field_value perturbed program)"
changed_program="$(field_value changed program)"
baseline_raw="$(field_value baseline raw-subject-body)"
perturbed_raw="$(field_value perturbed raw-subject-body)"

if [[ -z "$baseline_program" || -z "$perturbed_program" || -z "$changed_program" ]]; then
	echo "program-revision probe did not emit every required fingerprint" >&2
	exit 1
fi
if [[ "$baseline_raw" == "$perturbed_raw" ]]; then
	echo "regression setup did not shift Haxe's raw process-wide local IDs" >&2
	exit 1
fi
if [[ "$baseline_program" != "$perturbed_program" ]]; then
	echo "unrelated macro-local numbering changed the normalized program fingerprint" >&2
	exit 1
fi
if [[ "$baseline_program" == "$changed_program" ]]; then
	echo "a real Haxe body change did not change the normalized program fingerprint" >&2
	exit 1
fi
if ! cmp -s "$WORK_DIR/baseline/test/testlang/ProgramRevisionSubject.testout" "$WORK_DIR/perturbed/test/testlang/ProgramRevisionSubject.testout"; then
	echo "the local-number perturbation changed generated target code" >&2
	diff -u "$WORK_DIR/baseline/test/testlang/ProgramRevisionSubject.testout" "$WORK_DIR/perturbed/test/testlang/ProgramRevisionSubject.testout" || true
	exit 1
fi

echo "PROGRAM_REVISION_LOCAL_ID_NORMALIZATION:PASS"
