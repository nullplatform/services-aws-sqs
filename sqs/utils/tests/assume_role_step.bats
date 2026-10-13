#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
}

iam_provider_attributes() {
	jq -n '{
		iam_role_arns: {
			arns: [
				{selector: "sqs", arn: "arn:aws:iam::111122223333:role/sqs"}
			]
		}
	}'
}

@test "resolves the nrn from context.service.nrn and queries the identity-access-control provider" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	export MOCK_NP_PROVIDERS
	MOCK_NP_PROVIDERS=$(jq -n --argjson attrs "$(iam_provider_attributes)" '{results: [{attributes: $attrs}]}')
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "np provider list --nrn organization=1:account=2 --categories identity-access-control"
	assert_equal "$(captured SQS_ASSUME_ROLE_ARN_RESOLVED)" "arn:aws:iam::111122223333:role/sqs"
}

@test "falls back to context.scope.nrn when service.nrn is absent" {
	export CONTEXT='{"scope":{"nrn":"organization=1:account=2:scope=9"}}'
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "--nrn organization=1:account=2:scope=9"
}

@test "falls back to context.entity_nrn when service and scope nrn are absent" {
	export CONTEXT='{"entity_nrn":"organization=1:account=2:entity=5"}'
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "--nrn organization=1:account=2:entity=5"
}

@test "passes the context dimensions as a comma separated key:value list" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"},"dimensions":{"region":"us-west-2"}}'
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "--dimensions region:us-west-2"
}

@test "omits the dimensions flag when the context has no dimensions" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_not_contains "$(cat "$MOCK_LOG")" "--dimensions"
}

@test "uses a custom selector from SQS_ASSUME_ROLE_SELECTOR to pick the role arn" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	export SQS_ASSUME_ROLE_SELECTOR="other"
	export MOCK_NP_PROVIDERS
	MOCK_NP_PROVIDERS=$(jq -n '{results: [{attributes: {iam_role_arns: {arns: [
		{selector: "sqs", arn: "arn:aws:iam::111122223333:role/sqs"},
		{selector: "other", arn: "arn:aws:iam::111122223333:role/other"}
	]}}}]}')
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_equal "$(captured SQS_ASSUME_ROLE_ARN_RESOLVED)" "arn:aws:iam::111122223333:role/other"
}

@test "resolves the role, assumes it and exports the returned credentials" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	export MOCK_NP_PROVIDERS
	MOCK_NP_PROVIDERS=$(jq -n --argjson attrs "$(iam_provider_attributes)" '{results: [{attributes: $attrs}]}')
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$captured_stdout" "Role assumed successfully"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" "ASSUMEDKEY"
}

@test "does not fail when no role arn can be resolved for the selector, using agent credentials" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	run_script assume_role_step
	[ "$status" -eq 0 ]
	assert_contains "$captured_stdout" "assume_role=skipped"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" ""
}

@test "fails with troubleshooting guidance when sts:AssumeRole fails for the resolved role" {
	export CONTEXT='{"service":{"nrn":"organization=1:account=2"}}'
	export MOCK_NP_PROVIDERS
	MOCK_NP_PROVIDERS=$(jq -n --argjson attrs "$(iam_provider_attributes)" '{results: [{attributes: $attrs}]}')
	export MOCK_STS_EXIT=1
	run_script assume_role_step
	[ "$status" -eq 1 ]
	assert_contains "$captured_stderr" "assume_role step failed"
	assert_contains "$captured_stderr" "Possible causes"
	assert_contains "$captured_stderr" "organization=1:account=2"
}
