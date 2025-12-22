#!/usr/bin/env bash
# import-rhel-kernel-srpms.sh — container edition (final, complete)
# Runs inside a Rocky 9/10 container (via your podman/docker runner) and
# mirrors Rocky RHEL9/10 kernel SRPMs into a git repo mounted at /work.

set -euo pipefail

########## CONFIG (env) ##########
REPO_DIR="${1:-/work}"; REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && pwd -P)" || { echo "Repo dir '$REPO_DIR' not accessible" >&2; exit 1; }
MAJORS="${ARGV_MAJORS:-${MAJORS:-9 10}}"
WORKDIR="${WORKDIR:-$REPO_DIR/.work}"               # scratch: srpms/tmp/logs
MODE="${MODE:-prep}"                                # "prep" or "sources"
ARCH="${ARCH:-x86_64}"                              # rpmbuild --target; used for Kconfig too
KEEP_SRPMS="${KEEP_SRPMS:-1}"                       # 0 => delete SRPM after success
LOG_LEVEL="${LOG_LEVEL:-info}"                      # info|warn|error
INIT_BRANCH="${INIT_BRANCH:-main}"                  # minimal docs branch
MAIN_BRANCH="${MAIN_BRANCH:-$INIT_BRANCH}"
DEBUG="${DEBUG:-0}"                                 # 1 => bash -x + rpmbuild -vv + extra logs

# Optional arch config export (for MCP/LLM)
CONFIG_ARCHES="${CONFIG_ARCHES:-x86_64 ppc64le s390x}"
CONFIG_INCLUDE_REGEX="${CONFIG_INCLUDE_REGEX:-}"    # optional include regex (e.g. 'ppc64le')
CONFIG_EXCLUDE_REGEX="${CONFIG_EXCLUDE_REGEX:-debug|rt|realtime}"
CONFIG_GENERATE="${CONFIG_GENERATE:-1}"             # 1 => also run `make ARCH=<karch> olddefconfig`
CONFIG_EXPORT_DIR="${CONFIG_EXPORT_DIR:-$REPO_DIR/metadata/configs}"
CONFIG_LATEST_POINTER="${CONFIG_LATEST_POINTER:-1}" # 1 => maintain <arch>/latest/

# Disk hygiene
PRUNE_TMP="${PRUNE_TMP:-1}"                         # prune old .work/tmp/rpmbuild-*
PRUNE_TMP_AGE_HOURS="${PRUNE_TMP_AGE_HOURS:-12}"
PRUNE_TMP_AFTER_IMPORT="${PRUNE_TMP_AFTER_IMPORT:-1}"

# main branch policy
MAIN_ENFORCE_MINIMAL="${MAIN_ENFORCE_MINIMAL:-0}"   # 1 => purge everything on main except README.md, CHANGELOG.md, index.json, .gitignore, .work
README_MD_SOURCE="${README_MD_SOURCE:-$REPO_DIR/README.md}"

# Spec sanitizer for EL9-era rpm built-ins on newer rpmbuild
RPM_BUILTIN_RENAMES="${RPM_BUILTIN_RENAMES:-rpmversion=_rpmver,rpmrelease=_rpmrel}"

# Git identity
GIT_IMPORT_NAME="${GIT_IMPORT_NAME:-David Christensen}"
GIT_IMPORT_EMAIL="${GIT_IMPORT_EMAIL:-randomparity@gmail.com}"

########## UTILITIES ##########
ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
lvl(){ case "$1" in info) echo 1;; warn) echo 2;; error) echo 3;; *) echo 1;; esac; }
LOGN="$(lvl "$LOG_LEVEL")"
log(){ local L="$1"; shift; [ "$(lvl "$L")" -ge "$LOGN" ] && printf '[%s] %-5s %s\n' "$(ts)" "$L" "$*" >&2 || true; }

if [[ "$DEBUG" == "1" ]]; then set -x; fi

# Guard: prevent legacy rpm helpers from writing into repo root
mkdir -p "$WORKDIR"/{srpms,tmp,logs}
SAFE_HOME="$WORKDIR/.home"; mkdir -p "$SAFE_HOME"; export HOME="$SAFE_HOME"

