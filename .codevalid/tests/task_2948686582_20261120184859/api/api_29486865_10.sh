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
cv_step Given "a victim with a review and a buyer of the same product" $LINENO
create_product p
register_and_login victim
V_ID="$USER_ID"; V_TOKEN="$TOKEN"
register_and_login buyer
B_ID="$USER_ID"; B_TOKEN="$TOKEN"
place_order "$V_ID" "$PRODUCT_ID"
place_order "$B_ID" "$PRODUCT_ID"
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":5,"comment":"victim original"}' -H "Authorization: Bearer $V_TOKEN"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 for victim's review got $CV_HTTP_STATUS" $LINENO
V_BEFORE="$(sql "SELECT id || '|' || rating || '|' || comment || '|' || created_at || '|' || updated_at FROM product_reviews WHERE product_id = $PRODUCT_ID AND user_id = $V_ID")"
T0="$(sql "SELECT extract(epoch FROM now())::bigint")"
FORGED='{"rating":1,"comment":"forged","user_id":'"$V_ID"',"author_id":'"$V_ID"',"product_id":'"$PRODUCT_ID"',"created_at":"2000-01-01T00:00:00Z","updated_at":"2099-01-01T00:00:00Z"}'

# When
cv_step When "the buyer posts a review naming the victim as author with forged dates" $LINENO
cv_http POST "/products/$PRODUCT_ID/reviews" "$FORGED" -H "Authorization: Bearer $B_TOKEN"
S="$CV_HTTP_STATUS"; B="$CV_HTTP_BODY"

# Then
cv_step Then "the review belongs to the buyer with server time and the victim's review is untouched" $LINENO
V_AFTER="$(sql "SELECT id || '|' || rating || '|' || comment || '|' || created_at || '|' || updated_at FROM product_reviews WHERE product_id = $PRODUCT_ID AND user_id = $V_ID")"
[ "$V_AFTER" = "$V_BEFORE" ] || cv_fail "expected victim's review unchanged '$V_BEFORE' got '$V_AFTER'" $LINENO
if [ "$S" = "201" ] || [ "$S" = "200" ]; then
  [ "$(jq -r '.user_id' <<<"$B")" = "$B_ID" ] || cv_fail "expected response user_id $B_ID got $(jq -r '.user_id' <<<"$B")" $LINENO
  ROW="$(sql "SELECT user_id || '|' || abs(extract(epoch FROM created_at)::bigint - $T0) || '|' || abs(extract(epoch FROM updated_at)::bigint - $T0) FROM product_reviews WHERE product_id = $PRODUCT_ID AND comment = 'forged'")"
  [ -n "$ROW" ] || cv_fail "expected the buyer's review stored" $LINENO
  IFS='|' read -r RU DC DU <<<"$ROW"
  [ "$RU" = "$B_ID" ] || cv_fail "expected stored author $B_ID got $RU" $LINENO
  [ "$DC" -le 120 ] || cv_fail "expected created_at near posting time, off by ${DC}s" $LINENO
  [ "$DU" -le 120 ] || cv_fail "expected updated_at near posting time, off by ${DU}s" $LINENO
fi
cv_http GET "/products/$PRODUCT_ID/reviews"
VR="$(jq -c --argjson u "$V_ID" '[.reviews[] | select(.user_id == $u) | {rating, comment}]' <<<"$CV_HTTP_BODY")"
[ "$VR" = '[{"rating":5,"comment":"victim original"}]' ] || cv_fail "expected victim's listed review untouched got $VR" $LINENO
if [ "$S" = "201" ] || [ "$S" = "200" ]; then
  FIRST="$(jq -r '.reviews[0].user_id' <<<"$CV_HTTP_BODY")"
  [ "$FIRST" = "$B_ID" ] || cv_fail "expected buyer's review (just posted) first in newest-first list got user $FIRST" $LINENO
  LISTED_CREATED_YEAR="$(jq -r --argjson u "$B_ID" '.reviews[] | select(.user_id == $u) | .created_at[0:4]' <<<"$CV_HTTP_BODY")"
  [ "$LISTED_CREATED_YEAR" != "2000" ] || cv_fail "expected created_at not backdated got year $LISTED_CREATED_YEAR" $LINENO
fi

# Cleanup
cv_step Cleanup "remove created reviews, orders, users and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_29486865_10"
