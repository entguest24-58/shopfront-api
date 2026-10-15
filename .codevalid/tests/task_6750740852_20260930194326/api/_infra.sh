#!/usr/bin/env bash
set -euo pipefail

# Environment defaults for app container
export PORT="${PORT:-6713}"
export DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export WAIT_FOR_TCP="${WAIT_FOR_TCP:-toxiproxy:5432}"
export MIGRATE_CMD="${MIGRATE_CMD:-psql \"$DATABASE_URL\" -v ON_ERROR_STOP=1 -f /app/.codevalid/migrations/001_schema.sql}"
export JWT_SECRET="${JWT_SECRET:-codevalid-test-secret}"
export NODE_ENV="${NODE_ENV:-production}"

# Health URL for tests and helpers
export HEALTH_URL="${HEALTH_URL:-http://app:6713/health}"

# No-op compose controls: compose is managed outside the seed-test container.


# Wait for app health endpoint to report OK.


# Basic failure helper for assertions.

# Equality assertion helper.
# Usage: cv_expect_eq "expected" "actual" "optional message"

# Assert that an HTTP status code matches expectation.
# Usage: cv_expect_status 200 "$status"

# --- CodeValid diagnosis markers (parsed by the test runner; do not edit) ---
# cv_step  <Given|When|Then|Cleanup> "<what this section does>" $LINENO
# cv_prereq "<setup being done>" $LINENO
# cv_http  <METHOD> <url|/path> [json-body] [expected-status] [extra curl args, e.g. -H "Authorization: Bearer $T"]
#          performs the request (relative paths go to $BASE_URL), prints REQUEST_*/RESPONSE_*
#          and CV_HTTP|METHOD|url|status|ms, sets CV_HTTP_STATUS CV_HTTP_BODY CV_HTTP_MS
#          CV_HTTP_BODY_FILE CV_HTTP_HEADERS_FILE. Call it directly, never inside $(...).
#          A 3-digit expected-status (with or without a body) is asserted: a different status
#          fails the test via cv_fail. Omit it to assert on $CV_HTTP_STATUS yourself.
# cv_http  <METHOD> <url> <http_status>          (legacy: marker only, right after your own curl)
# cv_fail  "<expected X got Y>" $LINENO           (prints marker, exits 1)
cv_step() { printf 'CV_STEP|%s|%s|line=%s\n' "${1:-}" "${2:-}" "${3:-}"; }
cv_prereq() { printf 'CV_PREREQ|%s|line=%s\n' "${1:-}" "${2:-}"; }
cv_fail() { printf 'CV_ASSERT_FAIL|%s|line=%s\n' "${1:-}" "${2:-}"; exit 1; }
_cv_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_cv_ms_file() { printf '%s/.cv_last_ms.%s' "${TMPDIR:-/tmp}" "$$"; }
# psql without a connection falls back to a local socket seed-test does not have; when
# DATABASE_URL is set and the call names no connection, connect through it.
_cv_is_status() { _cv_is_int "${1:-}" && [ ${#1} -eq 3 ]; }
# --- end CodeValid diagnosis markers ---

start_compose() {
  :
}

stop_compose() {
  :
}

wait_for_app_health() {
  local url="${HEALTH_URL}"
  local timeout="${1:-60}" # seconds
  local start
  start="$(date +%s)"

  while true; do
    if code="$(curl -s -o /dev/null -w '%{http_code}' "$url")"; then
      if [ "$code" = "200" ]; then
        return 0
      fi
    fi

    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      echo "Timed out waiting for health at $url" >&2
      return 1
    fi

    sleep 1
  done
}

cv_fail() {
  local msg="${1:-Assertion failed}"
  echo "$msg" >&2
  return 1
}

cv_expect_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-expected '$expected' but got '$actual'}"

  if [ "$expected" != "$actual" ]; then
    cv_fail "$msg"
  fi
}

cv_expect_status() {
  local expected="$1"
  local actual="$2"
  cv_expect_eq "$expected" "$actual" "expected HTTP status $expected but got $actual"
}

_cv_now_ms() {
  _cv_n=${EPOCHREALTIME:-}
  if [ -n "$_cv_n" ]; then _cv_secs_to_ms "$_cv_n"; return 0; fi
  _cv_n=$(date +%s%3N 2>/dev/null || true)
  _cv_is_int "$_cv_n" || _cv_n=$(( $(date +%s) * 1000 ))
  printf '%s' "$_cv_n"
}

curl() {
  _cv_t0=$(_cv_now_ms)
  _cv_rc=0
  command curl "$@" || _cv_rc=$?
  _cv_t1=$(_cv_now_ms)
  printf '%s' "$((_cv_t1 - _cv_t0))" > "$(_cv_ms_file)" 2>/dev/null || :
  return $_cv_rc
}

psql() {
  if [ -n "${DATABASE_URL:-}" ]; then
    case " $* " in
      *" $DATABASE_URL "*|*" -h "*|*" --host"*|*" -d "*|*" --dbname"*|*"postgres://"*|*"postgresql://"*) ;;
      *) command psql "$DATABASE_URL" "$@"; return $? ;;
    esac
  fi
  command psql "$@"
}

