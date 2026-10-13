#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
	export TOFU_MODULE_DIR="$BATS_TEST_TMPDIR/module"
	mkdir -p "$OUTPUT_DIR" "$TOFU_MODULE_DIR"
	echo 'resource "x" "y" {}' > "$TOFU_MODULE_DIR/main.tf"
	export TOFU_INIT_VARIABLES="-backend-config=bucket=b -backend-config=key=k"
	export TOFU_VARIABLES="-var=a=1 -var=b=2"
}

@test "copies the module and runs init then apply with the split variables" {
	export TOFU_ACTION=apply
	run_script do_tofu
	[ "$status" -eq 0 ]
	[ -f "$OUTPUT_DIR/main.tf" ]
	assert_contains "$(cat "$MOCK_LOG")" "tofu init -reconfigure -backend-config=bucket=b -backend-config=key=k"
	assert_contains "$(cat "$MOCK_LOG")" "tofu apply -auto-approve -var=a=1 -var=b=2"
}

@test "runs the configured action when it is not apply" {
	export TOFU_ACTION=destroy
	run_script do_tofu
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "tofu $TOFU_ACTION -auto-approve -var=a=1 -var=b=2"
}

@test "aborts before apply with guidance when init fails" {
	export MOCK_TOFU_EXIT=1
	run_script do_tofu
	[ "$status" -ne 0 ]
	assert_not_contains "$(cat "$MOCK_LOG")" "tofu apply"
	assert_contains "$captured_stderr" "ERROR: tofu init failed in $OUTPUT_DIR"
	assert_contains "$captured_stderr" "Check that the state bucket exists and the assumed role can read it"
}

@test "reconfigures the backend so a stale .terraform from another key cannot abort the run" {
	mkdir -p "$OUTPUT_DIR/.terraform"
	printf '{"backend":{"config":{"key":"old.tfstate"}}}' > "$OUTPUT_DIR/.terraform/terraform.tfstate"
	run_script do_tofu
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "tofu init -reconfigure"
}
