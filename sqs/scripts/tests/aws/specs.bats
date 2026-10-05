#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	SPEC="$SERVICE_PATH/specs/service-spec.json.tpl"
	LINK="$SERVICE_PATH/specs/links/connect.json.tpl"
}

prop() {
	jq -r ".attributes.schema.properties.$1" "$SPEC"
}

@test "both specs are valid JSON with the schema under attributes.schema" {
	jq -e '.attributes.schema.type == "object"' "$SPEC"
	jq -e '.attributes.schema.type == "object"' "$LINK"
	run jq -e '.specification_schema' "$SPEC"
	[ "$status" -ne 0 ]
	run jq -e '.specification_schema' "$LINK"
	[ "$status" -ne 0 ]
}

@test "the service offers its link and the link slug matches" {
	assert_equal "$(jq -r .slug "$SPEC")" "aws-sqs"
	assert_equal "$(jq -r '.available_links[0]' "$SPEC")" "create-aws-sqs-link"
	assert_equal "$(jq -r .slug "$LINK")" "create-aws-sqs-link"
}

@test "the queue type and name can only be set on create" {
	assert_equal "$(prop 'queue_type.editableOn' | jq -c .)" '["create"]'
	assert_equal "$(prop 'name.editableOn' | jq -c .)" '["create"]'
	assert_equal "$(jq -c '.attributes.schema.required' "$SPEC")" '["queue_type","name"]'
}

@test "every other setting can be changed after creation" {
	for p in visibility_timeout_value visibility_timeout_unit message_retention_value message_retention_unit \
		delivery_delay_value delivery_delay_unit max_message_size_kib receive_wait_time_seconds \
		encryption_key_type kms_key_arn data_key_reuse_value data_key_reuse_unit \
		send_access send_principals receive_access receive_principals \
		redrive_allow redrive_source_queues dlq_enabled dlq_arn dlq_max_receives tags; do
		assert_equal "$(prop "$p.editableOn" | jq -c .)" '["create","update"]'
	done
}

@test "the defaults match the ones build_context applies" {
	assert_equal "$(prop 'queue_type.default')" "standard"
	assert_equal "$(prop 'visibility_timeout_value.default')" "30"
	assert_equal "$(prop 'visibility_timeout_unit.default')" "seconds"
	assert_equal "$(prop 'message_retention_value.default')" "4"
	assert_equal "$(prop 'message_retention_unit.default')" "days"
	assert_equal "$(prop 'delivery_delay_value.default')" "0"
	assert_equal "$(prop 'delivery_delay_unit.default')" "seconds"
	assert_equal "$(prop 'max_message_size_kib.default')" "1024"
	assert_equal "$(prop 'receive_wait_time_seconds.default')" "0"
	assert_equal "$(prop 'encryption.default')" "Enabled"
	assert_equal "$(prop 'encryption_key_type.default')" "sse-sqs"
	assert_equal "$(prop 'data_key_reuse_value.default')" "5"
	assert_equal "$(prop 'data_key_reuse_unit.default')" "minutes"
	assert_equal "$(prop 'send_access.default')" "owner"
	assert_equal "$(prop 'receive_access.default')" "owner"
	assert_equal "$(prop 'redrive_allow.default')" "disabled"
	assert_equal "$(prop 'dlq_enabled.default')" "disabled"
	assert_equal "$(prop 'dlq_max_receives.default')" "10"
}

@test "the numeric limits match the AWS ranges build_context enforces" {
	assert_equal "$(prop 'visibility_timeout_value.minimum')-$(prop 'visibility_timeout_value.maximum')" "0-43200"
	assert_equal "$(prop 'message_retention_value.minimum')-$(prop 'message_retention_value.maximum')" "1-1209600"
	assert_equal "$(prop 'delivery_delay_value.minimum')-$(prop 'delivery_delay_value.maximum')" "0-900"
	assert_equal "$(prop 'max_message_size_kib.minimum')-$(prop 'max_message_size_kib.maximum')" "1-1024"
	assert_equal "$(prop 'receive_wait_time_seconds.minimum')-$(prop 'receive_wait_time_seconds.maximum')" "0-20"
	assert_equal "$(prop 'data_key_reuse_value.minimum')-$(prop 'data_key_reuse_value.maximum')" "1-86400"
	assert_equal "$(prop 'dlq_max_receives.minimum')-$(prop 'dlq_max_receives.maximum')" "1-1000"
}

