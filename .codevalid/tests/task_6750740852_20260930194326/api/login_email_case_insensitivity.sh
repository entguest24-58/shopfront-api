#!/usr/bin/env bash
set -euo pipefail

source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

# Case mappings

# | case_id                         | method | path          |
# |---------------------------------|--------|---------------|
# | login_email_case_insensitivity  | POST   | /auth/login   |

# Case: login_email_case_insensitivity

### Preconditions
cv_step "Given compose stack is running and app is healthy" $LINENO
start_compose
wait_for_app_health

cv_prereq "Given database has no conflicting user email for shopper@example.com" $LINENO
# Ensure users table is empty to avoid unique constraint conflicts for this test email.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users;"

cv_prereq "Given a shopper is registered with lowercased email" $LINENO
# Register a shopper using lowercased email, non-empty name, and password >= 8 chars.
REGISTER_BODY='{"email":"shopper@example.com","password":"Password123","name":"Case Test Shopper"}'
cv_http POST /auth/register "$REGISTER_BODY"
if [ "$CV_HTTP_STATUS" -ne 201 ]; then
  cv_fail "expected 201 from POST /auth/register got $CV_HTTP_STATUS" $LINENO
fi

# Assert response contains only public user fields and matches the registration input (email normalized, role default).
REGISTER_USER_ID=$(jq -r '.id' <<<"$CV_HTTP_BODY")
REGISTER_EMAIL=$(jq -r '.email' <<<"$CV_HTTP_BODY")
REGISTER_NAME=$(jq -r '.name' <<<"$CV_HTTP_BODY")
REGISTER_ROLE=$(jq -r '.role' <<<"$CV_HTTP_BODY")
REGISTER_CREATED_AT=$(jq -r '.created_at' <<<"$CV_HTTP_BODY")

if [ "$REGISTER_EMAIL" != "shopper@example.com" ]; then
  cv_fail "expected registered email shopper@example.com got $REGISTER_EMAIL" $LINENO
fi
if [ "$REGISTER_NAME" != "Case Test Shopper" ]; then
  cv_fail "expected registered name Case Test Shopper got $REGISTER_NAME" $LINENO
fi
if [ "$REGISTER_ROLE" != "customer" ]; then
  cv_fail "expected registered role customer got $REGISTER_ROLE" $LINENO
fi
if [ -z "$REGISTER_USER_ID" ] || [ "$REGISTER_USER_ID" = "null" ]; then
  cv_fail "expected non-null user id in registration response" $LINENO
fi
if [ -z "$REGISTER_CREATED_AT" ] || [ "$REGISTER_CREATED_AT" = "null" ]; then
  cv_fail "expected non-null created_at in registration response" $LINENO
fi

# Ensure no password or password-derived fields are present.
if jq -e 'has("password") or has("password_hash")' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "registration response must not contain password or password_hash fields" $LINENO
fi

### When
cv_step "When shopper logs in using same email with different casing and correct password" $LINENO
# Use different casing for the same email; the app normalizes email.trim().toLowerCase() before querying.
LOGIN_BODY='{"email":"Shopper@Example.com","password":"Password123"}'
cv_http POST /auth/login "$LOGIN_BODY"
if [ "$CV_HTTP_STATUS" -ne 200 ]; then
  cv_fail "expected 200 from POST /auth/login with differently cased email got $CV_HTTP_STATUS" $LINENO
fi

### Then
cv_step "Then login succeeds, issuing a valid Bearer token with 2-hour expiry and public user info only" $LINENO
# Extract and assert token fields.
LOGIN_TOKEN=$(jq -r '.token' <<<"$CV_HTTP_BODY")
LOGIN_TOKEN_TYPE=$(jq -r '.token_type' <<<"$CV_HTTP_BODY")
LOGIN_EXPIRES_IN=$(jq -r '.expires_in' <<<"$CV_HTTP_BODY")

if [ -z "$LOGIN_TOKEN" ] || [ "$LOGIN_TOKEN" = "null" ]; then
  cv_fail "expected non-null token in login response" $LINENO
fi
if [ "$LOGIN_TOKEN_TYPE" != "Bearer" ]; then
  cv_fail "expected token_type Bearer got $LOGIN_TOKEN_TYPE" $LINENO
fi
if [ "$LOGIN_EXPIRES_IN" -ne 7200 ]; then
  cv_fail "expected expires_in 7200 got $LOGIN_EXPIRES_IN" $LINENO
fi

# Assert user object matches registered user and exposes only public fields.
LOGIN_USER_ID=$(jq -r '.user.id' <<<"$CV_HTTP_BODY")
LOGIN_USER_EMAIL=$(jq -r '.user.email' <<<"$CV_HTTP_BODY")
LOGIN_USER_NAME=$(jq -r '.user.name' <<<"$CV_HTTP_BODY")
LOGIN_USER_ROLE=$(jq -r '.user.role' <<<"$CV_HTTP_BODY")
LOGIN_USER_CREATED_AT=$(jq -r '.user.created_at' <<<"$CV_HTTP_BODY")

if [ "$LOGIN_USER_ID" != "$REGISTER_USER_ID" ]; then
  cv_fail "expected login user id $REGISTER_USER_ID got $LOGIN_USER_ID" $LINENO
fi
if [ "$LOGIN_USER_EMAIL" != "$REGISTER_EMAIL" ]; then
  cv_fail "expected login email $REGISTER_EMAIL got $LOGIN_USER_EMAIL" $LINENO
fi
if [ "$LOGIN_USER_NAME" != "$REGISTER_NAME" ]; then
  cv_fail "expected login name $REGISTER_NAME got $LOGIN_USER_NAME" $LINENO
fi
if [ "$LOGIN_USER_ROLE" != "$REGISTER_ROLE" ]; then
  cv_fail "expected login role $REGISTER_ROLE got $LOGIN_USER_ROLE" $LINENO
fi
if [ "$LOGIN_USER_CREATED_AT" != "$REGISTER_CREATED_AT" ]; then
  cv_fail "expected login created_at $REGISTER_CREATED_AT got $LOGIN_USER_CREATED_AT" $LINENO
fi

# Ensure user object has no password fields.
if jq -e '.user | has("password") or has("password_hash")' <<<"$CV_HTTP_BODY" >/dev/null 2>&1; then
  cv_fail "login user object must not contain password or password_hash fields" $LINENO
fi

cv_prereq "Then the issued token is accepted on a protected endpoint using Authorization: Bearer <token>" $LINENO
# Use the token on a protected route; src/cart/router.ts applies requireAuth to /cart.
AUTH_HEADER="Authorization: Bearer ${LOGIN_TOKEN}"
cv_http GET /cart "" -H "$AUTH_HEADER"
if [ "$CV_HTTP_STATUS" -ne 200 ]; then
  cv_fail "expected 200 from GET /cart with valid Bearer token got $CV_HTTP_STATUS" $LINENO
fi

### Teardown
cv_step "Cleanup compose stack and reset database" $LINENO
# Optional DB cleanup; not strictly required as compose teardown drops containers.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM cart_items;"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM orders;"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM users;"
stop_compose

echo "CODEVALID_TEST_ASSERTION_OK:login_email_case_insensitivity"
