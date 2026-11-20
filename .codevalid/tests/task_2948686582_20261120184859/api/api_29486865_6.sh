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
cv_step Given "a product with reviews from three buyers posted in sequence and a non-buyer signed in" $LINENO
create_product p
RATINGS=(5 2 4)
IDS=()
for i in 0 1 2; do
  register_and_login "b$i"
  place_order "$USER_ID" "$PRODUCT_ID"
  IDS+=("$USER_ID")
  cv_http POST "/products/$PRODUCT_ID/reviews" "$(jq -nc --argjson r "${RATINGS[$i]}" --arg c "review $i" '{rating:$r,comment:$c}')" -H "Authorization: Bearer $TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 seeding review $i got $CV_HTTP_STATUS" $LINENO
  sleep 0.05
done
register_and_login nonbuyer
NB_TOKEN="$TOKEN"
EXPECTED_ORDER="$(jq -nc --argjson a "${IDS[2]}" --argjson b "${IDS[1]}" --argjson c "${IDS[0]}" '[$a,$b,$c]')"

# When
cv_step When "an anonymous visitor and a signed-in non-buyer list the product's reviews" $LINENO
cv_http GET "/products/$PRODUCT_ID/reviews"
SA="$CV_HTTP_STATUS"; BA="$CV_HTTP_BODY"
cv_http GET "/products/$PRODUCT_ID/reviews" -H "Authorization: Bearer $NB_TOKEN"
SN="$CV_HTTP_STATUS"; BN="$CV_HTTP_BODY"

# Then
cv_step Then "both get newest-first reviews with average 3.7 and count 3" $LINENO
[ "$SA" = "200" ] || cv_fail "expected 200 for anonymous list got $SA" $LINENO
[ "$SN" = "200" ] || cv_fail "expected 200 for non-buyer list got $SN" $LINENO
[ "$(jq -r '.count' <<<"$BA")" = "3" ] || cv_fail "expected count 3 got $(jq -r '.count' <<<"$BA")" $LINENO
# (5+2+4)/3 = 3.666..
AVG_OK="$(jq -r '(.average - 11/3) | fabs < 0.051' <<<"$BA")"
[ "$AVG_OK" = "true" ] || cv_fail "expected average ~3.67 got $(jq -r '.average' <<<"$BA")" $LINENO
ORDER="$(jq -c '[.reviews[].user_id]' <<<"$BA")"
[ "$ORDER" = "$EXPECTED_ORDER" ] || cv_fail "expected newest-first order $EXPECTED_ORDER got $ORDER" $LINENO
NORM_A="$(jq -cS '{average, count, reviews}' <<<"$BA")"
NORM_N="$(jq -cS '{average, count, reviews}' <<<"$BN")"
[ "$NORM_A" = "$NORM_N" ] || cv_fail "expected non-buyer to see same result as anonymous; got $NORM_N vs $NORM_A" $LINENO

# Cleanup
cv_step Cleanup "remove created reviews, orders, users and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_29486865_6"