########## GIT INIT & IGNORE ##########
cd "$REPO_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q -b "$INIT_BRANCH"
else
  if git show-ref --quiet refs/heads/master && ! git show-ref --quiet "refs/heads/$INIT_BRANCH"; then
    ch="$(git symbolic-ref --short HEAD || true)"
    [[ "$ch" == "master" ]] && git branch -m master "$INIT_BRANCH" || true
  fi
fi
git config --get user.name  >/dev/null 2>&1 || git config user.name  "$GIT_IMPORT_NAME"
git config --get user.email >/dev/null 2>&1 || git config user.email "$GIT_IMPORT_EMAIL"
git config init.defaultBranch "$INIT_BRANCH" || true

touch .gitignore
grep -qxF "/.work/"    .gitignore || echo "/.work/"    >> .gitignore
grep -qxF "/redhat/"   .gitignore || echo "/redhat/"   >> .gitignore
grep -qxF "/rpmbuild/" .gitignore || echo "/rpmbuild/" >> .gitignore
EXCL="$REPO_DIR/.git/info/exclude"; mkdir -p "$(dirname "$EXCL")"
grep -qxF ".work/"    "$EXCL" 2>/dev/null || echo ".work/"    >> "$EXCL"
grep -qxF "redhat/"   "$EXCL" 2>/dev/null || echo "redhat/"   >> "$EXCL"
grep -qxF "rpmbuild/" "$EXCL" 2>/dev/null || echo "rpmbuild/" >> "$EXCL"

# Prune stale tmp
if [[ "$PRUNE_TMP" == "1" ]]; then
  find "$WORKDIR/tmp" -maxdepth 1 -type d -name 'rpmbuild-*' -mmin +"$((PRUNE_TMP_AGE_HOURS*60))" -exec rm -rf {} + || true
fi

########## DISCOVERY (Rocky SRPMs) ##########
SRPM_RE='kernel-[0-9][^"[:space:]]*\.src\.rpm'
ROCKY_PUB="https://download.rockylinux.org"
ROCKY_VLT="https://download.rockylinux.org"
ROCKY_VLT_FALLBACK="https://dl.rockylinux.org"

list_minors() {
  local major="$1" host
  for host in "$ROCKY_VLT" "$ROCKY_VLT_FALLBACK"; do
    if curl -fsI "$host/vault/rocky/" >/dev/null 2>&1; then
      curl -fsSL "$host/vault/rocky/" | grep -Eo "${major}\.[0-9]+/" | sed 's:/$::' | sort -Vu
      return 0
    fi
  done
  return 0
}

list_pkg_urls(){ local base="$1"; curl -fsSL "$base" | grep -Eo "$SRPM_RE" | sed -E "s|^|$base|"; }

gather_urls(){
  local majors="$1" out="$2"; : > "$out"
  for m in $majors; do
    local cur="$ROCKY_PUB/pub/rocky/$m/BaseOS/source/tree/Packages/k/"
    if curl -fsI "$cur" >/dev/null 2>&1; then list_pkg_urls "$cur" >> "$out" || true; fi
    while IFS= read -r minor; do
      for host in "$ROCKY_VLT" "$ROCKY_VLT_FALLBACK"; do
        local vd="$host/vault/rocky/$minor/BaseOS/source/tree/Packages/k/"
        if curl -fsI "$vd" >/dev/null 2>&1; then list_pkg_urls "$vd" >> "$out" || true; break; fi
      done
    done < <(list_minors "$m")
  done
  sort -u -o "$out" "$out"
}

########## HELPERS ##########
nvr_from_url(){ local b; b="$(basename "$1")"; echo "${b%.src.rpm}"; }
el_from_rel(){ sed -nE 's/.*\.el([0-9]+)(_.*)?/\1/p' <<<"$1"; }
tag_from_nvr(){ local nvr="$1"; local v="${nvr#kernel-}"; local r="${v#*-}"; echo "rhel$(el_from_rel "$r")-$v"; }
branch_from_nvr(){ local nvr="$1"; local v="${nvr#kernel-}"; local r="${v#*-}"; echo "rhel$(el_from_rel "$r")"; }
bt_epoch(){ rpm -qp --qf '%{BUILDTIME}\n' "$1"; }

karch_for(){ case "$1" in x86_64) echo x86 ;; ppc64le) echo powerpc ;; s390x) echo s390 ;; aarch64) echo arm64 ;; *) echo "$1" ;; esac; }

