#!/usr/bin/env bash
# import-rhel-kernel-srpms.sh — container edition
#
# Builds a Git repo of RHEL 9/10 kernel sources from public Rocky SRPMs.
# - Discovers SRPM URLs (rolling + all vault minors)
# - Downloads only new SRPMs (idempotent via Git tags)
# - Runs `rpmbuild -bp` (%prep only; no heavy BuildRequires) inside Rocky
# - Commits & tags on per-distro branches: rhel9, rhel10  (no commits on main)
# - Tags: rhel<major>-<version-release>  e.g., rhel9-5.14.0-570.52.1.el9_6
# - Exports per-arch kernel config files into: metadata/configs/<arch>/<TAG>/
#   and also refreshes metadata/configs/<arch>/latest/
#
# Environment (optional):
#   MAJORS="9 10" | WORKDIR="$REPO_DIR/.work" | MODE="prep|sources" | ARCH="x86_64"
#   KEEP_SRPMS=1   | LOG_LEVEL=info|warn|error | INIT_BRANCH=main
#   GIT_IMPORT_NAME="RHEL SRPM Importer" | GIT_IMPORT_EMAIL="rhel-srpm-importer@localdomain"
#   DEBUG=0|1      # when 1, enable verbose tracing & extra diagnostics
#
#   # Config export knobs (for MCP-friendly retrieval by arch):
#   CONFIG_ARCHES=""                      # e.g. "ppc64le s390x" (empty = skip export)
#   CONFIG_INCLUDE_REGEX=""               # e.g. 'ppc64le' (optional include filter)
#   CONFIG_EXCLUDE_REGEX="debug|rt|realtime"  # exclude flavors by name (regex)
#   CONFIG_EXPORT_DIR="metadata/configs"  # where configs are stored in the repo
#   CONFIG_GENERATE=0                     # 1 = also generate resolved .config via Kconfig
#   CONFIG_LATEST_POINTER=1               # 1 = refresh <arch>/latest/ each import
#
#   # Disk hygiene:
#   PRUNE_TMP=1                           # prune old rpmbuild trees at start
#   PRUNE_TMP_AGE_HOURS=12
#   PRUNE_TMP_AFTER_IMPORT=1              # remove this NVR's tmp after success
set -euo pipefail

# --- args/env ----------------------------------------------------------------
REPO_DIR="${1:-/work}"
[[ -d "$REPO_DIR" ]] || { echo "Repo dir $REPO_DIR not found" >&2; exit 1; }
REPO_DIR="$(readlink -f "$REPO_DIR" 2>/dev/null || realpath "$REPO_DIR")"

MAJORS="${MAJORS:-9 10}"
WORKDIR="${WORKDIR:-$REPO_DIR/.work}"
MODE="${MODE:-prep}"
ARCH="${ARCH:-x86_64}"
KEEP_SRPMS="${KEEP_SRPMS:-1}"
LOG_LEVEL="${LOG_LEVEL:-info}"
INIT_BRANCH="${INIT_BRANCH:-main}"
BRANCH_STRATEGY="per_major"          # rhel9 / rhel10

# Debug tracing
DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == "1" ]]; then
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

# Config export knobs
CONFIG_ARCHES="${CONFIG_ARCHES:-x86_64 ppc64le s390x}"
CONFIG_INCLUDE_REGEX="${CONFIG_INCLUDE_REGEX:-}"
CONFIG_EXCLUDE_REGEX="${CONFIG_EXCLUDE_REGEX:-debug|rt|realtime}"
CONFIG_EXPORT_DIR="${CONFIG_EXPORT_DIR:-metadata/configs}"
CONFIG_GENERATE="${CONFIG_GENERATE:-1}"
CONFIG_LATEST_POINTER="${CONFIG_LATEST_POINTER:-1}"

# Disk hygiene
PRUNE_TMP="${PRUNE_TMP:-1}"
PRUNE_TMP_AGE_HOURS="${PRUNE_TMP_AGE_HOURS:-12}"
PRUNE_TMP_AFTER_IMPORT="${PRUNE_TMP_AFTER_IMPORT:-1}"

