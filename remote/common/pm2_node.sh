# shellcheck shell=bash
# pm2 cluster mode runs every worker on pm2's own Node, whatever the app's .nvmrc says
# (ADR 0021). The deploy refuses a cluster-mode app whose .nvmrc names another version.
#
#   pm2_node_version                          pm2's Node, e.g. 24.11.0
#   pm2_cluster_node_check <config> <nvmrc>   fails, naming both versions and the fixes
#
# pm2's Node is the running daemon's binary ($PM2_HOME/pm2.pid); with no daemon, the `node`
# on PATH, which the pm2 CLI's `#!/usr/bin/env node` would start one with (call it before
# `nvm use`). An .nvmrc of `24` or `24.11` matches any 24.x or 24.11.x; an alias (lts/*)
# never does. No .nvmrc, or no cluster-mode app in the config: nothing to check.

pm2_node_version() {
  local pid exe=node
  pid=$(cat "${PM2_HOME:-$HOME/.pm2}/pm2.pid" 2>/dev/null) || pid=
  if [[ $pid =~ ^[0-9]+$ ]] && [[ -x /proc/$pid/exe ]]; then
    exe=/proc/$pid/exe
  fi
  "$exe" --version | sed 's/^v//'
}

pm2_cluster_node_check() {
  local config=$1 nvmrc=$2 apps want have
  [[ -f $nvmrc ]] || return 0
  apps=$(jq -r '[(if type == "array" then .[] elif has("apps") then .apps[] else . end)
                 | select(.exec_mode == "cluster" or .exec_mode == "cluster_mode") | .name] | join(", ")' "$config")
  [[ -n $apps ]] || return 0
  want=$(tr -d '[:space:]' <"$nvmrc")
  want=${want#v}
  have=$(pm2_node_version)
  if [[ $want =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] && [[ $have == "$want" || $have == "$want".* ]]; then
    return 0
  fi
  cat >&2 <<EOF
pm2 cluster mode runs $apps on pm2's Node $have, but .nvmrc says $want.
Fix one of:
  - set .nvmrc to $have (the version every cluster-mode app on this host runs), or
  - run the app in fork mode (exec_mode "fork") in the project's scripts/incl.sh.
EOF
  return 1
}