cfg_match(){ local f="$1" a="$2" b; b="$(basename "$f")"
  [[ -z "$CONFIG_INCLUDE_REGEX" ]] || [[ "$b" =~ $CONFIG_INCLUDE_REGEX ]] || return 1
  [[ -z "$CONFIG_EXCLUDE_REGEX" ]] || { [[ "$b" =~ $CONFIG_EXCLUDE_REGEX ]] && return 1; }
  [[ -n "$CONFIG_INCLUDE_REGEX" ]] || [[ "$b" == *"$a"* ]]
}

sanitize_spec_builtins(){
  local spec="$1" dlog="$2" map="$RPM_BUILTIN_RENAMES"
  IFS=',' read -r -a pairs <<< "$map"
  local kv from to
  for kv in "${pairs[@]}"; do
    [[ -z "$kv" ]] && continue
    from="${kv%%=*}"; to="${kv#*=}"
    if grep -Eq '^(%define|%global)[[:space:]]+'"$from"'([[:space:]]|\(|$)' "$spec"; then
      cp -f "$spec" "${spec}.orig.${from}" || true
      sed -i -E "s/^(%)(define|global)[[:space:]]+${from}([[:space:]]|\()/\1\2 ${to}\3/" "$spec"
      sed -i -E "s/%\{${from}\}/%{${to}}/g; s/%${from}\b/%${to}/g" "$spec"
      echo "--- sanitized built-in macro ${from}->${to} in $(basename "$spec")" >> "$dlog"
    fi
  done
}

dbg_hdr(){ [[ "$DEBUG" != "1" ]] && return 0; { echo "--- env ---"; uname -a; cat /etc/os-release; echo; echo "--- rpm/rpmbuild ---"; rpm --version; rpmbuild --version; echo; echo "--- rpm --showrc (head) ---"; rpm --showrc | sed -n '1,160p'; } >> "$1"; }
dbg_mac(){ [[ "$DEBUG" != "1" ]] && return 0; { echo; echo "--- macro eval ---"; rpmbuild --eval '%{?rhel} %{?fedora} %{_topdir} %{_sourcedir} %{_specdir} %{_tmppath}'; } >> "$1"; }
dbg_prep(){ [[ "$DEBUG" != "1" ]] && return 0; local tmp="$1" logf="$2" nvr="$3"; local t; t="$(ls -1t "$tmp"/rpm-tmp.* 2>/dev/null | head -1 || true)"; if [[ -f "$t" ]]; then cp -f "$t" "$WORKDIR/logs/${nvr}.prep.sh"; { echo; echo "--- %prep head ---"; sed -n '1,120p' "$t"; echo; echo "--- %prep tail ---"; tail -n 120 "$t"; } >> "$2"; fi; }
dbg_tree(){ [[ "$DEBUG" != "1" ]] && return 0; local b="$1" logf="$2"; { echo; echo "--- BUILD tree (first 200 dirs) ---"; find "$b" -maxdepth 5 -type d -print | sed -n '1,200p'; } >> "$2"; }

