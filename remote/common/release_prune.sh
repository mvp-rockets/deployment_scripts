#!/usr/bin/env bash
# Removes hanging releases: releases/<sha> directories that deployment_history doesn't list.
# A deploy creates releases/<sha> before init/start and logs it to deployment_history only
# after both succeed, so every failed deploy leaves one behind; clean_up_old_deployment.sh
# only removes what the history lists.
#
#   release_prune.sh [--dry-run] <service dir>...     one or more <app>/<env>/<service> dirs
#   release_prune.sh [--dry-run] --all [apps root]    every <root>/<app>/<env>/<service> (default $HOME/apps)
#
# A release is kept when any of these holds:
#   - deployment_history lists it
#   - `current` points at it
#   - a process has its working directory inside it (readable /proc only: run as root or the app user)
#   - it changed less than RELEASE_PRUNE_MIN_AGE_MIN minutes ago (default 120; a deploy in
#     progress). Measured by ctime: rsync -a copies mtimes from the laptop, ctime it can't set.
# A service without a deployment_history file is skipped (nothing to compare against).
# Exit 0 unless a removal fails.
set -euo pipefail

dry_run=0
all=0
min_age=${RELEASE_PRUNE_MIN_AGE_MIN:-120}
args=()
for a in "$@"; do
  case $a in
    --dry-run) dry_run=1 ;;
    --all) all=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) args+=("$a") ;;
  esac
done

# Working directories of every process we can see, resolved.
proc_cwds=$(for p in /proc/[0-9]*/cwd; do readlink "$p" 2>/dev/null || true; done | sort -u)

in_use() {   # <release path>
  local rel=$1
  grep -qxF "$rel" <<<"$proc_cwds" && return 0
  grep -qF "$rel/" <<<"$proc_cwds"
}

freed_kb=0
removed=0
failed=0

prune_service() {   # <service dir>
  local svc rel name current now ctime age kb
  svc=$(cd "$1" && pwd -P)
  [[ -d $svc/releases ]] || return 0
  if [[ ! -f $svc/deployment_history ]]; then
    echo "release_prune: skip $svc (no deployment_history)"
    return 0
  fi
  current=$(readlink -f "$svc/current" 2>/dev/null || true)
  now=$(date +%s)
  for rel in "$svc"/releases/*; do
    [[ -d $rel && ! -L $rel ]] || continue
    name=${rel##*/}
    grep -qxF "$name" "$svc/deployment_history" && continue
    [[ $rel == "$current" ]] && continue
    ctime=$(stat -c %Z "$rel")
    age=$(( (now - ctime) / 60 ))
    if (( age < min_age )); then
      echo "release_prune: keep $rel (changed ${age} min ago)"
      continue
    fi
    if in_use "$rel"; then
      echo "release_prune: keep $rel (a process runs in it)"
      continue
    fi
    kb=$(du -sk "$rel" 2>/dev/null | cut -f1); kb=${kb:-0}
    if (( dry_run )); then
      echo "release_prune: would remove $rel (${kb} KB)"
    elif rm -rf -- "$rel"; then
      echo "release_prune: removed $rel (${kb} KB)"
    else
      echo "release_prune: FAILED to remove $rel" >&2
      failed=$((failed + 1))
      continue
    fi
    removed=$((removed + 1))
    freed_kb=$((freed_kb + kb))
  done
}

if (( all )); then
  root=${args[0]:-$HOME/apps}
  # find, not a glob: an unmatched glob would be taken literally
  while IFS= read -r d; do
    prune_service "${d%/releases}"
  done < <(find "$root" -mindepth 4 -maxdepth 4 -type d -name releases -not -path '*/.nm-store/*' | sort)
else
  (( ${#args[@]} )) || { echo "usage: release_prune.sh [--dry-run] <service dir>... | --all [apps root]" >&2; exit 2; }
  for d in "${args[@]}"; do prune_service "$d"; done
fi

verb=removed; (( dry_run )) && verb="would remove"
echo "release_prune: $verb $removed release(s), $(( freed_kb / 1024 )) MB"
(( failed == 0 ))
