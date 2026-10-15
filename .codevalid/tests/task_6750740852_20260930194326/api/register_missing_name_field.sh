#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case: register_missing_name_field

# Case mappings
# id                          | method | path
# register_missing_name_field | POST   | /auth/register

### Mocks
# No external vendor services are called by POST /auth/register; no WireMock mappings needed for this case.

### Preconditions
cv_step "Given database is ready and no user exists for test email" "$LINENO"
cv_prereq "Ensure users table exists and check for pre-existing row" "$LINENO"

# Confirm schema is applied and inspect for any existing user with the test email
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT 1 FROM users WHERE email = 'missing-name@example.com' LIMIT 1;" >/tmp/pre_existing_user.out

if grep -q "1" /tmp/pre_existing_user.out; then
  cv_fail "Precondition failed: a user with email missing-name@example.com already exists" "$LINENO"
fi

### When
cv_step "When shopper submits registration without name field" "$LINENO"

REQUEST_BODY='{"email":"missing-name@example.com","password":"password123"}'

cv_http POST /auth/register "$REQUEST_BODY"

### Then
cv_step "Then registration is rejected and no user record is created" "$LINENO"

# Assert HTTP 400 Bad Request
if [ "${CV_HTTP_STATUS:-}" != "400" ]; then
  cv_fail "Expected HTTP 400 for missing name, got ${CV_HTTP_STATUS:-}" "$LINENO"
fi

# Assert error message is exactly "name is required"
ERROR_MSG=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')

if [ "$ERROR_MSG" != "name is required" ]; then
  cv_fail "Expected error 'name is required', got '${ERROR_MSG}'" "$LINENO"
fi

# Confirm that no user row was created for the normalized email
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "SELECT COUNT(*) FROM users WHERE email = 'missing-name@example.com';" >/tmp/user_count.out

USER_COUNT=$(cut -d'|' -f1 </tmp/user_count.out)

if [ "${USER_COUNT:-0}" != "0" ]; then
  cv_fail "Expected no user row for missing-name@example.com, found count=${USER_COUNT}" "$LINENO"
fi

### Teardown
cv_step "Cleanup any data created during the test (defensive)" "$LINENO"

# Defensive cleanup: delete any user with the test email if present
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = 'missing-name@example.com';" >/dev/null

echo "CODEVALID_TEST_ASSERTION_OK:register_missing_name_field"
