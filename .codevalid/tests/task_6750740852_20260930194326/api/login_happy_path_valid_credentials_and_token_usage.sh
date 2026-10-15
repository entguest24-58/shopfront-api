#!/usr/bin/env bash
set -euo pipefail

# Source shared infra helpers
source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Define BASE_URL explicitly if not provided by infra
BASE_URL="${BASE_URL:-http://app:6713}"

# Local inequality assertion helper using cv_fail with LINENO.
cv_expect_ne() {
  local actual="$1"
  local not_expected="$2"
  if [ "$actual" = "$not_expected" ]; then
    cv_fail "expected '$actual' to not equal '$not_expected'" "$LINENO"
  fi
}

# ------------------------- Given -------------------------
cv_step Given "app health ok and user registered" "$LINENO"

cv_prereq "wait for app health endpoint to be OK" "$LINENO"
wait_for_app_health

# Register a new customer account via POST /auth/register
REQUEST_BODY_REGISTER='{"email":"login-happy@example.com","password":"supersecure","name":"Login Happy"}'
cv_http POST "/auth/register" "$REQUEST_BODY_REGISTER" -H "Content-Type: application/json"
CV_HTTP_STATUS="$CV_HTTP_STATUS"
cv_expect_eq "$CV_HTTP_STATUS" 201

# Extract the registered user id and email from the register response (for later comparison)
REGISTER_USER_JSON="$(echo "$CV_HTTP_BODY" | jq -c '.')"
REGISTER_USER_ID="$(echo "$REGISTER_USER_JSON" | jq -r '.id')"
REGISTER_USER_EMAIL="$(echo "$REGISTER_USER_JSON" | jq -r '.email')"

# ------------------------- When -------------------------
cv_step When "user logs in with valid credentials" "$LINENO"

REQUEST_BODY_LOGIN='{"email":"login-happy@example.com","password":"supersecure"}'
cv_http POST "/auth/login" "$REQUEST_BODY_LOGIN" -H "Content-Type: application/json"
CV_HTTP_STATUS="$CV_HTTP_STATUS"
cv_expect_eq "$CV_HTTP_STATUS" 200

# ------------------------- Then -------------------------
cv_step Then "login response has token and user; token works on protected route" "$LINENO"

# Parse login response as compact JSON
LOGIN_JSON="$(echo "$CV_HTTP_BODY" | jq -c '.')"

# Assert token, token_type, and expires_in fields
LOGIN_TOKEN="$(echo "$LOGIN_JSON" | jq -r '.token')"
cv_expect_ne "$LOGIN_TOKEN" "null"
cv_expect_ne "$LOGIN_TOKEN" ""

LOGIN_TOKEN_TYPE="$(echo "$LOGIN_JSON" | jq -r '.token_type')"
cv_expect_eq "$LOGIN_TOKEN_TYPE" "Bearer"

LOGIN_EXPIRES_IN="$(echo "$LOGIN_JSON" | jq -r '.expires_in')"
cv_expect_eq "$LOGIN_EXPIRES_IN" 7200

# Assert user object contains id, email, name, role, created_at and no password fields
LOGIN_USER_JSON="$(echo "$LOGIN_JSON" | jq -c '.user')"

LOGIN_USER_ID="$(echo "$LOGIN_USER_JSON" | jq -r '.id')"
LOGIN_USER_EMAIL="$(echo "$LOGIN_USER_JSON" | jq -r '.email')"
cv_expect_eq "$LOGIN_USER_ID" "$REGISTER_USER_ID"
cv_expect_eq "$LOGIN_USER_EMAIL" "$REGISTER_USER_EMAIL"

LOGIN_USER_HAS_NAME="$(echo "$LOGIN_USER_JSON" | jq 'has("name")')"
cv_expect_eq "$LOGIN_USER_HAS_NAME" "true"

LOGIN_USER_HAS_ROLE="$(echo "$LOGIN_USER_JSON" | jq 'has("role")')"
cv_expect_eq "$LOGIN_USER_HAS_ROLE" "true"

LOGIN_USER_HAS_CREATED_AT="$(echo "$LOGIN_USER_JSON" | jq 'has("created_at")')"
cv_expect_eq "$LOGIN_USER_HAS_CREATED_AT" "true"

LOGIN_USER_HAS_PASSWORD="$(echo "$LOGIN_USER_JSON" | jq 'has("password")')"
cv_expect_eq "$LOGIN_USER_HAS_PASSWORD" "false"

LOGIN_USER_HAS_PASSWORD_HASH="$(echo "$LOGIN_USER_JSON" | jq 'has("password_hash")')"
cv_expect_eq "$LOGIN_USER_HAS_PASSWORD_HASH" "false"

# Use the issued token to access a protected endpoint (GET /cart)
AUTH_HEADER="Authorization: Bearer $LOGIN_TOKEN"
cv_http GET "/cart" "" -H "$AUTH_HEADER"
CV_HTTP_STATUS="$CV_HTTP_STATUS"
cv_expect_eq "$CV_HTTP_STATUS" 200

CART_JSON="$(echo "$CV_HTTP_BODY" | jq -c '.')" || CART_JSON="null"
# The cart router returns an array of items; response shape is not asserted beyond status 200.

# ------------------------- Cleanup -------------------------
cv_step Cleanup "no explicit teardown" "$LINENO"
# No specific teardown is required; the database row can remain for subsequent tests.

echo "CODEVALID_TEST_ASSERTION_OK:login_happy_path_valid_credentials_and_token_usage"
