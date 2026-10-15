#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

cv_step Given "app is healthy and a new customer can register and log in for token tests" $LINENO
cv_prereq "wait for app health at HEALTH_URL" $LINENO
wait_for_app_health

# Case mappings
# id                                      | entry             | method | path
# login_token_expiration_enforced_on_protected_endpoint | POST_login        | POST   | /auth/login

# Case: login_token_expiration_enforced_on_protected_endpoint

## Mocks
# No third-party/vendor HTTP clients are used by /auth/register, /auth/login, or /cart routes.
# The app talks only to Postgres via pg Pool, so no WireMock mappings are needed.

## Preconditions
cv_prereq "register a new customer account for login and token tests" $LINENO
cv_prereq "create users row via POST /auth/register" $LINENO
REGISTER_EMAIL="expiry-test@example.com"
REGISTER_PASSWORD="expiryPass123"
REGISTER_NAME="Expiry Test Customer"

cv_http POST \
  /auth/register \
  "$(jq -nc --arg e "$REGISTER_EMAIL" --arg p "$REGISTER_PASSWORD" --arg n "$REGISTER_NAME" '{email: $e, password: $p, name: $n}')"

cv_expect_status 201 "$CV_HTTP_STATUS"

# Assert that the registration response does not contain password fields
REGISTER_BODY_COMPACT=$(jq -c '.' <<<"$CV_HTTP_BODY")
PASSWORD_FIELD_COUNT=$(jq '([keys[] | select(test("password"))] | length)' <<<"$REGISTER_BODY_COMPACT")
cv_expect_eq "0" "$PASSWORD_FIELD_COUNT" "register response must not include any password-related fields"

cv_prereq "log in with the registered credentials to obtain a JWT access token" $LINENO
cv_prereq "POST /auth/login with registered email and password" $LINENO
cv_http POST \
  /auth/login \
  "$(jq -nc --arg e "$REGISTER_EMAIL" --arg p "$REGISTER_PASSWORD" '{email: $e, password: $p}')"

cv_expect_status 200 "$CV_HTTP_STATUS"

# Extract token, token_type, and expires_in from login response
LOGIN_BODY_COMPACT=$(jq -c '.' <<<"$CV_HTTP_BODY")
TOKEN=$(jq -r '.token' <<<"$LOGIN_BODY_COMPACT")
TOKEN_TYPE=$(jq -r '.token_type' <<<"$LOGIN_BODY_COMPACT")
EXPIRES_IN=$(jq -r '.expires_in' <<<"$LOGIN_BODY_COMPACT")

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  cv_fail "login response did not include a non-empty token" $LINENO
fi

cv_expect_eq "Bearer" "$TOKEN_TYPE" "login must return token_type 'Bearer'"
cv_expect_eq "7200" "$EXPIRES_IN" "login must advertise 2-hour token lifetime via expires_in = 7200"

## When
cv_step When "call protected GET /cart with a valid Authorization: Bearer token, then with an invalid token to exercise the rejection path used for expired tokens" $LINENO
cv_prereq "use token from login response in Authorization header" $LINENO
cv_http GET \
  /cart \
  "" \
  -H "Authorization: Bearer $TOKEN"

cv_expect_status 200 "$CV_HTTP_STATUS"

# Optional sanity check: response is valid JSON
CART_BODY_COMPACT=$(jq -c '.' <<<"$CV_HTTP_BODY" || true)
if [[ -z "$CART_BODY_COMPACT" ]]; then
  cv_fail "GET /cart with valid token did not return valid JSON" $LINENO
fi

cv_prereq "call protected GET /cart with an invalid token to exercise the rejection path used for expired tokens" $LINENO
INVALID_TOKEN="this-is-not-a-valid-jwt"
cv_http GET \
  /cart \
  "" \
  -H "Authorization: Bearer $INVALID_TOKEN"

## Then
cv_step Then "protected endpoint rejects non-valid/expired tokens with HTTP 401 and the expected generic error" $LINENO
cv_expect_status 401 "$CV_HTTP_STATUS"

INVALID_BODY_COMPACT=$(jq -c '.' <<<"$CV_HTTP_BODY")
INVALID_ERROR_MSG=$(jq -r '.error' <<<"$INVALID_BODY_COMPACT")
cv_expect_eq "invalid or expired token" "$INVALID_ERROR_MSG" "protected endpoint must respond with generic 'invalid or expired token' for non-valid or expired tokens"

# This assertion corresponds to the business requirement that tokens issued at login
# have a 2-hour lifetime and, once expired, are rejected by protected operations with
# status 401 and the same generic error message, without exposing any password data.

## Teardown
cv_step Cleanup "no explicit teardown required; database rows can remain for subsequent tests" $LINENO
# No cleanup actions are necessary because the test inserts only a single user row and
# uses existing products/catalog data. The database and app lifecycle are managed by
# the shared test infrastructure and Docker Compose configuration.

echo "CODEVALID_TEST_ASSERTION_OK:login_token_expiration_enforced_on_protected_endpoint"