# Identity
GIT_IMPORT_NAME="${GIT_IMPORT_NAME:-David Christensen}"
GIT_IMPORT_EMAIL="${GIT_IMPORT_EMAIL:-randomparity@gmail.com}"

mkdir -p "$WORKDIR"/{srpms,tmp,logs}

# --- logging -----------------------------------------------------------------
lvl(){ case "$1" in info) echo 1;; warn) echo 2;; error) echo 3;; *) echo 1;; esac; }
THRESHOLD="$(lvl "$LOG_LEVEL")"
log(){ local l="$1"; shift; [ "$(lvl "$l")" -ge "$THRESHOLD" ] && printf '[%s] %-5s %s\n' "$(date -u +'%FT%TZ')" "$l" "$*" >&2 || true; }

# --- repo init / local config ------------------------------------------------
cd "$REPO_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q -b "$INIT_BRANCH"
else
  if git show-ref --quiet refs/heads/master && ! git show-ref --quiet "refs/heads/$INIT_BRANCH"; then
    cur_head="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ "$cur_head" = "master" ]; then git branch -m master "$INIT_BRANCH"; fi
  fi
fi
git config --get user.name  >/dev/null 2>&1 || git config user.name  "$GIT_IMPORT_NAME"
git config --get user.email >/dev/null 2>&1 || git config user.email "$GIT_IMPORT_EMAIL"
git config init.defaultBranch "$INIT_BRANCH" || true
# Ensure repo-level ignore for cache/logs
if [[ ! -f .gitignore ]]; then printf "/.work/\n" > .gitignore; else grep -qxF "/.work/" .gitignore || printf "/.work/\n" >> .gitignore; fi
# Extra local exclude
EXCL_FILE=".git/info/exclude"; mkdir -p "$(dirname "$EXCL_FILE")"; grep -qxF ".work/" "$EXCL_FILE" 2>/dev/null || echo ".work/" >> "$EXCL_FILE"

# --- proactive tmp pruning ---------------------------------------------------
if [[ "$PRUNE_TMP" == "1" ]]; then
  find "$WORKDIR/tmp" -maxdepth 1 -type d -name 'rpmbuild-*' -mmin +"$((PRUNE_TMP_AGE_HOURS*60))" -exec rm -rf {} + 2>/dev/null || true
fi

# --- discovery helpers (robust, with fallback host) -------------------------
SRPM_RE='kernel-[0-9][^" <]*\.src\.rpm'
ROCKY_PUB="https://download.rockylinux.org"       # rolling
ROCKY_VLT="https://download.rockylinux.org"       # vault primary
ROCKY_VLT_FALLBACK="https://dl.rockylinux.org"    # vault fallback

list_minor_dirs() {  # prints 9.0 9.1 9.2 ... for given major (tries both hosts)
  local major="$1" host
  for host in "$ROCKY_VLT" "$ROCKY_VLT_FALLBACK"; do
    if curl -fsI "$host/vault/rocky/" >/dev/null 2>&1; then
      curl -fsSL "$host/vault/rocky/" \
        | grep -Eo "${major}\.[0-9]+/" \
        | sed 's:/$::' \
        | sort -Vu
      return 0
    fi
  done
  return 1
}

list_kernel_srpms_dir() {
  local dir_url="$1"
  curl -fsSL "$dir_url" \
    | grep -Eo "$SRPM_RE" \
    | sed -E "s|^|$dir_url|"
}

