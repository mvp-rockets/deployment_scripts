# shellcheck shell=bash
# The npm scripts init_api.sh runs, checked in the service's package.json before anything
# runs: a missing one would fail the deploy midway, after the migrations before it had run.
# deploy-api.sh calls the check on the laptop before the build and the first sync, init_api.sh
# again in its preflight (pipeline deploys, projects on an older laptop half).
#
#   npm_scripts_required <service dir>   the scripts, one a line
#   npm_scripts_check <service dir>      fails naming the missing ones
#
# The list: with tsconfig.json, load-secrets migration:run migration:seed; else (the older
# template) build:env db:migrate db:seed:all. A project whose init_api.sh is its own sets
# NPM_SCRIPTS_REQUIRED (space-separated) in scripts/env/.env.<env>, which both halves read.

npm_scripts_required() {
  local -a list
  if [[ -n ${NPM_SCRIPTS_REQUIRED:-} ]]; then
    read -ra list <<<"$NPM_SCRIPTS_REQUIRED"
  elif [[ -f $1/tsconfig.json ]]; then
    list=(load-secrets migration:run migration:seed)
  else
    list=(build:env db:migrate db:seed:all)
  fi
  printf '%s\n' "${list[@]}"
}

npm_scripts_check() {
  local dir=$1 pkg=$1/package.json required missing
  if ! jq -e 'type == "object" and ((.scripts // {}) | type == "object")' "$pkg" >/dev/null 2>&1; then
    echo "npm scripts: $pkg is missing or isn't a package.json" >&2
    return 1
  fi
  required=$(npm_scripts_required "$dir")
  # shellcheck disable=SC2016  # jq's $s and $p
  missing=$(jq -Rr --slurpfile p "$pkg" '. as $s | select(($p[0].scripts // {}) | has($s) | not)' <<<"$required")
  if [[ -z $missing ]]; then
    echo "npm scripts: ok ($(paste -sd' ' <<<"$required"))"
    return 0
  fi
  cat >&2 <<EOF
npm scripts missing from $pkg: $(paste -sd' ' <<<"$missing")
The deploy runs: $(paste -sd' ' <<<"$required"). Fix one of:
  - add the missing scripts to package.json, or
  - set NPM_SCRIPTS_REQUIRED in scripts/env/.env.<env> to what the project's own init_api.sh runs.
EOF
  return 1
}
