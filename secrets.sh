#!/usr/bin/env bash
# A project's secret values in Secrets Manager and its generated manifest (ADR 0053): one secret
# per project, environment and service, <project>-<env>-<service>, a JSON object of keys; the
# container (KMS key, tags, the app role's read) is Terraform's. Lives in the project's scripts/
# beside env.sh; runs with the caller's AWS credentials (AWS_PROFILE or --profile). Devops run it
# from infra-e2e-shared-platform through scripts/secrets.sh, on a checkout of the project.
#
#   secrets.sh <env> push <file.env|file.json>   the file's keys with non-empty values into the
#                                                secret (added or updated; empty values ignored);
#                                                their names into the service's manifest list
#   secrets.sh <env> export <file>               the current keys and values into a new <file>
#                                                (.json, else KEY=value lines), to edit and push
#   secrets.sh <env> delete KEY...               the keys out of the secret and the manifest list
#   secrets.sh <env> reload                      the live release re-reads the secret, over the
#                                                deploy's SSH (scripts/remote/current/reload_secrets.sh)
#   secrets.sh <env> keys                        key names (and how they differ from the manifest)
#   secrets.sh <env> manifest                    the service's manifest list set to the secret's
#                                                key names (the secret is only read): a project
#                                                whose secret predates its manifest
#   secrets.sh <env> diff <other env>            key names in one environment only
#
# Options: --service <name> (default api), --yes (no confirmation), --profile <aws profile>.
# Secret id: <project>-<env>-<service>, the project from SECRETS_PROJECT (devops' wrapper), else
# services.json's projectName; for api, AWS_SM_SECRET_ID in scripts/env/.env.<env> comes first.
# The manifest, scripts/secrets-manifest.json ({"<service>": [KEY, ...]}), is committed with the
# code: a deploy fails while the environment's secret lacks a key in its service's list.
# Every write reads the current secret with its version, applies the change, refuses if the
# secret changed meanwhile, and writes the whole object; values pass through a private temp
# directory, never argv, the output or the checkout.
set -euo pipefail
export LC_ALL=C  # one sort order for comm

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${SECRETS_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}
MANIFEST=$PROJECT_DIR/scripts/secrets-manifest.json

usage() { sed -n '/^#   secrets.sh/,/^# Options/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "secrets: $*" >&2; exit 1; }

YES='' SERVICE=api
args=()
while (($#)); do
  case $1 in
    --yes) YES=1 ;;
    --profile|--service)
      [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value"
      case $1 in
        --profile) export AWS_PROFILE=$2 ;;
        --service) SERVICE=$2 ;;
      esac
      shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *) args+=("$1") ;;
  esac
  shift