########## %prep: expand SRPM ##########
prep_srpm(){
  local srpm="$1"
  local nvr; nvr="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$srpm" 2>/dev/null || basename "$srpm" .src.rpm)"
  local top="$WORKDIR/tmp/rpmbuild-${nvr}"
  local ilog="$WORKDIR/logs/${nvr}.install.log"
  local plog="$WORKDIR/logs/${nvr}.bp.log"
  local dlog="$WORKDIR/logs/${nvr}.diag.txt"

  rm -rf "$top"; mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,TMP}
  : > "$ilog"; : > "$plog"; : > "$dlog"; dbg_hdr "$dlog"

  log info "Installing SRPM: $nvr"
  rpm -Uvh --nosignature --nodigest --define "_topdir $top" --nodeps "$srpm" >>"$ilog" 2>&1 || true

  local spec; spec="$(find "$top/SPECS" -maxdepth 1 -name '*.spec' -print -quit || true)"
  if [[ -z "$spec" ]]; then
    local ex="$top/EXTRACT"; mkdir -p "$ex"
    ( cd "$ex"; rpm2cpio "$srpm" | cpio -idmv ) >>"$ilog" 2>&1 || true
    spec="$(find "$ex" -maxdepth 3 -name '*.spec' -print -quit || true)"
    [[ -n "$spec" ]] || { log error "No .spec in SRPM (see $ilog)"; return 1; }
    cp -f "$spec" "$top/SPECS/"; spec="$top/SPECS/$(basename "$spec")"
    find "$ex" -mindepth 1 -maxdepth 1 ! -name '*.spec' -exec cp -a {} "$top/SOURCES/" \; || true
  fi

  dbg_mac "$dlog"
  sanitize_spec_builtins "$spec" "$dlog"

  local rel="${nvr#kernel-}"; rel="${rel#*-}"; local el; el="$(el_from_rel "$rel")"; [[ -z "$el" ]] && el="9"
  local defs=(
    --define "_topdir $top"
    --define "_sourcedir $top/SOURCES"
    --define "_specdir $top/SPECS"
    --define "_tmppath $top/TMP"
    --define "rhel $el"
    --define "fedora 0"
    --define 'uname_variant() %{lua: local f=rpm.expand("%{?1:%{1}}"); local m=f:match("([%w_]+)"); if m and m~="" then print("+"..m) end }'
    --define 'uname_suffix() %{lua: local f=rpm.expand("%{?1:%{1}}"); f=f:gsub("%-","_"); if f~="" then print("_"..f) end }'
    --define 'py3_shebang_fix() %{expand: : }'
  )

  log info "Running rpmbuild -bp for: $nvr"
  local vv=(); [[ "$DEBUG" == "1" ]] && vv=(-vv)
  if ! rpmbuild "${vv[@]}" --nodeps "${defs[@]}" --target "$ARCH" -bp "$spec" >>"$plog" 2>&1; then
    dbg_prep "$top/TMP" "$plog" "$nvr"; dbg_tree "$top/BUILD" "$plog"
    log error "rpmbuild -bp failed for $nvr (see $plog)"; return 1
  fi

  # Find the kernel source root (linux-* directory with Kconfig at top level)
  local src=""
  while IFS= read -r d; do
    [[ -f "$d/Kconfig" && -f "$d/Makefile" ]] && { src="$d"; break; }
  done < <(find "$top/BUILD" -maxdepth 3 -type d -name 'linux-*' | sort -V)
  if [[ -z "$src" || ! -d "$src" ]]; then
    dbg_prep "$top/TMP" "$plog" "$nvr"; dbg_tree "$top/BUILD" "$plog"
    log error "Prepared tree not found under $top/BUILD (see $plog)"; return 1
  fi

  if [[ -n "$CONFIG_ARCHES" ]]; then
    log info "Exporting configs for: $nvr"
    export_configs "$src" "$nvr" || true
  fi
  echo "$src"
}

