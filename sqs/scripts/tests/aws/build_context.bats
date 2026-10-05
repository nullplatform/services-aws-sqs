#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export CONTEXT
	CONTEXT=$(service_context '{}' "$(full_params)")
	rm -rf /tmp/np-service-0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718
}

with_params() {
	CONTEXT=$(echo "$CONTEXT" | jq "$1")
}

@test "names a Standard queue np-<name> and exports it" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders"
	assert_equal "$(tfvar queue_name)" "np-orders"
	assert_equal "$(tfvar fifo)" "false"
}

@test "names a FIFO queue np-<name>.fifo" {
	with_params '.parameters.queue_type = "fifo"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders.fifo"
	assert_equal "$(tfvar fifo)" "true"
}

@test "keeps the queue name stored in the attributes when the parameters change" {
	CONTEXT=$(service_context '{"queue_name":"np-orders.fifo"}' '{"aws_region":"us-west-2","queue_type":"standard","name":"renamed"}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders.fifo"
	assert_equal "$(tfvar fifo)" "true"
}

@test "rejects an invalid or missing name" {
	with_params '.parameters.name = "bad name!"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: name must be 1-72 characters"

	with_params 'del(.parameters.name)'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: name must be 1-72 characters"
}

@test "applies the documented defaults" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "30"
	assert_equal "$(tfvar message_retention_seconds)" "345600"
	assert_equal "$(tfvar delay_seconds)" "0"
	assert_equal "$(tfvar max_message_size_bytes)" "1048576"
	assert_equal "$(tfvar receive_wait_time_seconds)" "0"
	assert_equal "$(tfvar encryption_key_type)" "sse-sqs"
	assert_equal "$(tfvar kms_key_arn)" ""
	assert_equal "$(tfvar kms_data_key_reuse_seconds)" "300"
	assert_equal "$(tfvar send_principals)" "[]"
	assert_equal "$(tfvar receive_principals)" "[]"
	assert_equal "$(tfvar redrive_allow)" "disabled"
	assert_equal "$(tfvar redrive_source_queue_arns)" "[]"
	assert_equal "$(tfvar dlq_arn)" ""
	assert_equal "$(tfvar dlq_max_receives)" "10"
}

@test "converts every value and unit the developer picks" {
	with_params '.parameters += {
		visibility_timeout_value: 2, visibility_timeout_unit: "hours",
		message_retention_value: 90, message_retention_unit: "minutes",
		delivery_delay_value: 5, delivery_delay_unit: "minutes",
		max_message_size_kib: 256,
		receive_wait_time_seconds: 20
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "7200"
	assert_equal "$(tfvar message_retention_seconds)" "5400"
	assert_equal "$(tfvar delay_seconds)" "300"
	assert_equal "$(tfvar max_message_size_bytes)" "262144"
	assert_equal "$(tfvar receive_wait_time_seconds)" "20"
}

@test "accepts the lowest values of every range" {
	with_params '.parameters += {
		visibility_timeout_value: 0, message_retention_value: 1, message_retention_unit: "minutes",
		delivery_delay_value: 0, max_message_size_kib: 1, receive_wait_time_seconds: 0
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "0"
	assert_equal "$(tfvar message_retention_seconds)" "60"
	assert_equal "$(tfvar max_message_size_bytes)" "1024"
}

@test "rejects values outside the AWS ranges" {
	with_params '.parameters += {visibility_timeout_value: 13, visibility_timeout_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: visibility timeout must be between 0 and 43200 seconds, got 46800 (13 hours)"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {message_retention_value: 30, message_retention_unit: "seconds"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: message retention period must be between 60 and 1209600 seconds"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {message_retention_value: 15, message_retention_unit: "days"}'
	run_script build_context
	[ "$status" -ne 0 ]

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {delivery_delay_value: 16, delivery_delay_unit: "minutes"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: delivery delay must be between 0 and 900 seconds, got 960 (16 minutes)"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {max_message_size_kib: 1025}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: maximum message size (KiB) must be between 1 and 1024, got 1025"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {receive_wait_time_seconds: 21}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: receive message wait time (seconds) must be between 0 and 20, got 21"
}

@test "rejects a unit the field does not offer and a decimal value" {
	with_params '.parameters += {delivery_delay_value: 1, delivery_delay_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: delivery delay unit must be one of: seconds minutes"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {visibility_timeout_value: 1.5}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "must be a whole number, got '1.5'"
}

@test "SSE-KMS carries the key ARN and the data key reuse period" {
	with_params '.parameters += {
		encryption_key_type: "sse-kms",
		kms_key_arn: "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
		data_key_reuse_value: 1, data_key_reuse_unit: "hours"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar encryption_key_type)" "sse-kms"
	assert_equal "$(tfvar kms_key_arn)" "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
	assert_equal "$(tfvar kms_data_key_reuse_seconds)" "3600"
}

