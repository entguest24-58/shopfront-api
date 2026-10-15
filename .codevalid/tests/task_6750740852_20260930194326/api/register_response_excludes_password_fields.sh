#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case: register_response_excludes_password_fields

# Mocks
# No external vendor calls for /auth/register; nothing to stub.
cv_step "Given" "no external vendor dependencies to configure" $LINENO

# Preconditions
cv_prereq "prepare a unique email and ensure no existing user with that email" $LINENO

# Use a deterministic but unique-enough email for this test.
TEST_EMAIL="register-no-password-fields@example.com"

# Ensure the users table does not contain this email (cleanup safety; registration itself does the insert).
db_psql "DELETE FROM users WHERE email = '${TEST_EMAIL}';"

# When
cv_step "When" "POST /auth/register with valid name, email, password and explicit role" $LINENO

BASE_URL="$(app_url)"

REQUEST_BODY=$(cat <<'JSON'
{"email":"register-no-password-fields@example.com","password":"supersecret","name":"Response Shape Test","role":"customer"}
JSON
)

cv_http POST "${BASE_URL}/auth/register" "${REQUEST_BODY}"

# Then
cv_step "Then" "assert response status is 201 and response JSON excludes password fields" $LINENO

# Assert HTTP status code.
if ! cv_expect_eq "201" "${CV_HTTP_STATUS}" "expected 201 Created from /auth/register"; then
  cv_fail "expected 201 got ${CV_HTTP_STATUS}" $LINENO
fi

# Normalize JSON to a single line for easier key inspection.
COMPACT_JSON=$(printf '%s
' "${CV_HTTP_BODY}" | jq -c '.')

# Extract top-level keys as a sorted, space-separated string.
KEYS=$(printf '%s
' "${COMPACT_JSON}" | jq -r 'keys_unsorted | sort | join(" ")')

# Expect exactly: created_at, email, id, name, role
EXPECTED_KEYS="created_at email id name role"
if ! cv_expect_eq "${EXPECTED_KEYS}" "${KEYS}" "response should expose exactly id, email, name, role, created_at"; then
  cv_fail "expected ${EXPECTED_KEYS} got ${KEYS}" $LINENO
fi

# Confirm individual fields exist and have non-null values.
HAS_ID=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("id")')
HAS_EMAIL=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("email")')
HAS_NAME=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("name")')
HAS_ROLE=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("role")')
HAS_CREATED_AT=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("created_at")')

if ! cv_expect_eq "true" "${HAS_ID}" "response must include id"; then
  cv_fail "expected true got ${HAS_ID}" $LINENO
fi
if ! cv_expect_eq "true" "${HAS_EMAIL}" "response must include email"; then
  cv_fail "expected true got ${HAS_EMAIL}" $LINENO
fi
if ! cv_expect_eq "true" "${HAS_NAME}" "response must include name"; then
  cv_fail "expected true got ${HAS_NAME}" $LINENO
fi
if ! cv_expect_eq "true" "${HAS_ROLE}" "response must include role"; then
  cv_fail "expected true got ${HAS_ROLE}" $LINENO
fi
if ! cv_expect_eq "true" "${HAS_CREATED_AT}" "response must include created_at"; then
  cv_fail "expected true got ${HAS_CREATED_AT}" $LINENO
fi

# Explicitly assert that password-related fields are absent.
HAS_PASSWORD=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("password")')
HAS_PASSWORD_HASH=$(printf '%s
' "${COMPACT_JSON}" | jq -c 'has("password_hash")')

if ! cv_expect_eq "false" "${HAS_PASSWORD}" "response must not include password"; then
  cv_fail "expected false got ${HAS_PASSWORD}" $LINENO
fi
if ! cv_expect_eq "false" "${HAS_PASSWORD_HASH}" "response must not include password_hash"; then
  cv_fail "expected false got ${HAS_PASSWORD_HASH}" $LINENO
fi

echo "CODEVALID_TEST_ASSERTION_OK:register_response_excludes_password_fields"

# Teardown
cv_step "Cleanup" "remove the test user from the database" $LINENO

db_psql "DELETE FROM users WHERE email = '${TEST_EMAIL}';"
