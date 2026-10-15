# shellcheck shell=bash
# node_modules reuse across releases: a lockfile-keyed store.
#
#   . nm_store.sh; nm_store_install <release dir> <app>    # instead of `npm ci`
#   . nm_store.sh; nm_store_gc                              # drop entries no kept release uses
#
# Key = sha256(lockfile + package.json + node version + tool + install flags). On a miss the
# install runs once, in the release, and its node_modules moves to $NM_STORE/<app>/<key>/
# (same filesystem: a rename); every release, that one included, then gets a hard-link copy
# (`cp -al`): near-zero disk, seconds. Relative symlinks (npm's file: directories) resolve
# in every release, whose layout is the same. Not in the key: anything a postinstall step
# generates from repo files (none of the qa2 apps does, no Prisma): such an app
# must not use the store. Store files
# are made read-only: a release shares their inodes, so writing one in place would change
# the store (and every release using it); read-only makes that fail loudly instead.
# Each release records its key in <release>/.nm-store-key for the GC.
#
# Settings (environment):
#   NM_STORE          store root            default $HOME/apps/.nm-store
#   NM_INSTALL_FLAGS  extra install flags   e.g. "--include=dev" (part of the key)
#   NM_GC_MIN_AGE_MIN GC spares entries younger than this (a deploy in progress)   default 120

nm_store_root() { printf '%s\n' "${NM_STORE:-$HOME/apps/.nm-store}"; }

# nm_store_tool <dir>: npm or pnpm, from the lockfile present.
nm_store_tool() {
  if [[ -f $1/pnpm-lock.yaml ]]; then echo pnpm
  elif [[ -f $1/package-lock.json ]]; then echo npm
  else return 1
  fi
}

# nm_store_key <dir>: the store key for that directory's lockfile under the active node.
nm_store_key() {
  local dir=$1 tool lock
  tool=$(nm_store_tool "$dir") || { echo "nm_store: no package-lock.json or pnpm-lock.yaml in $dir" >&2; return 1; }
  [[ $tool == pnpm ]] && lock=pnpm-lock.yaml || lock=package-lock.json
  {
    printf 'tool %s\nnode %s\nflags %s\n' "$tool" "$(node -v)" "${NM_INSTALL_FLAGS:-}"
    sha256sum "$dir/$lock" "$dir/package.json" | cut -d' ' -f1
  } | sha256sum | cut -c1-32
}

# nm_store_install <release dir> <app>
nm_store_install() {
  local rel=$1 app=$2 tool key store tmp
  [[ -n $app && $app != */* ]] || { echo "nm_store: bad app name '$app'" >&2; return 1; }
  [[ ! -e $rel/node_modules ]] || { echo "nm_store: $rel/node_modules already exists" >&2; return 1; }
  tool=$(nm_store_tool "$rel") || { echo "nm_store: no lockfile in $rel" >&2; return 1; }
  key=$(nm_store_key "$rel") || return 1
  store=$(nm_store_root)/$app/$key
  if [[ -d $store/node_modules ]]; then
    echo "nm_store: hit $app/$key"
  else
    # Installed in the release itself (file: dependencies, postinstall steps that read the
    # repo), then moved into the store: same filesystem, so the move is a rename.
    echo "nm_store: miss $app/$key: $tool install"
    # shellcheck disable=SC2086  # NM_INSTALL_FLAGS is a list of flags
    if [[ $tool == pnpm ]]; then
      (cd "$rel" && pnpm install --frozen-lockfile ${NM_INSTALL_FLAGS:-}) || return 1
    else
      (cd "$rel" && npm ci ${NM_INSTALL_FLAGS:-}) || return 1
    fi
    mkdir -p "$rel/node_modules"   # a project with no dependencies still gets one
    find "$rel/node_modules" -type f -exec chmod a-w {} +
    mkdir -p "$(dirname "$store")"
    tmp=$(mktemp -d "$store.tmp.XXXXXX")
    mv "$rel/node_modules" "$tmp/node_modules"
    if ! mv -T "$tmp" "$store" 2>/dev/null; then
      # Another deploy placed the same key first: theirs is identical by construction.
      chmod -R u+w "$tmp" && rm -rf "$tmp"
      [[ -d $store/node_modules ]] || { echo "nm_store: could not place $store" >&2; return 1; }
    fi
  fi
  touch "$store"   # last used, for nm_store_gc's age check
  cp -al "$store/node_modules" "$rel/node_modules"
  printf '%s/%s\n' "$app" "$key" >"$rel/.nm-store-key"
}

# nm_store_gc [apps root]: remove store entries that no kept release references.
# Releases live in <apps root>/<app>/<env>/<service>/releases/<sha>/ (default $HOME/apps).
nm_store_gc() {
  local apps=${1:-$HOME/apps} root min_age used entry
  root=$(nm_store_root)
  min_age=${NM_GC_MIN_AGE_MIN:-120}
  [[ -d $root ]] || return 0
  # find, not a glob: with no releases left an unmatched glob would fail the whole GC
  used=$(find "$apps" -mindepth 6 -maxdepth 6 -path '*/releases/*' -name .nm-store-key -exec cat {} + 2>/dev/null | sort -u)
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    if ! grep -qxF "${entry#"$root"/}" <<<"$used"; then
      echo "nm_store: gc ${entry#"$root"/}"
      chmod -R u+w "$entry" && rm -rf "$entry"
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -mmin +"$min_age" ! -name '*.tmp.*')
  # Temp dirs left by an interrupted install.
  find "$root" -mindepth 2 -maxdepth 2 -type d -name '*.tmp.*' -mmin +"$min_age" -exec rm -rf {} +
}
