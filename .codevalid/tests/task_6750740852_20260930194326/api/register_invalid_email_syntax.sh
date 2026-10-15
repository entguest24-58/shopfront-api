#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

cv_step Given "No external vendor calls for /auth/register; mocks are not required" $LINENO
wiremock_admin_import_mappings "/dev/null"

# Given "Ensure no existing user row uses the malformed email; verify users table is accessible"
cv_prereq "Check that the users table exists and count rows with the malformed email" $LINENO
MALFORMED_EMAIL="invalid-email"
EXISTING_COUNT="$(psql_value "SELECT COUNT(*) FROM users WHERE email = lower('${MALFORMED_EMAIL}');")"
# If EXISTING_COUNT is non-zero, this test still proceeds but will later assert that count does not increase.
printf 'Existing users with malformed email (%s): %s\n' "${MALFORMED_EMAIL}" "${EXISTING_COUNT}"

cv_prereq "Seed a valid user principal for identity-related checks" $LINENO
cv_prereq "Insert a valid users row to establish a principal identity" $LINENO
VALID_EMAIL="valid-user@example.com"
VALID_NAME="Valid User"
VALID_PASSWORD_HASH="hashed-password-placeholder"
db_psql "INSERT INTO users (email, name, password_hash) VALUES (lower('${VALID_EMAIL}'), '${VALID_NAME}', '${VALID_PASSWORD_HASH}');"

cv_step When "Submit POST /auth/register with syntactically invalid email" $LINENO
BASE_URL="$(app_url)"
REQUEST_BODY="$(jq -c -n --arg email "${MALFORMED_EMAIL}" --arg password "password123" --arg name "Invalid Email User" '{email:$email, password:$password, name:$name}')" 
cv_http POST "${BASE_URL}/auth/register" "${REQUEST_BODY}"

cv_step Then "Assert HTTP 400, correct error message, no password exposure, and no user record created for malformed email" $LINENO

# Assert status code is 400
cv_expect_eq "${CV_HTTP_STATUS}" "400" "Expected HTTP 400 for invalid email syntax"

# Parse response JSON
ERROR_MESSAGE="$(printf '%s' "${CV_HTTP_BODY}" | jq -c -r '.error // empty')"
cv_expect_eq "${ERROR_MESSAGE}" "a valid email is required" "Expected specific invalid-email error message"

# Ensure no password or password_hash fields are present in the response
HAS_PASSWORD_FIELD="$(printf '%s' "${CV_HTTP_BODY}" | jq -c 'has("password")')"
HAS_PASSWORD_HASH_FIELD="$(printf '%s' "${CV_HTTP_BODY}" | jq -c 'has("password_hash")')"
cv_expect_eq "${HAS_PASSWORD_FIELD}" "false" "Response must not include password field"
cv_expect_eq "${HAS_PASSWORD_HASH_FIELD}" "false" "Response must not include password_hash field"

# Confirm that no user row was created for the malformed email
FINAL_COUNT="$(psql_value "SELECT COUNT(*) FROM users WHERE email = lower('${MALFORMED_EMAIL}');")"
printf 'Final users with malformed email (%s): %s\n' "${MALFORMED_EMAIL}" "${FINAL_COUNT}"
cv_expect_eq "${FINAL_COUNT}" "${EXISTING_COUNT}" "User count for malformed email must not increase after invalid registration"

cv_step Cleanup "No teardown required; database state for malformed email remains unchanged" $LINENO
:

echo "CODEVALID_TEST_ASSERTION_OK:register_invalid_email_syntax"
