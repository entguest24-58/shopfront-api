#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="reviewPass123"
CREATED_USERS=()
CREATED_PRODUCTS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "$1"; }

# register_and_login <label> -> sets USER_ID and TOKEN
register_and_login() {
  local email="rev_${1}_${SUFFIX}@example.com"
  cv_prereq "register and log in user $1" $LINENO
  cv_http POST /auth/register "$(jq -nc --arg e "$email" --arg p "$PASSWORD" --arg n "Reviewer $1" '{email:$e,password:$p,name:$n}')"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID="$(jq -r '.id' <<<"$CV_HTTP_BODY")"
  CREATED_USERS+=("$USER_ID")
  cv_http POST /auth/login "$(jq -nc --arg e "$email" --arg p "$PASSWORD" '{email:$e,password:$p}')"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN="$(jq -r '.token' <<<"$CV_HTTP_BODY")"
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
}

# create_product <label> -> sets PRODUCT_ID
create_product() {
  cv_prereq "insert product $1" $LINENO
  PRODUCT_ID="$(sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('REV-$1-$SUFFIX', 'Review product $1', 'test', 1000, 10) RETURNING id" | head -n1)"
  _cv_is_int "$PRODUCT_ID" || cv_fail "expected a product id got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCTS+=("$PRODUCT_ID")
}

# place_order <user_id> <product_id>
place_order() {
  cv_prereq "record an order of product $2 for user $1" $LINENO
  local oid
  oid="$(sql "INSERT INTO orders (user_id, subtotal_cents, tax_cents, total_cents) VALUES ($1, 1000, 80, 1080) RETURNING id" | head -n1)"
  _cv_is_int "$oid" || cv_fail "expected an order id got '$oid'" $LINENO
  sql "INSERT INTO order_items (order_id, product_id, name, unit_price_cents, quantity) VALUES ($oid, $2, 'Review product', 1000, 1)" >/dev/null
}

cleanup_all() {
  local p u
  for p in "${CREATED_PRODUCTS[@]}"; do
    sql "DELETE FROM product_reviews WHERE product_id = $p" >/dev/null || true
  done
  for u in "${CREATED_USERS[@]}"; do
    sql "DELETE FROM product_reviews WHERE user_id = $u; DELETE FROM orders WHERE user_id = $u; DELETE FROM cart_items WHERE user_id = $u; DELETE FROM users WHERE id = $u" >/dev/null || true
  done
  for p in "${CREATED_PRODUCTS[@]}"; do
    sql "DELETE FROM order_items WHERE product_id = $p; DELETE FROM products WHERE id = $p" >/dev/null || true
  done
}

# Given
cv_step Given "a buyer who has ordered two products" $LINENO
register_and_login buyer
BUYER_ID="$USER_ID"; BUYER_TOKEN="$TOKEN"
create_product a; PA="$PRODUCT_ID"
create_product b; PB="$PRODUCT_ID"
place_order "$BUYER_ID" "$PA"
place_order "$BUYER_ID" "$PB"
LONG="$(printf 'x%.0s' $(seq 1 1000))"
[ "${#LONG}" = "1000" ] || cv_fail "expected 1000-char comment got ${#LONG}" $LINENO

# When
cv_step When "the buyer posts rating 1 with no comment and rating 5 with a 1000-character comment" $LINENO
cv_http POST "/products/$PA/reviews" '{"rating":1}' -H "Authorization: Bearer $BUYER_TOKEN"
S1="$CV_HTTP_STATUS"; B1="$CV_HTTP_BODY"
cv_http POST "/products/$PB/reviews" "$(jq -nc --arg c "$LONG" '{rating:5,comment:$c}')" -H "Authorization: Bearer $BUYER_TOKEN"
S2="$CV_HTTP_STATUS"; B2="$CV_HTTP_BODY"

# Then
cv_step Then "both reviews are accepted and stored as sent" $LINENO
[ "$S1" = "201" ] || cv_fail "expected 201 for rating 1 without comment got $S1: $B1" $LINENO
[ "$S2" = "201" ] || cv_fail "expected 201 for rating 5 with 1000-char comment got $S2: $(head -c 200 <<<"$B2")" $LINENO
[ "$(jq -r '.rating' <<<"$B1")" = "1" ] || cv_fail "expected rating 1 got $(jq -r '.rating' <<<"$B1")" $LINENO
[ "$(jq -r '.comment' <<<"$B1")" = "" ] || cv_fail "expected empty comment got '$(jq -r '.comment' <<<"$B1")'" $LINENO
[ "$(jq -r '.rating' <<<"$B2")" = "5" ] || cv_fail "expected rating 5 got $(jq -r '.rating' <<<"$B2")" $LINENO
[ "$(jq -r '.comment' <<<"$B2")" = "$LONG" ] || cv_fail "expected the 1000-char comment returned unchanged" $LINENO
cv_http GET "/products/$PA/reviews"
R="$(jq -c --argjson u "$BUYER_ID" '[.reviews[] | select(.user_id == $u) | {rating, comment}]' <<<"$CV_HTTP_BODY")"
[ "$R" = '[{"rating":1,"comment":""}]' ] || cv_fail "expected stored [{rating:1,comment:\"\"}] got $R" $LINENO
cv_http GET "/products/$PB/reviews"
R2R="$(jq -r --argjson u "$BUYER_ID" '[.reviews[] | select(.user_id == $u)] | length' <<<"$CV_HTTP_BODY")"
[ "$R2R" = "1" ] || cv_fail "expected one stored review on product B got $R2R" $LINENO
R2C="$(jq -r --argjson u "$BUYER_ID" '.reviews[] | select(.user_id == $u) | .comment' <<<"$CV_HTTP_BODY")"
[ "$(jq -r --argjson u "$BUYER_ID" '.reviews[] | select(.user_id == $u) | .rating' <<<"$CV_HTTP_BODY")" = "5" ] || cv_fail "expected stored rating 5 on product B" $LINENO
[ "$R2C" = "$LONG" ] || cv_fail "expected stored comment of 1000 chars got ${#R2C} chars" $LINENO

# Cleanup
cv_step Cleanup "remove created reviews, orders, users and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_29486865_2"
