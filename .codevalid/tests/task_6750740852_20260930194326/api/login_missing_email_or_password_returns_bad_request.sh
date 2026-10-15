#!/usr/bin/env bash
set -euo pipefail

# shellcheck shell=bash

# Setup
source .codevalid/tests/task_6750740852_20260930194326/api/_infra.sh

cv_step "Given" "app is healthy" $LINENO
cv_prereq "wait for app health at HEALTH_URL=${HEALTH_URL:-http://app:6713/health}" $LINENO
wait_for_app_health

# Case: login_missing_email_or_password_returns_bad_request

## Mocks
# (no external vendor calls; no mocks required)

## Preconditions
cv_prereq "no specific user needed; presence/type validation happens before DB access" $LINENO
# No DB seeding is required because the handler returns 400 before querying the database
# when email or password is missing or not a string.

## When
cv_step "When" "POST /auth/login with various missing/invalid email/password combinations" $LINENO

# 1) No JSON body at all
cv_http POST /auth/login
cv_expect_status 400 "$CV_HTTP_STATUS"
ERROR_MSG=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
cv_expect_eq "email and password are required" "$ERROR_MSG"

# Assert no token fields are present
HAS_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token")')
HAS_TOKEN_TYPE=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token_type")')
cv_expect_eq "false" "$HAS_TOKEN"
cv_expect_eq "false" "$HAS_TOKEN_TYPE"

# 2) Body missing email field
BODY_MISSING_EMAIL='{"password":"password123"}'
cv_http POST /auth/login "$BODY_MISSING_EMAIL"
cv_expect_status 400 "$CV_HTTP_STATUS"
ERROR_MSG=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
cv_expect_eq "email and password are required" "$ERROR_MSG"
HAS_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token")')
HAS_TOKEN_TYPE=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token_type")')
cv_expect_eq "false" "$HAS_TOKEN"
cv_expect_eq "false" "$HAS_TOKEN_TYPE"

# 3) Body missing password field
BODY_MISSING_PASSWORD='{"email":"user@example.com"}'
cv_http POST /auth/login "$BODY_MISSING_PASSWORD"
cv_expect_status 400 "$CV_HTTP_STATUS"
ERROR_MSG=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
cv_expect_eq "email and password are required" "$ERROR_MSG"
HAS_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token")')
HAS_TOKEN_TYPE=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token_type")')
cv_expect_eq "false" "$HAS_TOKEN"
cv_expect_eq "false" "$HAS_TOKEN_TYPE"

# 4) Body with non-string email/password types
BODY_NON_STRING='{"email":123,"password":true}'
cv_http POST /auth/login "$BODY_NON_STRING"
cv_expect_status 400 "$CV_HTTP_STATUS"
ERROR_MSG=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
cv_expect_eq "email and password are required" "$ERROR_MSG"
HAS_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token")')
HAS_TOKEN_TYPE=$(printf '%s' "$CV_HTTP_BODY" | jq 'has("token_type")')
cv_expect_eq "false" "$HAS_TOKEN"
cv_expect_eq "false" "$HAS_TOKEN_TYPE"

## Then
cv_step "Then" "all malformed login requests return 400 with error message and no token fields" $LINENO
# The assertions above on each request enforce:
# - HTTP 400 status
# - error == 'email and password are required'
# - no token/token_type fields in the response

echo "CODEVALID_TEST_ASSERTION_OK:login_missing_email_or_password_returns_bad_request"

## Teardown
cv_step "Cleanup" "no teardown required for login validation tests" $LINENO
# No resources to clean up; database state was not modified by these requests.