########## Export per-arch configs to metadata/configs/<arch>/<TAG>/ + latest ##########
export_configs(){
  local src="$1" nvr="$2" tag; tag="$(tag_from_nvr "$nvr")"
  local candidates=()
  if [[ -d "$src/configs" ]]; then
    while IFS= read -r -d '' f; do candidates+=("$f"); done < <(find "$src/configs" -type f -name '*.config' -print0)
    log info "  Found ${#candidates[@]} config files in $src/configs"
  else
    log warn "  No configs directory at $src/configs"
  fi
  [[ -f "$src/.config" ]] && candidates+=("$src/.config")

  [[ "${#candidates[@]}" -eq 0 && "$CONFIG_GENERATE" != "1" ]] && return 0

  local outbase="$WORKDIR/config-export/$nvr"; rm -rf "$outbase"; mkdir -p "$outbase"

  if [[ "$CONFIG_GENERATE" == "1" ]]; then
    for a in $CONFIG_ARCHES; do
      local karch seed=""; karch="$(karch_for "$a")"
      for f in "${candidates[@]}"; do if cfg_match "$f" "$a"; then seed="$f"; break; fi; done
      if [[ -n "$seed" ]]; then
        log info "  Generating config for arch: $a (seed: $(basename "$seed"))"
      else
        log info "  Generating config for arch: $a (no seed found)"
      fi
      pushd "$src" >/dev/null
        # Clean only .config, not the whole tree (mrproper removes Makefile!)
        rm -f .config .config.old
        [[ -n "$seed" ]] && cp -f "$seed" .config
        local cfg_log="$WORKDIR/logs/${nvr}.config.${a}.log"
        if make ARCH="$karch" olddefconfig >"$cfg_log" 2>&1; then
          mkdir -p "$outbase/$a"
          cp -f .config "$outbase/$a/${nvr}.${a}.resolved.config"
        else
          log warn "  Failed to generate config for $a (see ${cfg_log})"
        fi
      popd >/dev/null
    done
  fi

  for a in $CONFIG_ARCHES; do
    local any=0
    for f in "${candidates[@]}"; do
      cfg_match "$f" "$a" || continue
      mkdir -p "$outbase/$a"; cp -f "$f" "$outbase/$a/"; any=1
    done
    if [[ "$any" -eq 1 ]]; then
      # manifest
      {
        echo '{'
        echo '  "nvr": "'"$nvr"'",'
        echo '  "tag": "'"$tag"'",'
        echo '  "arch": "'"$a"'",'
        echo '  "files": ['
        local first=1
        while IFS= read -r -d '' p; do
          local b s h; b="$(basename "$p")"; s="$(stat -c %s "$p" 2>/dev/null || stat -f %z "$p")"; h="$(sha256sum "$p" | awk '{print $1}')"
          [[ $first -eq 0 ]] && echo ','
          printf '    { "name": "%s", "bytes": %s, "sha256": "%s" }' "$b" "$s" "$h"
          first=0
        done < <(find "$outbase/$a" -maxdepth 1 -type f -name '*.config' -print0 | sort -z)
        echo
        echo '  ]'
        echo '}'
      } > "$outbase/$a/manifest.json"
    fi
  done
}

