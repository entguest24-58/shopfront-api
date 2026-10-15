#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case: register_success_valid_data

### Mocks
# No external vendor calls are made by POST /auth/register; no WireMock stubs required.
CASE_DIR=.codevalid/wiremock/mappings/cases/register_success_valid_data
mkdir -p "$CASE_DIR"
# wiremock_admin_import_mappings "$CASE_DIR"  # no-op for this task

### Preconditions
cv_step Given "unique email and fresh users table state for registration" "$LINENO"
BASE_URL="$(app_url)"

# Choose a unique, mixed-case email for this test.
TEST_EMAIL="NewUser+SignUp@Example.COM"
NORMALIZED_EMAIL="$(printf '%s\n' "$TEST_EMAIL" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//')"
TEST_NAME="Alice Shopper"
TEST_PASSWORD="securePass8"

cv_prereq "ensure no existing user row with the normalized test email" "$LINENO"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = '$NORMALIZED_EMAIL';" >/dev/null

### When
cv_step When "POST /auth/register with valid name, syntactically valid unique email, and password >= 8 characters" "$LINENO"
REQUEST_BODY="$(jq -nc --arg email "$TEST_EMAIL" --arg password "$TEST_PASSWORD" --arg name "$TEST_NAME" '{email: $email, password: $password, name: $name}')"

cv_http POST "/auth/register" "$REQUEST_BODY" 201

### Then
cv_step Then "response contains exactly id, email, name, role, created_at and users table has matching persisted row without exposing password" "$LINENO"

# Assert that the response JSON is an object with exactly the expected keys.
RESP_COMPACT="$(printf '%s\n' "$CV_HTTP_BODY" | jq -c '.')"

# Ensure required keys exist and no extra keys beyond id, email, name, role, created_at.
KEYS_JSON="$(printf '%s\n' "$RESP_COMPACT" | jq -c 'keys | sort')"
EXPECTED_KEYS_JSON="$(jq -nc '["created_at","email","id","name","role"] | sort')"
if [ "$KEYS_JSON" != "$EXPECTED_KEYS_JSON" ]; then
  cv_fail "expected response keys created_at,email,id,name,role got $KEYS_JSON" "$LINENO"
fi

# Extract individual fields.
RESP_ID="$(printf '%s\n' "$RESP_COMPACT" | jq -r '.id')"
RESP_EMAIL="$(printf '%s\n' "$RESP_COMPACT" | jq -r '.email')"
RESP_NAME="$(printf '%s\n' "$RESP_COMPACT" | jq -r '.name')"
RESP_ROLE="$(printf '%s\n' "$RESP_COMPACT" | jq -r '.role')"
RESP_CREATED_AT="$(printf '%s\n' "$RESP_COMPACT" | jq -r '.created_at')"

# Basic type/value checks.
if ! _cv_is_int "$RESP_ID"; then
  cv_fail "expected numeric id in response got $RESP_ID" "$LINENO"
fi

if [ "$RESP_EMAIL" != "$NORMALIZED_EMAIL" ]; then
  cv_fail "expected email to be normalized to lowercase '$NORMALIZED_EMAIL' got '$RESP_EMAIL'" "$LINENO"
fi

if [ "$RESP_NAME" != "$TEST_NAME" ]; then
  cv_fail "expected name '$TEST_NAME' got '$RESP_NAME'" "$LINENO"
fi

if [ "$RESP_ROLE" != "customer" ]; then
  cv_fail "expected default role 'customer' got '$RESP_ROLE'" "$LINENO"
fi

if [ -z "$RESP_CREATED_AT" ] || [ "$RESP_CREATED_AT" = "null" ]; then
  cv_fail "expected non-empty created_at timestamp got '$RESP_CREATED_AT'" "$LINENO"
fi

# Confirm that no password or password_hash fields are present in the response.
HAS_PASSWORD_FIELD="$(printf '%s\n' "$RESP_COMPACT" | jq -c 'has("password")')"
HAS_PASSWORD_HASH_FIELD="$(printf '%s\n' "$RESP_COMPACT" | jq -c 'has("password_hash")')"
if [ "$HAS_PASSWORD_FIELD" = "true" ] || [ "$HAS_PASSWORD_HASH_FIELD" = "true" ]; then
  cv_fail "response must not include password or password_hash fields" "$LINENO"
fi

# Verify persistence in the users table.
cv_prereq "query users table for row matching normalized email" "$LINENO"
USER_ROW="$(psql "$DATABASE_URL" -At -c "SELECT id, email, name, role, password_hash, created_at FROM users WHERE email = '$NORMALIZED_EMAIL';" | head -n 1)"
if [ -z "$USER_ROW" ]; then
  cv_fail "expected a users row for email '$NORMALIZED_EMAIL' but found none" "$LINENO"
fi

DB_ID="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f1)"
DB_EMAIL="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f2)"
DB_NAME="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f3)"
DB_ROLE="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f4)"
DB_PASSWORD_HASH="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f5)"
DB_CREATED_AT="$(printf '%s\n' "$USER_ROW" | cut -d'|' -f6)"

if [ "$DB_EMAIL" != "$NORMALIZED_EMAIL" ]; then
  cv_fail "database email '$DB_EMAIL' does not match normalized email '$NORMALIZED_EMAIL'" "$LINENO"
fi

if [ "$DB_NAME" != "$TEST_NAME" ]; then
  cv_fail "database name '$DB_NAME' does not match '$TEST_NAME'" "$LINENO"
fi

if [ "$DB_ROLE" != "customer" ]; then
  cv_fail "database role '$DB_ROLE' does not match expected 'customer'" "$LINENO"
fi

if [ -z "$DB_PASSWORD_HASH" ]; then
  cv_fail "expected non-empty password_hash in users row got empty" "$LINENO"
fi

if [ -z "$DB_CREATED_AT" ]; then
  cv_fail "expected non-empty created_at in users row got empty" "$LINENO"
fi

# Cross-check IDs between response and DB.
if [ "$DB_ID" != "$RESP_ID" ]; then
  cv_fail "expected DB id '$DB_ID' to match response id '$RESP_ID'" "$LINENO"
fi

echo "CODEVALID_TEST_ASSERTION_OK:register_success_valid_data"

### Teardown
cv_step Cleanup "remove test user row to keep users table clean" "$LINENO"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = '$NORMALIZED_EMAIL';" >/dev/null
