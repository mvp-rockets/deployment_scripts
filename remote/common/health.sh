# shellcheck shell=bash
# Post-deploy health gate.
#   health_wait <url> [timeout s]: 0 once <url> answers 2xx; 1 after the timeout.
#   health_wait_commit <url> <sha> [timeout s]: 0 once <url> answers 2xx with a line
#     commit=<sha>... (a version.txt naming that commit: its full SHA starts with the short
#     one); 1 after the timeout.
#   health_check_for <url> <sha> [timeout s]: health_wait_commit for a URL whose path ends in
#     /version.txt, else health_wait.

health_wait() {
  local url=$1 timeout=${2:-${HEALTH_TIMEOUT:-60}} deadline
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -m 5 -o /dev/null "$url" 2>/dev/null && return 0
    sleep "${HEALTH_INTERVAL:-2}"
  done
  return 1
}

health_wait_commit() {
  local url=$1 sha=$2 timeout=${3:-${HEALTH_TIMEOUT:-60}} deadline body
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if body=$(curl -fsS -m 5 -H 'Cache-Control: no-cache' "$url" 2>/dev/null) \
        && [[ $'\n'$body == *$'\n'"commit=$sha"* ]]; then
      return 0
    fi
    sleep "${HEALTH_INTERVAL:-2}"
  done
  return 1
}

health_check_for() {
  local url=$1 path=${1%%[?#]*}
  if [[ $path == */version.txt ]]; then
    health_wait_commit "$url" "$2" "${3:-}"
  else
    health_wait "$url" "${3:-}"
  fi
}