########## Commit/tag to per-distro branch ##########
commit_one(){
  local nvr="$1" tree="$2" srpm="$3" imported_tsv="$4"
  local tag; tag="$(tag_from_nvr "$nvr")"
  local branch; branch="$(branch_from_nvr "$nvr")"

  log info "Committing: $nvr -> $tag"

  local be; be="$(bt_epoch "$srpm" 2>/dev/null || echo 0)"
  local bts; bts="$(date -u -d "@$be" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || ts)"

  cd "$REPO_DIR"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then return 0; fi

  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git switch -q "$branch"
  else
    git switch -q --orphan "$branch"
  fi

  local keep="$(basename "$WORKDIR")"
  git ls-files -z | xargs -0r git rm -f --quiet || true
  find . -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".gitignore" ! -name "$keep" -exec rm -rf {} + || true

  if [[ "$MODE" == "prep" ]]; then
    rsync -a --delete \
      --exclude='/.git' --exclude='/.git/**' \
      --exclude='/.gitignore' \
      --exclude="/$keep" --exclude="/$keep/**" \
      "$tree/" "./"
  else
    mkdir -p packaging/{SOURCES,SPECS}
    rsync -a "$WORKDIR/tmp/rpmbuild-${nvr}/SOURCES/" packaging/SOURCES/ || true
    rsync -a "$WORKDIR/tmp/rpmbuild-${nvr}/SPECS/"   packaging/SPECS/   || true
    printf '%s\n' "$nvr"  > packaging/PACKAGE_NVR.txt
    printf '%s\n' "$srpm" > packaging/PACKAGE_SOURCE_SRPM.txt
  fi

  # copy exported configs into metadata/configs/<arch>/<TAG>/ and refresh latest/
  if [[ -n "$CONFIG_ARCHES" && -d "$WORKDIR/config-export/$nvr" ]]; then
    for a in $CONFIG_ARCHES; do
      if [[ -d "$WORKDIR/config-export/$nvr/$a" ]]; then
        local dest="$CONFIG_EXPORT_DIR/$a/$tag"
        mkdir -p "$dest"
        rsync -a --delete "$WORKDIR/config-export/$nvr/$a/" "$dest/"
        if [[ "$CONFIG_LATEST_POINTER" == "1" ]]; then
          mkdir -p "$CONFIG_EXPORT_DIR/$a/latest"
          rsync -a --delete "$WORKDIR/config-export/$nvr/$a/" "$CONFIG_EXPORT_DIR/$a/latest/"
        fi
      fi
    done
  fi

  git add -A
  GIT_AUTHOR_NAME="$GIT_IMPORT_NAME" \
  GIT_AUTHOR_EMAIL="$GIT_IMPORT_EMAIL" \
  GIT_COMMITTER_NAME="$GIT_IMPORT_NAME" \
  GIT_COMMITTER_EMAIL="$GIT_IMPORT_EMAIL" \
  GIT_AUTHOR_DATE="$bts" \
  GIT_COMMITTER_DATE="$bts" \
    git commit -m "Import ${nvr} (from SRPM: $(basename "$srpm"))" >/dev/null

  local sha; sha="$(git rev-parse --verify HEAD)"
  git -c user.name="$GIT_IMPORT_NAME" -c user.email="$GIT_IMPORT_EMAIL" tag -a "$tag" -m "$nvr" >/dev/null

  printf "%s\t%s\t%s\t%s\t%s\n" "$(el_from_rel "${nvr#*-}")" "$be" "$nvr" "$tag" "$sha" >> "$imported_tsv"

  if [[ "$PRUNE_TMP_AFTER_IMPORT" == "1" ]]; then
    rm -rf "$WORKDIR/tmp/rpmbuild-${nvr}" "$WORKDIR/config-export/$nvr" || true
  fi
}

########## main branch docs & index ##########
generate_index(){
  local out="$REPO_DIR/index.json"; : > "$out"
  {
    echo "["
    local first=1
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      local sha iso epoch ver el
      sha="$(git -C "$REPO_DIR" rev-parse "$t")"
      iso="$(git -C "$REPO_DIR" show -s --format=%cI "$t")"
      epoch="$(git -C "$REPO_DIR" show -s --format=%ct "$t")"
      ver="${t#rhel[0-9]-}"
      el="$(sed -nE 's/^rhel([0-9]+)-.*/\1/p' <<<"$t")"
      [[ $first -eq 0 ]] && echo ","
      printf '  {"tag":"%s","nvr":"%s","branch":"rhel%s","built_at":"%s","built_epoch":%s,"commit":"%s"' \
        "$t" "kernel-$ver" "$el" "$iso" "$epoch" "$sha"
      if [[ -n "$CONFIG_ARCHES" ]]; then
        printf ',"configs":{'
        local i=0
        for a in $CONFIG_ARCHES; do
          [[ $i -gt 0 ]] && printf ","
          printf '"%s":"%s/%s/%s/"' "$a" "$CONFIG_EXPOR T_DIR" "$a" "$t" | sed 's/ //g'
          i=$((i+1))
        done
        printf "}"
      fi
      printf "}"
      first=0
    done < <(git -C "$REPO_DIR" tag --list 'rhel*-*' | sort -V)
    echo
    echo "]"
  } >> "$out"
}

update_main(){
  local imported_tsv="$1"
  cd "$REPO_DIR"
  if git rev-parse --verify --quiet "refs/heads/$MAIN_BRANCH" >/dev/null 2>&1; then
    git switch -q "$MAIN_BRANCH"
  else
    git switch -q --orphan "$MAIN_BRANCH"
  fi

  if [[ "$MAIN_ENFORCE_MINIMAL" == "1" ]]; then
    find . -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".gitignore" ! -name "README.md" ! -name "CHANGELOG.md" ! -name "index.json" ! -name "$(basename "$WORKDIR")" -exec rm -rf {} + || true
  fi

  if [[ -f "$README_MD_SOURCE" ]]; then
    cp -f "$README_MD_SOURCE" README.md
  elif [[ ! -f README.md ]]; then
    cat > README.md <<'EOF'
# RHEL Kernel Source Mirror (Rocky SRPMs → Git)

Branches:
- `rhel9`, `rhel10`: prepared kernel source trees per SRPM.
- Tags: `rhel<major>-<version-release>`.

This `main` branch stays minimal:
- README.md (this file)
- CHANGELOG.md (one line per imported SRPM)
- index.json (machine-readable list of all tags with metadata)

If enabled, per-arch Kconfig snapshots live under:
`metadata/configs/<arch>/<TAG>/` and `metadata/configs/<arch>/latest/`.
EOF
  fi

  touch CHANGELOG.md
  if [[ -s "$imported_tsv" ]]; then
    while IFS=$'\t' read -r el bt nvr tag sha; do
      grep -qF "$tag" CHANGELOG.md && continue
      local iso; iso="$(date -u -d "@$bt" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || ts)"
      printf "%s  –  [%s] %s  (build %s)  branch=rhel%s  commit=%s\n" "$(date -u +%Y-%m-%d)" "$tag" "$nvr" "$iso" "$el" "$sha" >> CHANGELOG.md
    done < "$imported_tsv"
  fi

  generate_index

  [[ -f .gitignore ]] || printf "/.work/\n/redhat/\n/rpmbuild/\n" > .gitignore
  git add README.md CHANGELOG.md index.json
  [[ -f .gitignore ]] && git add .gitignore
  GIT_AUTHOR_NAME="$GIT_IMPORT_NAME" \
  GIT_AUTHOR_EMAIL="$GIT_IMPORT_EMAIL" \
  GIT_COMMITTER_NAME="$GIT_IMPORT_NAME" \
  GIT_COMMITTER_EMAIL="$GIT_IMPORT_EMAIL" \
    git commit -m "docs(main): update changelog & index" >/dev/null || true
}

########## MAIN ##########
URLS="$WORKDIR/kernel-srpms.txt"
gather_urls "$MAJORS" "$URLS"
DISCOVERED="$(wc -l < "$URLS" 2>/dev/null || echo 0)"

declare -A HAVE
while IFS= read -r t; do [[ -n "$t" ]] && HAVE["$t"]=1; done < <(git -C "$REPO_DIR" tag --list 'rhel*-*' || true)

TODO="$WORKDIR/todo-urls.txt"; : > "$TODO"
while IFS= read -r u; do
  [[ -z "$u" ]] && continue
  nvr="$(nvr_from_url "$u")"; tag="$(tag_from_nvr "$nvr")"
  [[ -n "${HAVE[$tag]:-}" ]] && continue
  echo "$u" >> "$TODO"
done < "$URLS"

TODO_CNT="$(wc -l < "$TODO" 2>/dev/null || echo 0)"
ALREADY=$(( DISCOVERED - TODO_CNT ))
DL=0; CACHED=0
while IFS= read -r u; do
  [[ -z "$u" ]] && continue
  f="$WORKDIR/srpms/$(basename "$u")"
  if [[ -s "$f" ]]; then CACHED=$((CACHED+1)); else DL=$((DL+1)); fi
done < "$TODO"

log info "Summary: discovered ${DISCOVERED}, already tagged ${ALREADY}, to import ${TODO_CNT} (cached ${CACHED}, to download ${DL})"

mkdir -p "$WORKDIR/srpms"
while IFS= read -r u; do
  [[ -z "$u" ]] && continue
  f="$WORKDIR/srpms/$(basename "$u")"
  if [[ ! -s "$f" ]]; then
    log info "Downloading: $(basename "$u")"
    curl -fL --retry 3 -o "$f.part" "$u" && mv "$f.part" "$f"
  fi
done < "$TODO"

PLAN="$WORKDIR/srpm-plan.tsv"; : > "$PLAN"
while IFS= read -r f; do
  [[ -e "$f" ]] || continue
  nvr="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$f" 2>/dev/null || basename "$f" .src.rpm)"
  rel="${nvr#kernel-}"; rel="${rel#*-}"; el="$(el_from_rel "$rel")"; [[ -z "$el" ]] && el="9"
  bt="$(bt_epoch "$f" 2>/dev/null || echo 0)"
  printf "%s\t%010d\t%s\t%s\n" "$el" "$bt" "$nvr" "$f" >> "$PLAN"
done < <(find "$WORKDIR/srpms" -maxdepth 1 -type f -name 'kernel-*.src.rpm' | sort)

sort -t$'\t' -k1,1n -k2,2n -o "$PLAN" "$PLAN"

IMPORTED="$WORKDIR/imported-this-run.tsv"; : > "$IMPORTED"

while IFS=$'\t' read -r el bt nvr srpm; do
  tag="$(tag_from_nvr "$nvr")"
  if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    continue
  fi
  src="$(prep_srpm "$srpm")" || { log error "Skipping $nvr (prep failed)"; continue; }
  commit_one "$nvr" "$src" "$srpm" "$IMPORTED"
  [[ "$KEEP_SRPMS" == "1" ]] || rm -f -- "$srpm" || true
done < "$PLAN"

update_main "$IMPORTED"

log info "Done. Repository: $REPO_DIR"
