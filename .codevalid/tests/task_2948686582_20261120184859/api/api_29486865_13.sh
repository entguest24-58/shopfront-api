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
cv_step Given "buyers A (4 stars) and B (2 stars) have both reviewed the same product" $LINENO
create_product p
register_and_login a
A_ID="$USER_ID"; A_TOKEN="$TOKEN"
register_and_login b
B_ID="$USER_ID"; B_TOKEN="$TOKEN"
place_order "$A_ID" "$PRODUCT_ID"
place_order "$B_ID" "$PRODUCT_ID"
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":4,"comment":"A review"}' 201 -H "Authorization: Bearer $A_TOKEN"
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":2,"comment":"B review"}' 201 -H "Authorization: Bearer $B_TOKEN"
B_BEFORE="$(sql "SELECT id || '|' || rating || '|' || comment || '|' || created_at || '|' || updated_at FROM product_reviews WHERE product_id = $PRODUCT_ID AND user_id = $B_ID")"
[ -n "$B_BEFORE" ] || cv_fail "expected B's review stored" $LINENO

# When
cv_step When "buyer A sends a delete for the product's review, naming buyer B in the body" $LINENO
cv_http DELETE "/products/$PRODUCT_ID/reviews" "{\"user_id\":$B_ID}" -H "Authorization: Bearer $A_TOKEN"
S="$CV_HTTP_STATUS"; B="$CV_HTTP_BODY"

# Then
cv_step Then "only A's review is removed; B's review stays and is still counted" $LINENO
B_AFTER="$(sql "SELECT id || '|' || rating || '|' || comment || '|' || created_at || '|' || updated_at FROM product_reviews WHERE product_id = $PRODUCT_ID AND user_id = $B_ID")"
[ "$B_AFTER" = "$B_BEFORE" ] || cv_fail "expected B's review unchanged '$B_BEFORE' got '$B_AFTER' (delete status $S)" $LINENO
cv_http GET "/products/$PRODUCT_ID/reviews" 200
BR="$(jq -c --argjson u "$B_ID" '[.reviews[] | select(.user_id == $u) | {rating, comment}]' <<<"$CV_HTTP_BODY")"
[ "$BR" = '[{"rating":2,"comment":"B review"}]' ] || cv_fail "expected B's review still listed got $BR" $LINENO
AR="$(jq -r --argjson u "$A_ID" '[.reviews[] | select(.user_id == $u)] | length' <<<"$CV_HTTP_BODY")"
[ "$AR" = "0" ] || cv_fail "expected A's review removed got $AR listed (delete status $S)" $LINENO
[ "$(jq -c '{average, count}' <<<"$CV_HTTP_BODY")" = '{"average":2,"count":1}' ] || cv_fail "expected {average:2,count:1} got $(jq -c '{average, count}' <<<"$CV_HTTP_BODY")" $LINENO

# Cleanup
cv_step Cleanup "remove created reviews, orders, users and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_29486865_13"