_cv_secs_to_ms() {
  _cv_t=$(printf '%s' "${1:-0}" | tr ',' '.')
  _cv_s=${_cv_t%%.*}
  case "$_cv_t" in *.*) _cv_f=${_cv_t#*.}000 ;; *) _cv_f=000 ;; esac
  _cv_f=${_cv_f%"${_cv_f#???}"}
  while [ "${_cv_f#0}" != "$_cv_f" ]; do _cv_f=${_cv_f#0}; done
  _cv_is_int "$_cv_s" || _cv_s=0
  _cv_is_int "$_cv_f" || _cv_f=0
  printf '%s' "$(( _cv_s * 1000 + _cv_f ))"
}

cv_http() {
  if [ $# -ge 3 ] && [ $# -le 4 ] && _cv_is_status "$3" && { [ $# -eq 3 ] || _cv_is_int "$4"; }      && { [ -n "${4:-}" ] || [ -f "$(_cv_ms_file)" ]; }; then
    _cv_ms=${4:-}
    if [ -z "$_cv_ms" ] && [ -f "$(_cv_ms_file)" ]; then
      _cv_ms=$(cat "$(_cv_ms_file)" 2>/dev/null || true)
      rm -f "$(_cv_ms_file)" 2>/dev/null || :
    fi
    _cv_is_int "$_cv_ms" || _cv_ms=''
    printf 'CV_HTTP|%s|%s|%s%s\n' "$1" "$2" "$3" "${_cv_ms:+|$_cv_ms}"
    return 0
  fi
  _cv_method=${1:-GET}
  _cv_url=${2:-/}
  _cv_data=''
  _cv_expect=''
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  if [ $# -ge 1 ] && ! _cv_is_status "$1"; then
    case "$1" in -*) ;; *) _cv_data=$1; shift ;; esac
  fi
  if [ $# -ge 1 ] && _cv_is_status "$1"; then _cv_expect=$1; shift; fi
  case "$_cv_url" in /*) _cv_url="${BASE_URL:-http://app:6713}$_cv_url" ;; esac
  CV_HTTP_BODY_FILE="${TMPDIR:-/tmp}/cv_http_body.$$"
  CV_HTTP_HEADERS_FILE="${TMPDIR:-/tmp}/cv_http_headers.$$"
  : > "$CV_HTTP_BODY_FILE"; : > "$CV_HTTP_HEADERS_FILE"
  printf 'REQUEST_HEADERS:\n%s %s\n' "$_cv_method" "$_cv_url"
  printf 'REQUEST_BODY:\n%s\n' "$_cv_data"
  if [ -n "$_cv_data" ]; then
    _cv_w=$(command curl -sS -X "$_cv_method" -H 'Content-Type: application/json' --data "$_cv_data" \
      -D "$CV_HTTP_HEADERS_FILE" -o "$CV_HTTP_BODY_FILE" -w '%{http_code} %{time_total}' "$@" "$_cv_url") || true
  else
    _cv_w=$(command curl -sS -X "$_cv_method" \
      -D "$CV_HTTP_HEADERS_FILE" -o "$CV_HTTP_BODY_FILE" -w '%{http_code} %{time_total}' "$@" "$_cv_url") || true
  fi
  CV_HTTP_STATUS=${_cv_w%% *}
  _cv_is_int "$CV_HTTP_STATUS" || CV_HTTP_STATUS=000
  case "$_cv_w" in *' '*) CV_HTTP_MS=$(_cv_secs_to_ms "${_cv_w#* }") ;; *) CV_HTTP_MS=0 ;; esac
  CV_HTTP_BODY=$(cat "$CV_HTTP_BODY_FILE" 2>/dev/null || true)
  printf 'RESPONSE_HEADERS:\n'; cat "$CV_HTTP_HEADERS_FILE" 2>/dev/null || true
  printf 'RESPONSE_BODY:\n%s\n' "$CV_HTTP_BODY"
  rm -f "$(_cv_ms_file)" 2>/dev/null || :
  printf 'CV_HTTP|%s|%s|%s|%s\n' "$_cv_method" "$_cv_url" "$CV_HTTP_STATUS" "$CV_HTTP_MS"
  if [ -n "$_cv_expect" ] && [ "$CV_HTTP_STATUS" != "$_cv_expect" ]; then
    cv_fail "expected HTTP $_cv_expect from $_cv_method $_cv_url got $CV_HTTP_STATUS: $(printf '%s' "$CV_HTTP_BODY" | head -c 300)" ""
  fi
  return 0
}

app_url() {
  echo "http://app:${PORT}"
}

db_psql() {
  # Run psql against $DATABASE_URL with -At for scripting-friendly output.
  # Usage: db_psql "SQL..."
  PGPASSWORD="" psql "$DATABASE_URL" -At -v ON_ERROR_STOP=1 -c "$1"
}

psql_value() {
  # Run a query expected to return a single row and single column,
  # print just that scalar value.
  # Usage: psql_value "SELECT count(*) FROM users;"
  db_psql "$1" | head -n 1 | cut -d'|' -f1
}

wiremock_admin_import_mappings() {
  # No-op for this task: vendor stubs are not required.
  :
}
