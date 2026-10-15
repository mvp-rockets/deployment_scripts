# shellcheck shell=bash
# Deploy events: one JSON line per event in $NAPSES_DEPLOY_EVENTS (default
# /var/log/napses/deploy-events.jsonl, which the host's log agent ships), and a
# best-effort POST to $DORA_WEBHOOK_URL when set.
#
#   deploy_event <event> [key=value ...]     e.g. deploy_event deploy_end result=failure stage=init
#
# Every line carries ts, event, app, env, service, host, sha, branch, trigger (from
# .env.deploy: PROJECT_NAME, APP_ENV, DEPLOY_SERVICE, GIT_COMMIT, GIT_BRANCH,
# DEPLOY_TRIGGER = pipeline build number or the laptop's git user.email). Numeric values
# become JSON numbers. A failed deploy is any line with result=failure.
# Never fails the deploy: a missing log file or a dead webhook only warns.

deploy_event() {
  local event=$1 kv line file=${NAPSES_DEPLOY_EVENTS:-/var/log/napses/deploy-events.jsonl}
  shift
  line=$(jq -cn --arg ts "$(date -u +%FT%TZ)" --arg event "$event" --arg app "${PROJECT_NAME:-}" \
    --arg env "${APP_ENV:-}" --arg service "${DEPLOY_SERVICE:-}" --arg host "$(hostname)" \
    --arg sha "${GIT_COMMIT:-}" --arg branch "${GIT_BRANCH:-}" --arg trigger "${DEPLOY_TRIGGER:-}" \
    '{ts: $ts, event: $event, app: $app, env: $env, service: $service, host: $host, sha: $sha, branch: $branch, trigger: $trigger}')
  for kv in "$@"; do
    line=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): ($v | tonumber? // $v)}' <<<"$line")
  done
  { printf '%s\n' "$line" >>"$file"; } 2>/dev/null || echo "deploy_event: can't append to $file" >&2
  if [[ -n ${DORA_WEBHOOK_URL:-} ]]; then
    curl -fsS -m 5 -H 'Content-Type: application/json' -d "$line" "$DORA_WEBHOOK_URL" >/dev/null \
      || echo "deploy_event: webhook POST failed" >&2
  fi
  return 0
}

# deploy_started: record the start (for duration_s) and log deploy_start.
deploy_started() {
  date +%s >"${DEPLOYMENT_DIR:-.}/.deploy-started"
  deploy_event deploy_start
}

# deploy_finished <success|failure> [key=value ...]
deploy_finished() {
  local result=$1 started
  shift
  started=$(cat "${DEPLOYMENT_DIR:-.}/.deploy-started" 2>/dev/null || date +%s)
  deploy_event deploy_end result="$result" duration_s=$(( $(date +%s) - started )) "$@"
}
