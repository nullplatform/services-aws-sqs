#!/usr/bin/env bats

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	UTILS_DIR="$(cd "$TEST_DIR/.." && pwd)"
	source "$UTILS_DIR/assume_role_lib"

	IAM_PROVIDER='{"iam_role_arns":{"arns":[
		{"selector":"sqs","arn":"arn:aws:iam::111122223333:role/sqs"},
		{"selector":"other","arn":"arn:aws:iam::111122223333:role/other"}
	]}}'

	unset SQS_ASSUME_ROLE_ARN SQS_ASSUME_ROLE_ARN_DEFAULT
}

@test "arn_for_selector returns the arn matching the selector" {
	run arn_for_selector "$IAM_PROVIDER" "sqs"
	[ "$status" -eq 0 ]
	[ "$output" = "arn:aws:iam::111122223333:role/sqs" ]
}

@test "arn_for_selector returns empty when no entry matches" {
	run arn_for_selector "$IAM_PROVIDER" "missing"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "arn_for_selector returns empty on malformed json without crashing" {
	run arn_for_selector "not json at all" "sqs"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "resolve_assume_role_arn prefers the explicit override" {
	export SQS_ASSUME_ROLE_ARN="arn:aws:iam::999:role/override"
	run resolve_assume_role_arn "$IAM_PROVIDER" "sqs" "SQS_ASSUME_ROLE_ARN" "SQS_ASSUME_ROLE_ARN_DEFAULT"
	[ "$output" = "arn:aws:iam::999:role/override" ]
}

@test "resolve_assume_role_arn falls back to the provider entry" {
	run resolve_assume_role_arn "$IAM_PROVIDER" "sqs" "SQS_ASSUME_ROLE_ARN" "SQS_ASSUME_ROLE_ARN_DEFAULT"
	[ "$output" = "arn:aws:iam::111122223333:role/sqs" ]
}

@test "resolve_assume_role_arn falls back to the default env var" {
	export SQS_ASSUME_ROLE_ARN_DEFAULT="arn:aws:iam::999:role/default"
	run resolve_assume_role_arn "$IAM_PROVIDER" "missing" "SQS_ASSUME_ROLE_ARN" "SQS_ASSUME_ROLE_ARN_DEFAULT"
	[ "$output" = "arn:aws:iam::999:role/default" ]
}

@test "resolve_assume_role_arn treats an empty override as unset" {
	export SQS_ASSUME_ROLE_ARN=""
	run resolve_assume_role_arn "$IAM_PROVIDER" "sqs" "SQS_ASSUME_ROLE_ARN" "SQS_ASSUME_ROLE_ARN_DEFAULT"
	[ "$output" = "arn:aws:iam::111122223333:role/sqs" ]
}

@test "resolve_assume_role_arn returns empty when nothing is configured" {
	run resolve_assume_role_arn "{}" "sqs" "SQS_ASSUME_ROLE_ARN" "SQS_ASSUME_ROLE_ARN_DEFAULT"
	[ "$output" = "" ]
}
