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
cv_step Given "a buyer of a product that already has one review from another buyer" $LINENO
register_and_login other
OTHER_ID="$USER_ID"; OTHER_TOKEN="$TOKEN"
register_and_login buyer
BUYER_ID="$USER_ID"; BUYER_TOKEN="$TOKEN"
create_product p
place_order "$OTHER_ID" "$PRODUCT_ID"
place_order "$BUYER_ID" "$PRODUCT_ID"
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":3,"comment":"baseline"}' -H "Authorization: Bearer $OTHER_TOKEN"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 for baseline review got $CV_HTTP_STATUS" $LINENO
cv_http GET "/products/$PRODUCT_ID/reviews"
BEFORE="$(jq -c '{average, count}' <<<"$CV_HTTP_BODY")"
[ "$BEFORE" = '{"average":3,"count":1}' ] || cv_fail "expected baseline {average:3,count:1} got $BEFORE" $LINENO

# When
cv_step When "the buyer posts a rating of 0 and then a rating of 6" $LINENO
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":0,"comment":"zero"}' -H "Authorization: Bearer $BUYER_TOKEN"
S0="$CV_HTTP_STATUS"; B0="$CV_HTTP_BODY"
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":6,"comment":"six"}' -H "Authorization: Bearer $BUYER_TOKEN"
S6="$CV_HTTP_STATUS"; B6="$CV_HTTP_BODY"

# Then
cv_step Then "both are refused with a rating message and nothing changes" $LINENO
[ "$S0" = "400" ] || cv_fail "expected 400 for rating 0 got $S0: $B0" $LINENO
[ "$S6" = "400" ] || cv_fail "expected 400 for rating 6 got $S6: $B6" $LINENO
jq -r '.error // ""' <<<"$B0" | grep -qi 'rating' || cv_fail "expected error mentioning rating for 0 got $B0" $LINENO
jq -r '.error // ""' <<<"$B6" | grep -qi 'rating' || cv_fail "expected error mentioning rating for 6 got $B6" $LINENO
N="$(sql "SELECT count(*) FROM product_reviews WHERE product_id = $PRODUCT_ID AND user_id = $BUYER_ID")"
[ "$N" = "0" ] || cv_fail "expected no stored review for the buyer got $N" $LINENO
cv_http GET "/products/$PRODUCT_ID/reviews"
AFTER="$(jq -c '{average, count}' <<<"$CV_HTTP_BODY")"
[ "$AFTER" = "$BEFORE" ] || cv_fail "expected average/count unchanged $BEFORE got $AFTER" $LINENO

# Cleanup
cv_step Cleanup "remove created reviews, orders, users and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_29486865_3"
