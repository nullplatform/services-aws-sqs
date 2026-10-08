#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	ENTRYPOINT_DIR="$SERVICE_PATH/entrypoint"
	# np prints each argument in brackets, so assertions see the arguments exactly as the script passed them.
	cat >"$MOCK_BIN/np" <<'EOF'
#!/bin/bash
printf 'np'; printf ' [%s]' "$@"; echo
EOF
	chmod +x "$MOCK_BIN/np"
	unset OVERRIDES_PATH
}

run_action() { # script type [slug]
	SERVICE_ACTION_TYPE="$2" SERVICE_ACTION="${3-slug}" run "$ENTRYPOINT_DIR/$1"
}

@test "service actions run workflows/aws/<type>.yaml with the values file" {
	for type in create update delete; do
		run_action service "$type"
		[ "$status" -eq 0 ]
		[[ "$output" == *"np [service] [workflow] [exec] [--workflow] [$SERVICE_PATH/workflows/aws/$type.yaml] [--values] [$SERVICE_PATH/values.yaml]"* ]]
	done
}

@test "a custom service action runs the workflow named after its slug" {
	run_action service custom read
	[ "$status" -eq 0 ]
	[[ "$output" == *"[$SERVICE_PATH/workflows/aws/read.yaml]"* ]]
}

@test "link actions map create, update and delete to link, link-update and unlink" {
	run_action link create
	[[ "$output" == *"[$SERVICE_PATH/workflows/aws/link.yaml]"* ]]
	run_action link update
	[[ "$output" == *"[$SERVICE_PATH/workflows/aws/link-update.yaml]"* ]]
	run_action link delete
	[[ "$output" == *"[$SERVICE_PATH/workflows/aws/unlink.yaml]"* ]]
}

@test "passes the overrides workflow only when one exists under OVERRIDES_PATH" {
	export OVERRIDES_PATH="$BATS_TEST_TMPDIR/overrides"
	mkdir -p "$OVERRIDES_PATH/workflows/aws"
	touch "$OVERRIDES_PATH/workflows/aws/update.yaml"

	run_action service update
	[[ "$output" == *"[--overrides] [$OVERRIDES_PATH/workflows/aws/update.yaml]"* ]]

	run_action link create
	[ "$status" -eq 0 ]
	[[ "$output" != *"--overrides"* ]]
}

@test "refuses a custom action slug that is not a plain name" {
	for slug in '../../tmp/x' 'read;touch pwned' 'a b' ''; do
		for script in service link; do
			run_action "$script" custom "$slug"
			[ "$status" -eq 1 ]
			[[ "$output" == *"ERROR: invalid action"* ]]
			[[ "$output" != *"np ["* ]]
		done
	done
	[ ! -e pwned ]
}
