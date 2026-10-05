#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
}

referenced_files() {
	grep -hoE 'file: \$SERVICE_PATH/[^ ]+' "$SERVICE_PATH"/workflows/*.yaml | sed 's|file: \$SERVICE_PATH/||' | sort -u
}

@test "every script a workflow references exists and is executable" {
	[ -n "$(referenced_files)" ]
	for rel in $(referenced_files); do
		[ -x "$SERVICE_PATH/$rel" ] || { echo "missing or not executable: $rel"; return 1; }
	done
}

@test "every workflow is valid YAML-shaped: it starts with steps and each step has a name and a type" {
	for f in "$SERVICE_PATH"/workflows/*.yaml; do
		head -1 "$f" | grep -q '^steps:$' || { echo "$f does not start with steps:"; return 1; }
		[ "$(grep -c '^  - name:' "$f")" -eq "$(grep -c '^    type: script$' "$f")" ] || { echo "$f: name/type mismatch"; return 1; }
	done
}

@test "create and update provision with apply, delete destroys and then cleans the state" {
	for action in create update; do
		grep -q 'TOFU_ACTION: apply' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'write_service_outputs' "$SERVICE_PATH/workflows/$action.yaml"
	done
	grep -q 'TOFU_ACTION: destroy' "$SERVICE_PATH/workflows/delete.yaml"
	grep -q 'delete_tfstate_objects' "$SERVICE_PATH/workflows/delete.yaml"
}

@test "every workflow that touches AWS assumes the role first" {
	for f in create update delete link link-update unlink; do
		[ "$(grep -m1 'file:' "$SERVICE_PATH/workflows/$f.yaml")" = '    file: $SERVICE_PATH/utils/assume_role_step' ]
	done
}

@test "the template placeholder script is gone" {
	[ ! -e "$SERVICE_PATH/scripts/example" ]
}

@test "link and link-update apply and write the link outputs, unlink destroys" {
	for action in link link-update; do
		grep -q 'TOFU_ACTION: apply' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'build_permissions_context' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'write_link_outputs' "$SERVICE_PATH/workflows/$action.yaml"
	done
	grep -q 'TOFU_ACTION: destroy' "$SERVICE_PATH/workflows/unlink.yaml"
	! grep -q 'write_link_outputs' "$SERVICE_PATH/workflows/unlink.yaml"
}
