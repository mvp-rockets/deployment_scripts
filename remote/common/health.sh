# shellcheck shell=bash
# Post-deploy health gate.
#   health_wait <url> [timeout s]: 0 once <url> answers 2xx; 1 after the timeout.

health_wait() {
  local url=$1 timeout=${2:-${HEALTH_TIMEOUT:-60}} deadline
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -m 5 -o /dev/null "$url" 2>/dev/null && return 0
    sleep "${HEALTH_INTERVAL:-2}"
  done
  return 1
}