gather_urls() {  # discover all kernel SRPM URLs for majors
  local majors="$1" out="$2"
  : > "$out"
  for m in $majors; do
    local cur="${ROCKY_PUB}/pub/rocky/${m}/BaseOS/source/tree/Packages/k/"
    curl -fsI "$cur" >/dev/null 2>&1 && list_kernel_srpms_dir "$cur" >> "$out" || true
    while read -r minor; do
      for host in "$ROCKY_VLT" "$ROCKY_VLT_FALLBACK"; do
        local vd="${host}/vault/rocky/${minor}/BaseOS/source/tree/Packages/k/"
        if curl -fsI "$vd" >/dev/null 2>&1; then
          list_kernel_srpms_dir "$vd" >> "$out" || true
          break
        fi
      done
    done < <(list_minor_dirs "$m" || true)
  done
  sort -u -o "$out" "$out"
}

# --- misc helpers -----------------------------------------------------------
nvr_from_url(){ local b; b="$(basename "$1")"; echo "${b%.src.rpm}"; }
el_major(){ sed -nE 's/.*\.el([0-9]+)(_.*)?/\1/p' <<<"$1"; }
tag_for_nvr(){ local nvr="$1" verrel rel el; verrel="${nvr#kernel-}"; rel="${verrel#*-}"; el="$(el_major "$rel")"; echo "rhel${el}-${verrel}"; }
branch_for_nvr(){ local nvr="$1" verrel rel el; verrel="${nvr#kernel-}"; rel="${verrel#*-}"; el="$(el_major "$rel")"; echo "rhel${el}"; }
buildtime_epoch(){ rpm -qp --qf '%{BUILDTIME}\n' "$1"; }

# Map Linux triple to Kconfig ARCH (used if CONFIG_GENERATE=1)
karch_for(){ case "$1" in x86_64) echo x86 ;; ppc64le) echo powerpc ;; s390x) echo s390 ;; aarch64) echo arm64 ;; *) echo "$1" ;; esac; }

config_matches(){ # $1=file $2=arch
  local f="$1" arch="$2" base; base="$(basename "$f")"
  [[ -z "$CONFIG_INCLUDE_REGEX" ]] || [[ "$base" =~ $CONFIG_INCLUDE_REGEX ]] || return 1
  [[ -z "$CONFIG_EXCLUDE_REGEX" ]] || { [[ "$base" =~ $CONFIG_EXCLUDE_REGEX ]] && return 1; }
  [[ -n "$CONFIG_INCLUDE_REGEX" ]] || [[ "$base" == *"$arch"* ]]
}

collect_configs(){ # $1=src_root $2=nvr ; echo exported_count
  local src_root="$1" nvr="$2" exported=0
  [[ -z "$CONFIG_ARCHES" ]] && { echo 0; return 0; }

  local out_base="$WORKDIR/config-export/$nvr"
  rm -rf "$out_base"; mkdir -p "$out_base"

  # candidates from shipped configs + any top-level .config
  local candidates=()
  if [[ -d "$src_root/configs" ]]; then
    while IFS= read -r -d '' f; do candidates+=("$f"); done \
      < <(find "$src_root/configs" -type f -name '*.config' -print0)
  fi
  [[ -f "$src_root/.config" ]] && candidates+=("$src_root/.config")

  # optional: generate resolved .config per arch
  if [[ "$CONFIG_GENERATE" == "1" ]]; then
    for arch in $CONFIG_ARCHES; do
      local karch seed=""
      karch="$(karch_for "$arch")"
      for f in "${candidates[@]}"; do if config_matches "$f" "$arch"; then seed="$f"; break; fi; done
      pushd "$src_root" >/dev/null
      make mrproper >/dev/null 2>&1 || true
      [[ -n "$seed" ]] && cp -f "$seed" .config
      if make ARCH="$karch" olddefconfig >/dev/null 2>&1; then
        mkdir -p "$out_base/$arch"
        cp -f .config "$out_base/$arch/${nvr}.${arch}.resolved.config"
        exported=$((exported+1))
      fi
      popd >/dev/null
    done
  fi

  # copy shipped configs filtered by arches/regexes
  for arch in $CONFIG_ARCHES; do
    for f in "${candidates[@]}"; do
      config_matches "$f" "$arch" || continue
      mkdir -p "$out_base/$arch"
      cp -f "$f" "$out_base/$arch/"
      exported=$((exported+1))
    done
  done

  # write manifest per arch
  for arch in $CONFIG_ARCHES; do
    [[ -d "$out_base/$arch" ]] || continue
    {
      echo '{'
      echo '  "nvr": "'"$nvr"'",'
      echo '  "arch": "'"$arch"'",'
      echo '  "files": ['
      local first=1
      while IFS= read -r -d '' f; do
        local base size sha
        base="$(basename "$f")"
        size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
        sha="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
        [[ $first -eq 0 ]] && echo ','
        echo '    { "name": "'"$base"'", "bytes": '"$size"', "sha256": "'"$sha"'" }'
        first=0
      done < <(find "$out_base/$arch" -maxdepth 1 -type f -print0 | sort -z)
      echo '  ]'
      echo '}'
    } > "$out_base/$arch/manifest.json"
  done

  echo "$exported"
}

