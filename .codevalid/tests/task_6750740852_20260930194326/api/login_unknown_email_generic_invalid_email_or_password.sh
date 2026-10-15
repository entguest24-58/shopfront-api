#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case: login_unknown_email_generic_invalid_email_or_password

## Preconditions
cv_step Given "start compose stack and wait for app health" $LINENO
start_compose
wait_for_app_health

cv_prereq "ensure no user exists for unknown@example.com" $LINENO
# The users table starts empty after migrations; no additional seed is required.
# Optionally, verify absence to keep the case self-contained.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users WHERE email = 'unknown@example.com';"

## When
cv_step When "POST /auth/login with unknown email and a password" $LINENO
LOGIN_BODY='{"email":"unknown@example.com","password":"irrelevantpass"}'
cv_http POST /auth/login "$LOGIN_BODY"

## Then
cv_step Then "assert 401 and generic invalid email or password message with no token issuance" $LINENO

if [ "${CV_HTTP_STATUS:-}" != "401" ]; then
  cv_fail "expected HTTP 401 for unknown email login, got ${CV_HTTP_STATUS:-}" $LINENO
fi

ERROR_FIELD=$(printf '%s
' "$CV_HTTP_BODY" | jq -r '.error // empty' 2>/dev/null || echo "")
if [ "$ERROR_FIELD" != "invalid email or password" ]; then
  cv_fail "expected error message 'invalid email or password', got '${ERROR_FIELD}'" $LINENO
fi

# Assert no token-related fields are present
HAS_TOKEN=$(printf '%s
' "$CV_HTTP_BODY" | jq 'has("token") or has("token_type") or has("expires_in") or has("user")' 2>/dev/null || echo "false")
if [ "$HAS_TOKEN" != "false" ]; then
  cv_fail "unexpected token or user fields present in response for unknown email login" $LINENO
fi

echo "CODEVALID_TEST_ASSERTION_OK:login_unknown_email_generic_invalid_email_or_password"

## Teardown
cv_step Cleanup "stop compose stack" $LINENO
stop_compose