@test "SSE-KMS accepts an alias ARN" {
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "arn:aws:kms:us-west-2:111122223333:alias/queues"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" "arn:aws:kms:us-west-2:111122223333:alias/queues"
}

@test "SSE-KMS rejects a missing or malformed key and an out-of-range reuse period" {
	with_params '.parameters += {encryption_key_type: "sse-kms"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: kms_key_arn must be a KMS key or alias ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "1234abcd-12ab-34cd-56ef-1234567890ab"}'
	run_script build_context
	[ "$status" -ne 0 ]

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "arn:aws:kms:us-west-2:111122223333:alias/queues", data_key_reuse_value: 25, data_key_reuse_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: data key reuse period must be between 60 and 86400 seconds, got 90000 (25 hours)"
}

@test "SSE-SQS ignores a leftover key ARN, and an unknown key type is rejected" {
	with_params '.parameters += {encryption_key_type: "sse-sqs", kms_key_arn: "garbage"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" ""

	with_params '.parameters.encryption_key_type = "sse-foo"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: encryption_key_type must be sse-sqs or sse-kms, got 'sse-foo'"
}

@test "send and receive principals are normalized, owner access stays empty" {
	with_params '.parameters += {
		send_access: "principals", send_principals: " 111122223333 , arn:aws:iam::444455556666:role/worker ,",
		receive_access: "owner", receive_principals: "ignored"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar send_principals)" '["arn:aws:iam::111122223333:root","arn:aws:iam::444455556666:role/worker"]'
	assert_equal "$(tfvar receive_principals)" "[]"
}

@test "principals mode with an empty or invalid list is rejected" {
	with_params '.parameters += {receive_access: "principals", receive_principals: ""}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: receive principals needs at least one account ID or ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {send_access: "principals", send_principals: "nope"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: send principals entry 'nope' is not a 12-digit account ID"
}

@test "redrive allow By queue carries the source queue ARNs" {
	with_params '.parameters += {
		redrive_allow: "by_queue",
		redrive_source_queues: "arn:aws:sqs:us-west-2:111122223333:jobs, arn:aws:sqs:us-west-2:111122223333:jobs-2"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar redrive_allow)" "by_queue"
	assert_equal "$(tfvar redrive_source_queue_arns)" '["arn:aws:sqs:us-west-2:111122223333:jobs","arn:aws:sqs:us-west-2:111122223333:jobs-2"]'
}

@test "redrive allow All and Deny need no queues; By queue without queues and unknown modes are rejected" {
	with_params '.parameters.redrive_allow = "allow_all"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar redrive_allow)" "allow_all"
	assert_equal "$(tfvar redrive_source_queue_arns)" "[]"

	with_params '.parameters.redrive_allow = "by_queue"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: redrive_source_queues needs at least one queue ARN"

	with_params '.parameters.redrive_allow = "sometimes"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: redrive_allow must be disabled, allow_all, by_queue or deny_all, got 'sometimes'"
}

@test "an enabled dead-letter queue carries its ARN and max receives" {
	with_params '.parameters += {dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq", dlq_max_receives: 5}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar dlq_arn)" "arn:aws:sqs:us-west-2:111122223333:orders-dlq"
	assert_equal "$(tfvar dlq_max_receives)" "5"
}

@test "an enabled dead-letter queue needs a valid ARN, a sane max receives and the same queue type" {
	with_params '.parameters += {dlq_enabled: "enabled"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: dead-letter queue ARN must be an SQS queue ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq", dlq_max_receives: 0}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: maximum receives must be between 1 and 1000, got 0"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {queue_type: "fifo", dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: a FIFO queue needs a FIFO dead-letter queue"
}

@test "a disabled dead-letter queue ignores a leftover ARN" {
	with_params '.parameters += {dlq_enabled: "disabled", dlq_arn: "garbage"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar dlq_arn)" ""
}