# --- diagnostics (only when DEBUG=1) ----------------------------------------
dump_diag_header(){ [[ "$DEBUG" != "1" ]] && return 0; { echo "--- env ---"; uname -a || true; cat /etc/os-release 2>/dev/null || true; echo; echo "--- rpm/rpmbuild versions ---"; rpm --version || true; rpmbuild --version || true; echo; echo "--- rpm --showrc (first 200 lines) ---"; rpm --showrc 2>/dev/null | sed -n '1,200p' || true; } >> "$1"; }
dump_macro_eval(){ [[ "$DEBUG" != "1" ]] && return 0; { echo; echo "--- macro eval ---"; rpmbuild --eval '%{?rhel} %{?fedora} %{_topdir} %{_sourcedir} %{_specdir} %{_tmppath}' 2>/dev/null || true; echo "_topdir (script): $2"; } >> "$1"; }
save_expanded_spec(){ [[ "$DEBUG" != "1" ]] && return 0; rpmspec -P "$1" > "$2" 2>/dev/null || true; }
save_tmp_scripts(){ [[ "$DEBUG" != "1" ]] && return 0; if [[ -d "$1" ]]; then local tmp_file; tmp_file="$(ls -1t "$1"/rpm-tmp.* 2>/dev/null | head -1 || true)"; if [[ -n "$tmp_file" && -f "$tmp_file" ]]; then cp -f "$tmp_file" "$WORKDIR/logs/${3}.prep.sh" 2>/dev/null || true; { echo; echo "--- %prep shell head ---"; sed -n '1,200p' "$tmp_file"; echo; echo "--- %prep shell tail ---"; tail -n 200 "$tmp_file"; } >> "$2" 2>/dev/null || true; fi; fi; }
list_build_tree(){ [[ "$DEBUG" != "1" ]] && return 0; { echo; echo "--- BUILD tree (first 200 dirs) ---"; find "$1" -maxdepth 5 -type d -printf '%p\n' 2>/dev/null | sed -n '1,200p'; } >> "$2" 2>/dev/null || true; }

# --- detect prepared source root --------------------------------------------
looks_like_kernel_root(){ local d="$1"; [[ -f "$d/Makefile" && -d "$d/arch" && -d "$d/init" ]]; }
find_kernel_src_root(){
  local build_root="$1" cand
  cand="$(find "$build_root" -maxdepth 5 -type d -name 'linux-*' | sort -V | tail -1 || true)"
  if [[ -n "$cand" && -d "$cand" ]] && looks_like_kernel_root "$cand"; then echo "$cand"; return 0; fi
  cand="$(find "$build_root" -maxdepth 5 -type d -print 2>/dev/null | while read -r d; do looks_like_kernel_root "$d" && echo "$d"; done | sort -V | tail -1 || true)"
  [[ -n "$cand" && -d "$cand" ]] && { echo "$cand"; return 0; }
  cand="$(find "$build_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -n | awk '{print $2}' | tail -1 || true)"
  [[ -n "$cand" && -d "$cand" ]] && { echo "$cand"; return 0; }
  return 1
}

