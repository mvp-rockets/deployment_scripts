# shellcheck shell=bash
# The secret checked against the app's manifest before load-secrets.
# scripts/secrets-manifest.json in the app repo:
#   {"services": {"api": {"required": ["DB_HOST", ...], "optional": [...]}, "sqs": {...}}}
# Missing required keys for this service fail the deploy. Keys in the secret that no
# service lists fail it too, except on the app's first checked deploy, which only warns
# (and leaves a marker; later deploys enforce).
#
#   secrets_manifest_check <manifest> <secret json file> <service> <marker file>

secrets_manifest_check() {
  local manifest=$1 secret=$2 service=$3 marker=$4 missing extra
  jq -e --arg s "$service" '.services[$s]' "$manifest" >/dev/null \
    || { echo "secrets manifest: no service '$service' in $manifest" >&2; return 1; }
  jq -e 'type == "object"' "$secret" >/dev/null 2>&1 \
    || { echo "secrets manifest: the secret is not a JSON object" >&2; return 1; }
  missing=$(jq -r --arg s "$service" --slurpfile sec "$secret" \
    '(.services[$s].required // []) - ($sec[0] | keys) | .[]' "$manifest")
  extra=$(jq -r --slurpfile sec "$secret" \
    '($sec[0] | keys) - ([.services[] | (.required // []) + (.optional // [])] | add // []) | .[]' "$manifest")
  if [[ -n $missing ]]; then
    echo "secrets manifest: required keys missing from the secret for $service: $(paste -sd' ' <<<"$missing")" >&2
    return 1
  fi
  if [[ -n $extra ]]; then
    if [[ -f $marker ]]; then
      echo "secrets manifest: keys in the secret that the manifest doesn't list: $(paste -sd' ' <<<"$extra")" >&2
      return 1
    fi
    echo "secrets manifest: WARNING (first checked deploy; enforced from the next): unlisted keys: $(paste -sd' ' <<<"$extra")" >&2
  fi
  touch "$marker"
  echo "secrets manifest: ok ($service)"
}

# secrets_fetch <file>: the secret's JSON (key names and values) into <file>, mode 0600.
# Default: the AWS CLI with the app's profile; SECRETS_FETCH_CMD overrides (tests).
secrets_fetch() {
  local out=$1
  (umask 077; if [[ -n ${SECRETS_FETCH_CMD:-} ]]; then
    bash -c "$SECRETS_FETCH_CMD" >"$out"
  else
    aws secretsmanager get-secret-value --secret-id "${AWS_SM_SECRET_ID:?AWS_SM_SECRET_ID not set}" \
      --query SecretString --output text >"$out"
  fi)
}