@test "merges the developer's tags under the platform tags, which cannot be overridden" {
	with_params '.parameters.tags = [{"key":"team","value":"payments"},{"key":"account_id","value":"spoofed"}]'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar tags.team)" "payments"
	assert_equal "$(tfvar tags.account_id)" "2"
	assert_equal "$(tfvar 'tags | has("scope_id")')" "false"
}

@test "accepts the tags as a key=value string" {
	with_params '.parameters.tags = "team=payments, env = prod"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar tags.team)" "payments"
	assert_equal "$(tfvar tags.env)" "prod"
}

@test "rejects a tag key that starts with aws:" {
	with_params '.parameters.tags = [{"key":"aws:team","value":"x"}]'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: tag keys must not start with aws:"
}

@test "takes the region from the aws_region attribute without querying the account provider" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured REGION)" "us-west-2"
	assert_not_contains "$(cat "$MOCK_LOG")" "np provider"
}

@test "resolves the region from the account provider when the attribute is absent" {
	with_params 'del(.parameters.aws_region)'
	export MOCK_NP_PROVIDERS='{"results":[{"id":"prov-1","data_source":{"stored_keys":["account.region"]}}]}'
	export MOCK_NP_PROVIDER='{"attributes":{"account":{"region":"eu-central-1"}}}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured REGION)" "eu-central-1"
	assert_contains "$(cat "$MOCK_LOG")" "np provider list --nrn organization=1:account=2 --format json --limit 100"
}

@test "fails with a clear message when no region can be resolved" {
	with_params 'del(.parameters.aws_region)'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: no account provider with account.region found for organization=1:account=2"
}

@test "keeps the service state under services/sqs/<service id>/" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured TFSTATE_BUCKET)" "np-sqs-state"
	assert_equal "$(captured TFSTATE_KEY_PREFIX)" "services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=key=services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/terraform.tfstate"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=bucket=np-sqs-state"
	assert_equal "$(captured TOFU_MODULE_DIR)" "$SERVICE_PATH/deployment"
	assert_contains "$(captured TOFU_VARIABLES)" "-var-file=$(captured OUTPUT_DIR)/terraform.tfvars.json"
}

@test "fails when the state bucket variable is missing or the bucket is unreachable" {
	export SQS_S3_STATE_BUCKET=""
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: SQS_S3_STATE_BUCKET is not set."

	export SQS_S3_STATE_BUCKET="np-sqs-state"
	export MOCK_BUCKET_EXISTS=1
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: the state bucket np-sqs-state does not exist or is not reachable from us-west-2."
}

@test "a link action derives the link user and skips the queue settings" {
	export ACTION_SOURCE=link
	CONTEXT=$(link_context '{"queue_name":"np-orders","aws_region":"us-west-2"}' '{}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured LINK_ID)" "7d9e2f10-1234-4abc-9def-0123456789ab"
	assert_equal "$(captured LINK_USER_NAME)" "np-orders-api-7d9e2-user"
	assert_equal "$(captured QUEUE_NAME)" "np-orders"
	assert_equal "$(captured TOFU_VARIABLES)" ""
	[ ! -f "$(captured OUTPUT_DIR)/terraform.tfvars.json" ]
}

@test "a link action fails when the service has no queue yet" {
	export ACTION_SOURCE=link
	CONTEXT=$(link_context '{"aws_region":"us-west-2"}' '{}')
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: the service has no queue_name attribute yet."
}

@test "deleting a service does not re-validate the form, so a service whose saved settings are invalid can still be deleted" {
	export SERVICE_ACTION_TYPE=delete
	CONTEXT=$(service_context '{"queue_name":"np-orders","message_retention_value":1,"message_retention_unit":"seconds","send_access":"principals","send_principals":"bob"}' '{"aws_region":"us-west-2"}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar queue_name)" "np-orders"
	assert_equal "$(tfvar fifo)" "false"
	assert_equal "$(tfvar region)" "us-west-2"
	assert_equal "$(captured TOFU_MODULE_DIR)" "$SERVICE_PATH/deployment"
}

@test "deleting a FIFO service keeps its fifo flag so destroy matches the queue name" {
	export SERVICE_ACTION_TYPE=delete
	CONTEXT=$(service_context '{"queue_name":"np-orders.fifo"}' '{"aws_region":"us-west-2"}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar fifo)" "true"
}

@test "creating or updating still validates the form" {
	export SERVICE_ACTION_TYPE=update
	with_params '.parameters += {message_retention_value: 30, message_retention_unit: "seconds"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: message retention period must be between 60 and 1209600 seconds"
}