# --- %prep (expand SRPM, apply patches) -------------------------------------
prep_from_srpm(){
  local srpm="$1"
  local nvr; nvr="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$srpm" 2>/dev/null || true)"
  [[ -n "$nvr" ]] || nvr="$(basename "$srpm" .src.rpm)"

  local top="$WORKDIR/tmp/rpmbuild-${nvr}"
  local ilog="$WORKDIR/logs/${nvr}.install.log"
  local plog="$WORKDIR/logs/${nvr}.bp.log"
  local dlog="$WORKDIR/logs/${nvr}.diag.txt"
  local plog_host="$REPO_DIR/.work/logs/${nvr}.bp.log"

  rm -rf "$top"; mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,TMP}
  : > "$ilog"; : > "$plog"; : > "$dlog"; dump_diag_header "$dlog"

  log info "Installing SRPM: $nvr"
  rpm -Uvh --nosignature --nodigest --define "_topdir $top" --nodeps "$srpm" >>"$ilog" 2>&1 || true

  local spec; spec="$(find "$top/SPECS" -maxdepth 1 -name '*.spec' | head -n1 || true)"
  if [[ -z "$spec" ]]; then
    local extract="$top/EXTRACT"; mkdir -p "$extract"
    ( cd "$extract" && rpm2cpio "$srpm" | cpio -idmv ) >>"$ilog" 2>&1 || true
    spec="$(find "$extract" -maxdepth 3 -name '*.spec' | head -n1 || true)"
    [[ -n "$spec" ]] || { log error "No .spec in $srpm (see $ilog)"; return 1; }
    cp -f "$spec" "$top/SPECS/"
    shopt -s dotglob nullglob
    for p in "$extract"/*; do [[ "${p##*.}" == "spec" ]] && continue; cp -a "$p" "$top/SOURCES/" 2>/dev/null || true; done
    shopt -u dotglob nullglob
    spec="$top/SPECS/$(basename "$spec")"
  fi
  save_expanded_spec "$spec" "$WORKDIR/logs/${nvr}.spec.expanded.txt"

  local rel el; rel="${nvr#kernel-}"; rel="${rel#*-}"; el="$(el_major "$rel")"; : "${el:=9}"
  local defs=(
    --define "rhel $el"
    --define "fedora 0"
    --define "_tmppath $top/TMP"
    --define 'uname_variant() %{lua: local f=rpm.expand("%{?1:%{1}}"); local main=f:match("([%w_]+)"); if main and main~="" then print("+"..main) end }'
    --define 'uname_suffix() %{lua: local f=rpm.expand("%{?1:%{1}}"); f=f:gsub("%-","_"); if f~="" then print("_"..f) end }'
    --define 'py3_shebang_fix() %{expand: : }'
  )
  dump_macro_eval "$dlog" "$top"

  log info "Running rpmbuild -bp for: $nvr"
  local extra_verbosity=(); [[ "$DEBUG" == "1" ]] && extra_verbosity+=(-vv)
  if ! rpmbuild "${extra_verbosity[@]}" --nodeps \
        --define "_topdir $top" \
        --define "_sourcedir $top/SOURCES" \
        --define "_specdir $top/SPECS" \
        "${defs[@]}" \
        --target "$ARCH" \
        -bp "$spec" >>"$plog" 2>&1; then
    save_tmp_scripts "$top/TMP" "$plog" "$nvr"; list_build_tree "$top/BUILD" "$plog"
    log error "rpmbuild -bp failed for $nvr (see $plog_host)"; return 1
  fi

  local src_root
  if ! src_root="$(find_kernel_src_root "$top/BUILD")"; then
    save_tmp_scripts "$top/TMP" "$plog" "$nvr"; list_build_tree "$top/BUILD" "$plog"
    log error "Prepared tree not found under $top/BUILD (see $plog_host)"; return 1
  fi

  # Export arch configs (versioned-by-tag handled later in commit_version)
  if [[ -n "$CONFIG_ARCHES" ]]; then
    local exported_configs=0
    exported_configs="$(collect_configs "$src_root" "$nvr")" || exported_configs=0
    [[ "$exported_configs" -gt 0 ]] && log info "Exported ${exported_configs} config file(s) for: $nvr"
  fi

  echo "$src_root"
}

# --- commit/tag --------------------------------------------------------------
commit_version(){
  local nvr="$1" tag="$2" tree="$3" srpm="$4"
  if [[ ! -d "$tree" ]]; then log error "Prepared tree missing: $tree"; return 1; fi

  local bt_epoch bt_iso
  bt_epoch="$(buildtime_epoch "$srpm" 2>/dev/null || echo '')"
  if [[ -n "$bt_epoch" ]]; then
    bt_iso="$(date -u -d "@$bt_epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$bt_epoch" +'%Y-%m-%dT%H:%M:%SZ')"
  else
    bt_iso="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  fi

  pushd "$REPO_DIR" >/dev/null
  local branch; branch="$(branch_for_nvr "$nvr")"
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git switch -q "$branch"
  else
    git switch -q --orphan "$branch"
  fi

  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    log info "Tag exists, skipping: $tag"; popd >/dev/null; return 0; fi

  local keep_dir; keep_dir="$(basename "$WORKDIR")"
  git ls-files -z | xargs -0r git rm -f >/dev/null || true
  find . -mindepth 1 -maxdepth 1 \
      ! -name ".git" \
      ! -name "$keep_dir" \
      ! -name ".gitignore" \
      -exec rm -rf {} + 2>/dev/null || true

  if [[ "$MODE" == "prep" ]]; then
    rsync -a --delete \
      --exclude='/.git' --exclude='/.git/**' \
      --exclude="/${keep_dir}" --exclude="/${keep_dir}/**" \
      --exclude='/.gitignore' \
      "${tree}/" "./"
  else
    mkdir -p packaging/{SOURCES,SPECS}
    rsync -a "$WORKDIR/tmp/rpmbuild-${nvr}/SOURCES/" packaging/SOURCES/ || true
    rsync -a "$WORKDIR/tmp/rpmbuild-${nvr}/SPECS/"   packaging/SPECS/   || true
    printf "%s\n" "$nvr" > PACKAGING_NEVR.txt
    echo "$srpm" > PACKAGING_SOURCE_SRPM.txt
  fi

  # Copy exported configs into metadata/configs/<arch>/<TAG>/ and refresh latest/
  if [[ -n "$CONFIG_ARCHES" && -d "$WORKDIR/config-export/$nvr" ]]; then
    local arch dest_dir
    for arch in $CONFIG_ARCHES; do
      [[ -d "$WORKDIR/config-export/$nvr/$arch" ]] || continue
      dest_dir="$CONFIG_EXPORT_DIR/$arch/$tag"
      mkdir -p "$dest_dir"
      rsync -a --delete "$WORKDIR/config-export/$nvr/$arch/" "$dest_dir/"
      if [[ "$CONFIG_LATEST_POINTER" == "1" ]]; then
        mkdir -p "$CONFIG_EXPORT_DIR/$arch/latest"
        rsync -a --delete "$WORKDIR/config-export/$nvr/$arch/" "$CONFIG_EXPORT_DIR/$arch/latest/"
      fi
    done
  fi

  git add -A
  GIT_AUTHOR_NAME="$GIT_IMPORT_NAME" \
  GIT_AUTHOR_EMAIL="$GIT_IMPORT_EMAIL" \
  GIT_COMMITTER_NAME="$GIT_IMPORT_NAME" \
  GIT_COMMITTER_EMAIL="$GIT_IMPORT_EMAIL" \
  GIT_AUTHOR_DATE="$bt_iso" \
  GIT_COMMITTER_DATE="$bt_iso" \
    git commit -m "Import ${nvr} (from SRPM: $(basename "$srpm"))" >/dev/null

  git -c user.name="$GIT_IMPORT_NAME" -c user.email="$GIT_IMPORT_EMAIL" \
    tag -a "$tag" -m "$nvr" >/dev/null

  popd >/dev/null
  log info "Imported and tagged: $tag"

  # Clean per-import tmp tree and config-export scratch
  if [[ "$PRUNE_TMP_AFTER_IMPORT" == "1" ]]; then
    rm -rf "$WORKDIR/tmp/rpmbuild-${nvr}" "$WORKDIR/config-export/$nvr" 2>/dev/null || true
  fi
}

# --- main --------------------------------------------------------------------
URLS="$WORKDIR/kernel-srpms.txt"
gather_urls "$MAJORS" "$URLS"
DISCOVERED=$(wc -l < "$URLS" 2>/dev/null || echo 0)

# already-imported tags
declare -A HAVE
while read -r t; do [[ -n "$t" ]] && HAVE["$t"]=1; done < <(git -C "$REPO_DIR" tag --list 'rhel*-*' || true)

# download only what's missing by tag
TODO="$WORKDIR/todo-urls.txt"; : > "$TODO"
while read -r u; do
  [[ -z "$u" ]] && continue
  nvr="$(nvr_from_url "$u")"; tag="$(tag_for_nvr "$nvr")"
  [[ -n "${HAVE[$tag]:-}" ]] && continue
  echo "$u" >> "$TODO"
done < "$URLS"

TODO_COUNT=$(wc -l < "$TODO" 2>/dev/null || echo 0)
ALREADY_TAGGED=$(( DISCOVERED - TODO_COUNT ))
# count how many TODO items are already cached (no download needed)
TO_DOWNLOAD=0
while read -r u; do
  [[ -z "$u" ]] && continue
  f="$WORKDIR/srpms/$(basename "$u")"
  [[ -s "$f" ]] || TO_DOWNLOAD=$((TO_DOWNLOAD+1))
done < "$TODO"
CACHED=$(( TODO_COUNT - TO_DOWNLOAD ))

# Summary line
log info "Summary: discovered ${DISCOVERED}, already tagged ${ALREADY_TAGGED}, to import ${TODO_COUNT} (cached ${CACHED}, to download ${TO_DOWNLOAD})"

# perform downloads
mkdir -p "$WORKDIR/srpms"
while read -r u; do
  [[ -z "$u" ]] && continue
  f="$WORKDIR/srpms/$(basename "$u")"
  if [[ ! -s "$f" ]]; then
    log info "Downloading: $(basename "$u")"
    curl -fL --retry 3 -o "$f.part" "$u" && mv "$f.part" "$f"
  fi
done < "$TODO"

# Build map: el  BUILDTIME  NVR  path (then sort per-major by build time)
MAP="$WORKDIR/srpm-map.tsv"; : > "$MAP"
for f in "$WORKDIR"/srpms/kernel-*.src.rpm; do
  [[ -e "$f" ]] || continue
  nvr="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$f" 2>/dev/null || basename "$f" .src.rpm)"
  rel="${nvr#kernel-}"; rel="${rel#*-}"
  el="$(sed -nE 's/.*\.el([0-9]+)(_.*)?/\1/p' <<<"$rel")"
  bt="$(rpm -qp --qf '%{BUILDTIME}\n' "$f" 2>/dev/null || echo 0)"
  printf "%s\t%010d\t%s\t%s\n" "$el" "$bt" "$nvr" "$f" >> "$MAP"
done
sort -t$'\t' -k1,1n -k2,2n -o "$MAP" "$MAP"

# Import loop
while IFS=$'\t' read -r el bt nvr srpm; do
  tag="$(tag_for_nvr "$nvr")"
  git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1 && continue
  tree="$(prep_from_srpm "$srpm")" || { log error "Skipping $nvr (prep failed)"; continue; }
  commit_version "$nvr" "$tag" "$tree" "$srpm"
  [[ "$KEEP_SRPMS" == "0" ]] && rm -f -- "$srpm" || true
done < "$MAP"

log info "Done. Repository: $REPO_DIR"
