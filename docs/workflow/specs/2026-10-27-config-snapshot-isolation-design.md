# Config export state isolation

## Problem and scope

Issue #7: `export_configs` removes source `.config`, seeds and generates it per
architecture, then leaves the final generated state for `commit_one` to copy.
The exporter owns temporary state; the snapshot copier should preserve source
inputs, including any legitimate original `.config` and `.config.old`.

## Design

Point Kconfig's existing `KCONFIG_CONFIG` environment variable at a per-architecture
file in the existing export staging directory, outside the source tree. Seed that
file from the selected original candidate, run `make olddefconfig` in the source
working directory, copy successful output to the existing resolved-config name,
and delete the temporary file and its `.old` sibling after success or failure.
No interfaces, architecture defaults, or snapshot copier policy change.
Original inputs remain available for candidate export and subsequent architectures.

## Success

Actual imports using local RPM fixtures produce tagged snapshots without temporary
root configs when none were supplied. Original root config bytes survive unchanged.
Exports retain architecture-specific resolved output. Failed generation cannot leak
partial config state into the source snapshot; existing best-effort behavior stays.
Consumers select `metadata/configs/<arch>/<tag>/` or `latest/`, not root `.config`.

## Failure model

Prevented: generated or partially generated root config entering a future snapshot.
Handled: failed `olddefconfig` logs a warning and cleans its temporary config files.
Accepted: existing unrelated Kbuild generated files and abrupt process termination;
staging is already outside the source tree, and interruption cannot publish a tag.
Deployment: existing Linux/container Bash import path; configured x86_64, ppc64le,
and s390x export targets remain unchanged. No remote import or existing-tag rewrite.

## Validation

`tests/config-export-snapshot.sh` drives the importer and actual snapshot commit
with isolated external command fixtures. It covers no original config, preserved
original config and backup, failed generation, and generation disabled. Assert
snapshot contents and per-architecture exports. Run red before implementation,
then green, relevant existing import tests, shellcheck and shfmt. Consumer prose
has no executable contract; review it against the actual metadata layout.