done
((${#args[@]} >= 2)) || usage 1
APP_ENV=${args[0]} CMD=${args[1]}
ARGS=("${args[@]:2}")
[[ $SERVICE =~ ^[a-z0-9-]+$ ]] || die "bad service name '$SERVICE'"
[[ $APP_ENV =~ ^[A-Za-z0-9_-]+$ ]] || die "bad environment name '$APP_ENV'"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/secrets.XXXXXX")
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
umask 077

secret_id() {  # secret_id <env>
  local env=$1 file="$PROJECT_DIR/scripts/env/.env.$1" id='' project=${SECRETS_PROJECT:-}
  if [[ -z $project && $SERVICE == api && -f $file ]]; then
    id=$(sed -n 's/^AWS_SM_SECRET_ID=//p' "$file" | sed -n 1p | tr -d "\"'")
  fi
  if [[ -n $id ]]; then
    echo "$id"
    return
  fi
  if [[ -z $project ]]; then
    [[ -f $PROJECT_DIR/services.json ]] || die "no services.json in $PROJECT_DIR"
    project=$(jq -r '.projectName // empty' "$PROJECT_DIR/services.json")
    [[ -n $project ]] || die "no projectName in services.json"
  fi
  echo "$project-$env-$SERVICE"
}

fetch() {  # fetch <secret id> <prefix>: <prefix>.json (the object), <prefix>.version, <prefix>.arn
  if aws secretsmanager get-secret-value --secret-id "$1" --output json >"$2.resp" 2>"$2.err"; then
    jq -r .ARN "$2.resp" >"$2.arn"
    jq -r .VersionId "$2.resp" >"$2.version"
    jq -e '.SecretString | fromjson | type == "object"' "$2.resp" >/dev/null 2>&1 \
      || die "$1 is not a JSON object"
    jq -S '.SecretString | fromjson' "$2.resp" >"$2.json"
  elif aws secretsmanager describe-secret --secret-id "$1" --output json >"$2.resp" 2>/dev/null \
      && jq -e '[.VersionIdsToStages // {} | .[][]] | index("AWSCURRENT") | not' "$2.resp" >/dev/null; then
    jq -r .ARN "$2.resp" >"$2.arn"  # a container Terraform created, with no value yet
    : >"$2.version"
    echo '{}' >"$2.json"
  else
    die "can't read $1: $(cat "$2.err")"
  fi
  rm -f "$2.resp" "$2.err"
}

# --- the manifest: {"<service>": [KEY, ...]}, sorted; ADR 0020's {"services": {...}} is
# rewritten in this form (each service's required keys) at the first change ---

manifest_json() {  # the manifest in the current form, on stdout ({} without one)
  if [[ ! -f $MANIFEST ]]; then
    echo '{}'
  else
    jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || die "$MANIFEST is not a JSON object"
    jq -S 'if has("services") and (.services | type == "object")
           then .services | map_values(.required // [] | unique) else . end' "$MANIFEST"
  fi
}

manifest_list() {  # this service's keys, one per line
  manifest_json | jq -r --arg s "$SERVICE" '.[$s] // [] | .[]'
}

# manifest_change add|remove|set KEY...: the keys into or out of this service's list, or the list
# replaced by them. The file is rewritten in place (it keeps its mode) and only when its content
# changes.
manifest_change() {
  local op=$1
  shift
  manifest_json | jq -S --indent 2 --arg s "$SERVICE" --arg op "$op" --args '
    .[$s] = (if $op == "add" then ((.[$s] // []) + $ARGS.positional)
             elif $op == "set" then $ARGS.positional
             else ((.[$s] // []) - $ARGS.positional) end | unique)' \
    "$@" >"$TMP/manifest.json"
  if [[ -f $MANIFEST ]] && cmp -s "$TMP/manifest.json" "$MANIFEST"; then
    return 0
  fi
  [[ -f $MANIFEST ]] || (umask 022; : >"$MANIFEST")
  cat "$TMP/manifest.json" >"$MANIFEST"
  echo "manifest: $SERVICE's list updated ($MANIFEST): commit it with the code that reads these keys"
}

# Shows what changes (key names only), asks, checks the version, writes; no change, no write.
write() {  # write <secret id>  (reads $TMP/cur.*, $TMP/new.json)
  local id=$1 added changed removed now answer
  added=$(jq -r --slurpfile c "$TMP/cur.json" 'keys - ($c[0] | keys) | .[]' "$TMP/new.json")
  removed=$(jq -r --slurpfile n "$TMP/new.json" 'keys - ($n[0] | keys) | .[]' "$TMP/cur.json")
  changed=$(jq -r --slurpfile c "$TMP/cur.json" \
    'to_entries[] | .key as $k | select(($c[0] | has($k)) and $c[0][$k] != .value) | $k' "$TMP/new.json")
  if [[ -z $added$changed$removed ]]; then
    echo "secrets: no change to $id"
    return 0
  fi
  echo "secret:  $(cat "$TMP/cur.arn")"
  [[ -z $added ]] || echo "added:   $(paste -sd' ' <<<"$added")"
  [[ -z $changed ]] || echo "changed: $(paste -sd' ' <<<"$changed")"
  [[ -z $removed ]] || echo "removed: $(paste -sd' ' <<<"$removed")"
  confirm "Write to $id?"
  now=$(aws secretsmanager describe-secret --secret-id "$id" --output json \
    | jq -r '.VersionIdsToStages // {} | to_entries[] | select(.value | index("AWSCURRENT")) | .key')
  [[ $now == "$(cat "$TMP/cur.version")" ]] \
    || die "$id changed since it was read (version $now): nothing written; run again"
  aws secretsmanager put-secret-value --secret-id "$id" --secret-string "file://$TMP/new.json" \
    --output json --query VersionId >/dev/null
  echo "secrets: written; the app reads it at its next deploy, or now with: secrets.sh $APP_ENV reload$([[ $SERVICE == api ]] || echo " --service $SERVICE")"
}

confirm() {  # confirm <question>
  local answer
  [[ -z $YES ]] || return 0
  [[ -t 0 ]] || die "not a terminal: pass --yes"
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] ]] || die "nothing done"
}

# read_file <file> <out>: an env or JSON file's keys and values as a JSON object of strings;
# empty values dropped (their names in $TMP/empty).
read_file() {
  local file=$1 out=$2
  [[ -f $file ]] || die "no file $file"
  case $file in
    *.json)
      jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file is not a JSON object"
      jq -S 'map_values(if . == null then "" elif type == "string" then . else tostring end)' "$file" >"$TMP/in.json" ;;
    *)  # KEY=value lines: comments, blank lines and `export ` dropped; a "double-quoted" value
        # read as a JSON string (\n, \", \\) when it is one, else its quotes removed; 'single'
        # quotes removed; a trailing CR dropped. One value per line.
      sed -n -E 's/\r$//; s/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/\2\t\3/p' "$file" \
        | jq -S -R -n '[inputs | (index("\t")) as $i | {key: .[:$i], value: (.[$i+1:]
            | . as $v | if test("^\".*\"$") then (try fromjson catch $v[1:-1])
              elif test("^'"'"'.*'"'"'$") then .[1:-1] else . end)}] | from_entries' >"$TMP/in.json" ;;
  esac
  jq -e 'keys | all(test("^[A-Za-z_][A-Za-z0-9_]*$"))' "$TMP/in.json" >/dev/null \
    || die "$file has key names that aren't [A-Za-z_][A-Za-z0-9_]*"
  jq -r 'to_entries[] | select(.value == "") | .key' "$TMP/in.json" >"$TMP/empty"
  jq -S 'with_entries(select(.value != ""))' "$TMP/in.json" >"$out"
  rm -f "$TMP/in.json"
}

reload() {  # the deploy's SSH (the project's incl.sh and env file) runs reload_secrets.sh in the live release
  local remote=$PROJECT_DIR/scripts/remote/current/reload_secrets.sh
  [[ -f $remote ]] || die "no $remote: update the project's scripts/ (deployment_scripts)"
  [[ -f $PROJECT_DIR/scripts/env/.env.$APP_ENV ]] || die "no scripts/env/.env.$APP_ENV in $PROJECT_DIR"
  confirm "Reload $SERVICE in $APP_ENV with its secret's current values (pm2 reload, health gate)?"
  (
    set +u
    cd "$PROJECT_DIR"
    export SCRIPT_DIR=$PROJECT_DIR/scripts
    # shellcheck source=/dev/null  # the project's copy, sourced in this subshell only
    source "$SCRIPT_DIR/incl.sh"
    load_vars "$SCRIPT_DIR/env/.env.$APP_ENV"
    export_vars
    export DEPLOY_SERVICE=$SERVICE
    sync "/scripts/remote/common/*" "/$SERVICE/"
    sync "/scripts/remote/current/reload_secrets.sh" "/$SERVICE/current/"
    run_remote "/$SERVICE/current" reload_secrets.sh
  )
}

case $CMD in
  keys)
    ((${#ARGS[@]} == 0)) || die "keys takes no arguments"
    ID=$(secret_id "$APP_ENV")
    fetch "$ID" "$TMP/cur"
    jq -r 'keys[]' "$TMP/cur.json"
    missing=$(comm -13 <(jq -r 'keys[]' "$TMP/cur.json") <(manifest_list | sort))
    extra=$(comm -23 <(jq -r 'keys[]' "$TMP/cur.json") <(manifest_list | sort))
    [[ -z $missing ]] || echo "secrets: in the manifest, not in $ID (a deploy fails): $(paste -sd' ' <<<"$missing")" >&2
    [[ -z $extra ]] || echo "secrets: in $ID, not in the manifest: $(paste -sd' ' <<<"$extra")" >&2
    ;;
  manifest)
    ((${#ARGS[@]} == 0)) || die "manifest takes no arguments"
    ID=$(secret_id "$APP_ENV")
    fetch "$ID" "$TMP/cur"
    [[ $(jq length "$TMP/cur.json") -gt 0 ]] || die "$ID has no keys: push its values first"
    added=$(comm -23 <(jq -r 'keys[]' "$TMP/cur.json") <(manifest_list | sort))
    removed=$(comm -13 <(jq -r 'keys[]' "$TMP/cur.json") <(manifest_list | sort))
    [[ -z $added ]] || echo "listed:   $(paste -sd' ' <<<"$added")"
    [[ -z $removed ]] || echo "unlisted: $(paste -sd' ' <<<"$removed")"
    mapfile -t names < <(jq -r 'keys[]' "$TMP/cur.json")
    manifest_change set "${names[@]}"
    [[ -n $added$removed ]] || echo "manifest: $SERVICE's list already matches $ID"
    ;;
  push)
    ((${#ARGS[@]} == 1)) || die "push takes one file"
    read_file "${ARGS[0]}" "$TMP/push.json"
    [[ ! -s $TMP/empty ]] || echo "ignored (empty): $(paste -sd' ' "$TMP/empty")"
    [[ $(jq length "$TMP/push.json") -gt 0 ]] || die "${ARGS[0]} has no keys with values"
    ID=$(secret_id "$APP_ENV")
    fetch "$ID" "$TMP/cur"
    jq -S --slurpfile p "$TMP/push.json" '. + $p[0]' "$TMP/cur.json" >"$TMP/new.json"
    write "$ID"
    mapfile -t pushed < <(jq -r 'keys[]' "$TMP/push.json")
    manifest_change add "${pushed[@]}"
    ;;
  export)
    ((${#ARGS[@]} == 1)) || die "export takes one file"
    file=${ARGS[0]}
    [[ ! -e $file ]] || die "$file exists: export writes a new file"
    ID=$(secret_id "$APP_ENV")
    fetch "$ID" "$TMP/cur"
    case $file in
      *.json) jq -S . "$TMP/cur.json" >"$TMP/out" ;;
      *) jq -r 'to_entries[] | "\(.key)=\(.value | if test("^[A-Za-z0-9_./:@+,=-]+$") then . else tojson end)"' \
           "$TMP/cur.json" >"$TMP/out" ;;
    esac
    (set -o noclobber; cat "$TMP/out" >"$file")
    echo "secrets: $(jq length "$TMP/cur.json") keys of $ID in $file (mode 0600): edit, push it back, then delete it"
    ;;
  delete)
    ((${#ARGS[@]} >= 1)) || die "delete takes KEY [KEY...]"
    ID=$(secret_id "$APP_ENV")
    fetch "$ID" "$TMP/cur"
    unknown=$(comm -23 <(printf '%s\n' "${ARGS[@]}" | sort -u) \
      <(sort -u <(jq -r 'keys[]' "$TMP/cur.json") <(manifest_list)))
    [[ -z $unknown ]] || die "not in $ID or the manifest: $(paste -sd' ' <<<"$unknown")"
    jq -S --args 'reduce $ARGS.positional[] as $k (.; del(.[$k]))' "${ARGS[@]}" \
      <"$TMP/cur.json" >"$TMP/new.json"
    write "$ID"
    manifest_change remove "${ARGS[@]}"
    ;;
  reload)
    ((${#ARGS[@]} == 0)) || die "reload takes no arguments"
    reload
    ;;
  diff)
    ((${#ARGS[@]} == 1)) || die "diff takes one other environment"
    [[ ${ARGS[0]} != "$APP_ENV" ]] || die "diff needs two different environments"
    ID=$(secret_id "$APP_ENV")
    other=$(secret_id "${ARGS[0]}")
    fetch "$ID" "$TMP/cur"
    fetch "$other" "$TMP/other"
    only_here=$(comm -23 <(jq -r 'keys[]' "$TMP/cur.json") <(jq -r 'keys[]' "$TMP/other.json"))
    only_there=$(comm -13 <(jq -r 'keys[]' "$TMP/cur.json") <(jq -r 'keys[]' "$TMP/other.json"))
    [[ -z $only_here ]] || echo "only in $APP_ENV: $(paste -sd' ' <<<"$only_here")"
    [[ -z $only_there ]] || echo "only in ${ARGS[0]}: $(paste -sd' ' <<<"$only_there")"
    [[ -n $only_here$only_there ]] || echo "secrets: $APP_ENV and ${ARGS[0]} have the same keys"
    ;;
  *) usage 1 ;;
esac
