#!/bin/sh
# Smoke test for a deployed MoneyPrinterTurbo template: health, the web UI
# login, the session cookie, and the API key.
#
# Usage:
#   sh scripts/smoke-test.sh <url> <webui-password> <api-key> [webui-username]
#
# It makes no videos and spends nothing.
set -eu

USAGE="usage: smoke-test.sh <url> <webui-password> <api-key> [webui-username]"
URL="${1:?$USAGE}"
PASSWORD="${2:?$USAGE}"
KEY="${3:?$USAGE}"
USERNAME="${4:-admin}"
URL="${URL%/}"
fails=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (expected $2, got $3)"; fails=$((fails + 1)); fi
}
code() { curl -s -o /dev/null -m 30 -w '%{http_code}' "$@"; }

echo "Testing $URL"
check "health check answers without a login"       200 "$(code "$URL/healthz")"
check "web UI refuses a visitor with no login"     401 "$(code "$URL/")"
check "web UI refuses a wrong password"            401 "$(code -u "$USERNAME:wrong-password" "$URL/")"
check "web UI internals are not reachable either"  401 "$(code "$URL/_stcore/health")"
check "web UI accepts the login"                   200 "$(code -u "$USERNAME:$PASSWORD" "$URL/")"

cookie=$(curl -s -m 30 -D - -o /dev/null -u "$USERNAME:$PASSWORD" "$URL/" \
  | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(mpt_session=[a-f0-9]*\).*/\1/p' | head -n 1)
if [ -n "$cookie" ]; then
  check "session cookie opens the web UI (Safari)" 200 "$(code -H "Cookie: $cookie" "$URL/")"
  check "a forged session cookie is refused"       401 "$(code -H "Cookie: ${cookie}0" "$URL/")"
else
  echo "  FAIL no session cookie after login"; fails=$((fails + 1))
fi

check "API docs are served"                         200 "$(code "$URL/docs")"
check "API refuses a request with no key"           401 "$(code "$URL/api/v1/tasks")"
check "API refuses a wrong key"                     401 "$(code -H 'x-api-key: wrong' "$URL/api/v1/tasks")"
check "API accepts the key"                         200 "$(code -H "x-api-key: $KEY" "$URL/api/v1/tasks")"
check "generated files need the key too"            401 "$(code "$URL/tasks/none.mp4")"
check "the web UI login does not open the API"      401 "$(code -u "$USERNAME:$PASSWORD" "$URL/api/v1/tasks")"

music=$(curl -s -m 30 -H "x-api-key: $KEY" "$URL/api/v1/musics" | tr -d ' \n')
case "$music" in
  *'"files":[]'*) echo "  ok   no bundled background music" ;;
  *'"files":['*)  echo "  note background music present (your own uploads)" ;;
  *)              echo "  FAIL could not list background music: $music"; fails=$((fails + 1)) ;;
esac

if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$fails check(s) failed."
  exit 1
fi
