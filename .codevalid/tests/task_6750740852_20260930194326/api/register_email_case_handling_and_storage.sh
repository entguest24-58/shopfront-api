#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case mappings
# id                                     | method | path           | handler
# --------------------------------------+--------+----------------+-------------------
# register_email_case_handling_and_storage | POST   | /auth/register | src/auth/router.ts

# Case: register_email_case_handling_and_storage
### Mocks
# No external vendors are called by POST /auth/register; no WireMock stubs required.

### Preconditions
cv_step Given "database schema applied and no existing user with target email" $LINENO
cv_prereq "Ensure users table exists and is empty for target email" $LINENO

# Confirm schema is applied by checking users table exists (will error if missing).
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT 1 FROM users LIMIT 1;" >/dev/null

# Define the mixed-case email used for this scenario.
TARGET_EMAIL_MIXED="Mixed.Case+Test@Example.COM"
TARGET_EMAIL_NORMALIZED="$(printf '%s' "$TARGET_EMAIL_MIXED" | tr 'A-Z' 'a-z')"

# Ensure no pre-existing user row with this normalized email.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = '$TARGET_EMAIL_NORMALIZED';" >/dev/null

### When
cv_step When "register a new account with mixed-case email, then attempt duplicate registration with different casing" $LINENO

BASE_URL="$(app_url)"

# First registration with mixed-case email to establish the principal user row.
FIRST_BODY="$(jq -n --arg email "$TARGET_EMAIL_MIXED" \
                    --arg name "Mixed Case User" \
                    --arg password "SuperSecureP@ss1" \
                    '{email: $email, name: $name, password: $password}')"

cv_http POST "/auth/register" "$FIRST_BODY"

if [ "$CV_HTTP_STATUS" -ne 201 ]; then
  cv_fail "expected first register status 201 got $CV_HTTP_STATUS" $LINENO
fi

FIRST_RESP_FILE="${TMPDIR:-/tmp}/register_email_case_handling_and_storage_first.json"
printf '%s
' "$CV_HTTP_BODY" > "$FIRST_RESP_FILE"

# Second registration with same email but different casing
SECOND_EMAIL_VARIANT="$(printf '%s' "$TARGET_EMAIL_NORMALIZED" | sed 's/@/@/' | tr 'a-z' 'A-Z')"
# Construct a different-cased variant explicitly to ensure different casing; use lowercase normalized form and uppercase local-part for clarity.
SECOND_EMAIL_VARIANT="${TARGET_EMAIL_NORMALIZED}"

SECOND_BODY="$(jq -n --arg email "$SECOND_EMAIL_VARIANT" \
                     --arg name "Another User" \
                     --arg password "AnotherPass123" \
                     '{email: $email, name: $name, password: $password}')"

cv_http POST "/auth/register" "$SECOND_BODY"

SECOND_RESP_FILE="${TMPDIR:-/tmp}/register_email_case_handling_and_storage_second.json"
printf '%s
' "$CV_HTTP_BODY" > "$SECOND_RESP_FILE"

### Then
cv_step Then "email is normalized, stored and returned consistently; duplicate casing rejected with clear conflict" $LINENO

# Assert first response has exactly the expected public fields and no password fields.
# Use jq with careful parentheses to avoid precedence issues.
HAS_ID="$(jq 'has("id")' "$FIRST_RESP_FILE")"
HAS_EMAIL="$(jq 'has("email")' "$FIRST_RESP_FILE")"
HAS_NAME="$(jq 'has("name")' "$FIRST_RESP_FILE")"
HAS_ROLE="$(jq 'has("role")' "$FIRST_RESP_FILE")"
HAS_CREATED_AT="$(jq 'has("created_at")' "$FIRST_RESP_FILE")"
HAS_PASSWORD="$(jq 'has("password")' "$FIRST_RESP_FILE")"
HAS_PASSWORD_HASH="$(jq 'has("password_hash")' "$FIRST_RESP_FILE")"

if [ "$HAS_ID" != "true" ] || [ "$HAS_EMAIL" != "true" ] || [ "$HAS_NAME" != "true" ] || [ "$HAS_ROLE" != "true" ] || [ "$HAS_CREATED_AT" != "true" ]; then
  cv_fail "expected first response to contain id, email, name, role, created_at fields" $LINENO
fi

if [ "$HAS_PASSWORD" != "false" ] || [ "$HAS_PASSWORD_HASH" != "false" ]; then
  cv_fail "first response must not contain password or password_hash fields" $LINENO
fi

# Assert email in response is normalized lowercase.
RESP_EMAIL="$(jq -r '.email' "$FIRST_RESP_FILE")"
if [ "$RESP_EMAIL" != "$TARGET_EMAIL_NORMALIZED" ]; then
  cv_fail "expected response email '$TARGET_EMAIL_NORMALIZED' got '$RESP_EMAIL'" $LINENO
fi

# Assert role is set (default 'customer' from schema/code).
RESP_ROLE="$(jq -r '.role' "$FIRST_RESP_FILE")"
if [ "$RESP_ROLE" != "customer" ] && [ "$RESP_ROLE" != "admin" ]; then
  cv_fail "expected response role to be 'customer' or 'admin' got '$RESP_ROLE'" $LINENO
fi

# Assert user row in DB exists and email is stored normalized.
DB_ROW="$(psql "$DATABASE_URL" -At -c "SELECT email FROM users WHERE email = '$TARGET_EMAIL_NORMALIZED';")"
DB_EMAIL="$(printf '%s' "$DB_ROW" | cut -d'|' -f1)"

if [ "$DB_EMAIL" != "$TARGET_EMAIL_NORMALIZED" ]; then
  cv_fail "expected DB email '$TARGET_EMAIL_NORMALIZED' got '$DB_EMAIL'" $LINENO
fi

# Assert second registration attempt is rejected with 409 and clear conflict message.
if [ "$CV_HTTP_STATUS" -ne 409 ]; then
  cv_fail "expected second register status 409 got $CV_HTTP_STATUS" $LINENO
fi

SECOND_ERROR="$(jq -r '.error // empty' "$SECOND_RESP_FILE")"
if [ "$SECOND_ERROR" != "an account with this email already exists" ]; then
  cv_fail "expected second response error 'an account with this email already exists' got '$SECOND_ERROR'" $LINENO
fi

# Assert no duplicate user rows were created for differently cased email.
USER_COUNT="$(psql "$DATABASE_URL" -At -c "SELECT count(*) FROM users WHERE email = '$TARGET_EMAIL_NORMALIZED';")"
USER_COUNT_VAL="$(printf '%s' "$USER_COUNT" | cut -d'|' -f1)"

if [ "$USER_COUNT_VAL" != "1" ]; then
  cv_fail "expected exactly 1 user row for normalized email, got $USER_COUNT_VAL" $LINENO
fi

### Teardown
cv_step Cleanup "remove test user rows for target email" $LINENO

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = '$TARGET_EMAIL_NORMALIZED';" >/dev/null

echo "CODEVALID_TEST_ASSERTION_OK:register_email_case_handling_and_storage"
