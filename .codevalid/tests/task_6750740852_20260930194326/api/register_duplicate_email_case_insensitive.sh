#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case mappings
# id                                     | method | path
# -------------------------------------- | ------ | ----------------
# register_duplicate_email_case_insensitive | POST   | /auth/register

# Case: register_duplicate_email_case_insensitive

### Mocks
# No external vendors are called by POST /auth/register; no WireMock mappings needed for this case.

### Preconditions
cv_step "Given schema is applied and no user exists with the target email" $LINENO
cv_prereq "Ensure users table exists and is empty for our test email" $LINENO
# Confirm users table exists (schema applied by app startup) and remove any prior rows for the test email.
TEST_EMAIL_LOWER="duplicate@test.example"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = lower('$TEST_EMAIL_LOWER');"

cv_prereq "Given an existing customer account already registered with the lowercase email" $LINENO
cv_prereq "Create initial user via POST /auth/register using lowercase email" $LINENO
INITIAL_BODY=$(jq -n \
  --arg email "$TEST_EMAIL_LOWER" \
  --arg password "Password123" \
  --arg name "Existing User" \
  '{email: $email, password: $password, name: $name}')
cv_http POST /auth/register "$INITIAL_BODY"
if [ "$CV_HTTP_STATUS" -ne 201 ]; then
  cv_fail "expected initial registration 201, got $CV_HTTP_STATUS" $LINENO
fi

# Assert response contains exactly id, email, name, role, created_at and no password fields.
HAS_ID=$(echo "$CV_HTTP_BODY" | jq 'has("id")')
HAS_EMAIL_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("email")')
HAS_NAME_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("name")')
HAS_ROLE_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("role")')
HAS_CREATED_AT_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("created_at")')
HAS_PASSWORD_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("password")')
HAS_PASSWORD_HASH_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("password_hash")')
HAS_OTHER_PASSWORD_FIELD=$(echo "$CV_HTTP_BODY" | jq 'has("passwordDerived")')
if [ "$HAS_ID" != "true" ] || [ "$HAS_EMAIL_FIELD" != "true" ] || [ "$HAS_NAME_FIELD" != "true" ] || [ "$HAS_ROLE_FIELD" != "true" ] || [ "$HAS_CREATED_AT_FIELD" != "true" ]; then
  cv_fail "initial registration response missing one of required fields id/email/name/role/created_at" $LINENO
fi
if [ "$HAS_PASSWORD_FIELD" != "false" ] || [ "$HAS_PASSWORD_HASH_FIELD" != "false" ] || [ "$HAS_OTHER_PASSWORD_FIELD" != "false" ]; then
  cv_fail "initial registration response must not include password or password-derived fields" $LINENO
fi

# Verify exactly one row exists in users for the normalized email.
USER_COUNT=$(psql "$DATABASE_URL" -At -c "SELECT COUNT(*) FROM users WHERE email = lower('$TEST_EMAIL_LOWER');")
if [ "$USER_COUNT" != "1" ]; then
  cv_fail "expected 1 existing user with email=$TEST_EMAIL_LOWER, found $USER_COUNT" $LINENO
fi

### When
cv_step "When a shopper attempts to register with the same email differing only by case" $LINENO
cv_prereq "Prepare JSON body with uppercased email and valid name/password" $LINENO
DUPLICATE_EMAIL_UPPER=$(echo "$TEST_EMAIL_LOWER" | tr '[:lower:]' '[:upper:]')
DUPLICATE_BODY=$(jq -n \
  --arg email "$DUPLICATE_EMAIL_UPPER" \
  --arg password "Password123" \
  --arg name "Second User" \
  '{email: $email, password: $password, name: $name}')
cv_http POST /auth/register "$DUPLICATE_BODY"

### Then
cv_step "Then the registration is rejected with 409 and a clear account already exists message, and no additional user row is created" $LINENO

# Assert HTTP status is 409 Conflict.
if [ "$CV_HTTP_STATUS" -ne 409 ]; then
  cv_fail "expected duplicate registration 409, got $CV_HTTP_STATUS" $LINENO
fi

# Assert the error message matches acceptance criteria wording.
ERROR_MESSAGE=$(echo "$CV_HTTP_BODY" | jq -r '.error // empty')
if [ "$ERROR_MESSAGE" != "an account with this email already exists" ]; then
  cv_fail "expected error 'an account with this email already exists', got '$ERROR_MESSAGE'" $LINENO
fi

# Assert no password or password-derived fields are present in duplicate response.
HAS_PASSWORD_FIELD_DUP=$(echo "$CV_HTTP_BODY" | jq 'has("password")')
HAS_PASSWORD_HASH_FIELD_DUP=$(echo "$CV_HTTP_BODY" | jq 'has("password_hash")')
HAS_OTHER_PASSWORD_FIELD_DUP=$(echo "$CV_HTTP_BODY" | jq 'has("passwordDerived")')
if [ "$HAS_PASSWORD_FIELD_DUP" != "false" ] || [ "$HAS_PASSWORD_HASH_FIELD_DUP" != "false" ] || [ "$HAS_OTHER_PASSWORD_FIELD_DUP" != "false" ]; then
  cv_fail "duplicate registration error response must not include password or password-derived fields" $LINENO
fi

# Confirm users table still has exactly one row for the normalized email (case-insensitive uniqueness enforced).
FINAL_USER_COUNT=$(psql "$DATABASE_URL" -At -c "SELECT COUNT(*) FROM users WHERE email = lower('$TEST_EMAIL_LOWER');")
if [ "$FINAL_USER_COUNT" != "1" ]; then
  cv_fail "expected users table to still have 1 row for email=$TEST_EMAIL_LOWER after duplicate attempt, found $FINAL_USER_COUNT" $LINENO
fi

### Teardown
cv_step "Cleanup any test users created for this case" $LINENO
cv_prereq "Delete users with the test email from the users table" $LINENO
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = lower('$TEST_EMAIL_LOWER');"

echo "CODEVALID_TEST_ASSERTION_OK:register_duplicate_email_case_insensitive"
