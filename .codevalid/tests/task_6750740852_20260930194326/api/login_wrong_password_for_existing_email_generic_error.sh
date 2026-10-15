#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case id                                             | Purpose                                                   | Main endpoint    |
#-----------------------------------------------------|-----------------------------------------------------------|------------------|
# login_wrong_password_for_existing_email_generic_error | Incorrect password for existing email yields generic auth error without token | POST /auth/login |

# Case: login_wrong_password_for_existing_email_generic_error

### Mocks
# No external vendors are called by /auth/register or /auth/login; no WireMock stubs are required.

### Preconditions
cv_step "Given compose stack is running and DB schema applied" "$LINENO"
start_compose
wait_for_app_health

cv_prereq "a registered customer account exists via POST /auth/register" "$LINENO"
BASE_URL="http://app:${PORT}"
REGISTER_EMAIL="existing.user@example.com"
REGISTER_PASSWORD="CorrectPass123"
REGISTER_NAME="Existing User"

cv_http POST "/auth/register" "$(jq -nc --arg e "$REGISTER_EMAIL" --arg p "$REGISTER_PASSWORD" --arg n "$REGISTER_NAME" '{email:$e, password:$p, name:$n}')" 

if [ "$CV_HTTP_STATUS" -ne 201 ]; then
  cv_fail "expected 201 from /auth/register got $CV_HTTP_STATUS" "$LINENO"
fi

# Assert that the registration response contains the public user fields and no password data
REGISTER_ID=$(jq -r '.id' <<<"$CV_HTTP_BODY")
REGISTER_RESP_EMAIL=$(jq -r '.email' <<<"$CV_HTTP_BODY")
REGISTER_RESP_NAME=$(jq -r '.name' <<<"$CV_HTTP_BODY")
REGISTER_RESP_ROLE=$(jq -r '.role' <<<"$CV_HTTP_BODY")
REGISTER_RESP_CREATED_AT=$(jq -r '.created_at' <<<"$CV_HTTP_BODY")

if [ -z "$REGISTER_ID" ] || [ "$REGISTER_ID" = "null" ]; then
  cv_fail "registration response missing id" "$LINENO"
fi
if [ "$REGISTER_RESP_EMAIL" != "$(echo "$REGISTER_EMAIL" | tr '[:upper:]' '[:lower:]')" ]; then
  cv_fail "registration response email mismatch: expected normalized $REGISTER_EMAIL got $REGISTER_RESP_EMAIL" "$LINENO"
fi
if [ "$REGISTER_RESP_NAME" != "$REGISTER_NAME" ]; then
  cv_fail "registration response name mismatch: expected $REGISTER_NAME got $REGISTER_RESP_NAME" "$LINENO"
fi
if [ "$REGISTER_RESP_ROLE" = "null" ] || [ -z "$REGISTER_RESP_ROLE" ]; then
  cv_fail "registration response missing role" "$LINENO"
fi
if [ "$REGISTER_RESP_CREATED_AT" = "null" ] || [ -z "$REGISTER_RESP_CREATED_AT" ]; then
  cv_fail "registration response missing created_at" "$LINENO"
fi

# Ensure password-related fields are not present
if jq -e '.password' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "registration response unexpectedly contains password field" "$LINENO"
fi
if jq -e '.password_hash' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "registration response unexpectedly contains password_hash field" "$LINENO"
fi

### When
cv_step "When the shopper logs in with the correct registered email but an incorrect password" "$LINENO"
WRONG_PASSWORD="IncorrectPass456"

cv_http POST "/auth/login" "$(jq -nc --arg e "$REGISTER_EMAIL" --arg p "$WRONG_PASSWORD" '{email:$e, password:$p}')" 

### Then
cv_step "Then the login fails with a generic invalid email or password error and no token is issued" "$LINENO"

if [ "$CV_HTTP_STATUS" -ne 401 ]; then
  cv_fail "expected 401 from /auth/login with wrong password got $CV_HTTP_STATUS" "$LINENO"
fi

LOGIN_ERROR=$(jq -r '.error' <<<"$CV_HTTP_BODY" 2>/dev/null || echo "")
if [ "$LOGIN_ERROR" != "invalid email or password" ]; then
  cv_fail "expected error 'invalid email or password' got '$LOGIN_ERROR'" "$LINENO"
fi

# Ensure no access token is returned
if jq -e '.token' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login response with wrong password must not include token" "$LINENO"
fi
if jq -e '.token_type' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login response with wrong password must not include token_type" "$LINENO"
fi
if jq -e '.expires_in' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login response with wrong password must not include expires_in" "$LINENO"
fi

# Ensure no password or password-derived fields are exposed
if jq -e '.password' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login response unexpectedly contains password field" "$LINENO"
fi
if jq -e '.password_hash' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login response unexpectedly contains password_hash field" "$LINENO"
fi

### Teardown
cv_step "Cleanup compose stack" "$LINENO"
stop_compose

echo "CODEVALID_TEST_ASSERTION_OK:login_wrong_password_for_existing_email_generic_error"