@test "each unit field offers exactly the units its range allows" {
	units() { prop "$1.oneOf" | jq -c '[.[].const]'; }
	assert_equal "$(units visibility_timeout_unit)" '["seconds","minutes","hours"]'
	assert_equal "$(units message_retention_unit)" '["seconds","minutes","hours","days"]'
	assert_equal "$(units delivery_delay_unit)" '["seconds","minutes"]'
	assert_equal "$(units data_key_reuse_unit)" '["minutes","hours"]'
}

@test "the enum values are the ones the scripts understand" {
	vals() { prop "$1.oneOf" | jq -c '[.[].const]'; }
	assert_equal "$(vals queue_type)" '["standard","fifo"]'
	assert_equal "$(vals encryption_key_type)" '["sse-sqs","sse-kms"]'
	assert_equal "$(vals send_access)" '["owner","principals"]'
	assert_equal "$(vals receive_access)" '["owner","principals"]'
	assert_equal "$(vals redrive_allow)" '["disabled","allow_all","by_queue","deny_all"]'
	assert_equal "$(vals dlq_enabled)" '["disabled","enabled"]'
}

@test "the service exports the queue url and arn and nothing secret" {
	assert_equal "$(prop 'queue_url.export')" "true"
	assert_equal "$(prop 'queue_arn.export')" "true"
	run jq -e '[.attributes.schema.properties[] | select(.export | type == "object")] | length == 0' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "every control in the form points at a property and every input property has a control" {
	run jq -e '
		.attributes.schema as $s
		| [ $s.uiSchema | .. | objects | select(.type == "Control") | .scope | sub("^#/properties/"; "") ] as $controls
		| ($controls | all(. as $k | $s.properties | has($k)))
		  and (($s.properties | keys) - $controls - ["aws_region","queue_url","queue_arn","queue_name"] == [])
	' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "the conditional fields are shown only when their switch is on" {
	cond() {
		jq -r --arg scope "#/properties/$1" '
			[.attributes.schema.uiSchema | .. | objects | select(.scope? == $scope) | .rule.condition | "\(.scope) \(.schema | tojson)"] | first' "$SPEC"
	}
	assert_equal "$(cond kms_key_arn)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond data_key_reuse_value)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond data_key_reuse_unit)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond send_principals)" '#/properties/send_access {"const":"principals"}'
	assert_equal "$(cond receive_principals)" '#/properties/receive_access {"const":"principals"}'
	assert_equal "$(cond redrive_source_queues)" '#/properties/redrive_allow {"const":"by_queue"}'
	assert_equal "$(cond dlq_arn)" '#/properties/dlq_enabled {"const":"enabled"}'
	assert_equal "$(cond dlq_max_receives)" '#/properties/dlq_enabled {"const":"enabled"}'
	run jq -e '[.attributes.schema.uiSchema | .. | objects | select(has("rule")) | .rule.effect] | all(. == "SHOW")' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "the hidden-when-off string fields accept an empty value" {
	for p in kms_key_arn dlq_arn; do
		pattern=$(prop "$p.pattern")
		[[ "" =~ $pattern ]]
	done
}

@test "the link exports the credentials as secrets and the region as plain" {
	assert_equal "$(jq -r '.attributes.schema.properties.access_key_id.export' "$LINK")" "true"
	assert_equal "$(jq -c '.attributes.schema.properties.secret_access_key.export' "$LINK")" '{"type":"environment_variable","secret":true}'
	assert_equal "$(jq -r '.attributes.schema.properties.aws_region.export' "$LINK")" "true"
	assert_equal "$(jq -c '.attributes.schema.required' "$LINK")" '["access_key_id","secret_access_key"]'
}
