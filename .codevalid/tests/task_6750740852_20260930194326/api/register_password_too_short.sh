#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case mappings
# id                               | method | path
# ---------------------------------|--------|----------------
# register_password_too_short      | POST   | /auth/register

### Mocks
# No external vendors are called by POST /auth/register; no WireMock stubs required.

### Preconditions
cv_step "Given" "database schema applied and no existing user with the test email" "$LINENO"
cv_prereq "Apply db/schema.sql via app migration (already handled by app startup MIGRATE_CMD)" "$LINENO"

# Establish a principal user row for the test email (defensive seed before exercising the handler).
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At <<SQL
INSERT INTO users (email, name, password_hash, role)
VALUES (lower('shortpass-user@example.com'), 'Short Pass User', 'seeded-password-hash', 'customer')
ON CONFLICT (email) DO NOTHING;
SQL

# Ensure no pre-existing user with the test email created by this test path.
TEST_EMAIL="shortpass-user@example.com"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At <<SQL
DELETE FROM users WHERE email = lower('$TEST_EMAIL');
SQL

### When
cv_step "When" "client attempts to register with a password shorter than 8 characters" "$LINENO"

BASE_URL="$(app_url)"

REQUEST_BODY="$(jq -nc --arg email "$TEST_EMAIL" --arg name "Short Pass User" --arg password "short7" --arg role "customer" '{email: $email, name: $name, password: $password, role: $role}')"

cv_http POST "$BASE_URL/auth/register" "$REQUEST_BODY"

### Then
cv_step "Then" "registration is rejected with HTTP 400 and no user is created" "$LINENO"

# Assert HTTP status 400.
if [ "$CV_HTTP_STATUS" != "400" ]; then
  cv_fail "expected HTTP 400 from POST /auth/register got $CV_HTTP_STATUS" "$LINENO"
fi

# Assert error message matches handler: { "error": "password must be at least 8 characters" }.
ERROR_MSG="$(printf '%s' "$CV_HTTP_BODY" | jq -rc '.error // empty')"
if [ "$ERROR_MSG" != "password must be at least 8 characters" ]; then
  cv_fail "expected error message 'password must be at least 8 characters' got '${ERROR_MSG}'" "$LINENO"
fi

# Assert no user row was created for the normalized email (lowercased).
USER_COUNT="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At <<SQL
SELECT count(*) FROM users WHERE email = lower('$TEST_EMAIL');
SQL
)"

if [ "$USER_COUNT" != "0" ]; then
  cv_fail "expected no user row for email ${TEST_EMAIL}, found count=${USER_COUNT}" "$LINENO"
fi

# If we reached here, all assertions passed.
echo "CODEVALID_TEST_ASSERTION_OK:register_password_too_short"

### Teardown
cv_step "Cleanup" "remove any user rows with the test email (defensive cleanup)" "$LINENO"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At <<SQL
DELETE FROM users WHERE email = lower('$TEST_EMAIL');
SQL
