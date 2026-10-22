# Preserve the original kernel spec

## Problem
Issue #5: prep imports omit the original packaged kernel.spec and its changelog.

## Scope
For new MODE=prep imports, preserve the extracted spec as
`$top/kernel.spec` before either compatibility sanitizer runs. Both extraction
paths converge here; explicitly check the fallback EXTRACT-to-SPECS copy
before trusting its destination. Keep the existing sanitized SPECS file for rpmbuild.
Before staging the prepared source snapshot, copy the preserved file to
`$REPO_DIR/kernel.spec`, replacing any same-named source-tree entry.
Force-stage kernel.spec in prep mode so repository ignore rules cannot omit it.
Check copies and explicit staging failures: prep_srpm is called in a conditional command
substitution, so Bash errexit alone cannot enforce preservation failure.
Report actionable errors and prevent a commit/tag without the original spec.
prep_srpm owns preservation, commit_one owns assembly; signatures stay unchanged.
Historical commits/tags and MODE=sources packaging layout are excluded, owned
by future separately requested work. Operator approved these exclusions and
the design in the current session. Operator separately authorized shfmt of both
scripts, isolated in its own commit. No ownership transition or ADR is needed.

## Success
- A new prep-mode tag contains kernel.spec byte-identical to extracted input,
  including %changelog, even with an existing ignore rule, while rpmbuild uses the modified compatibility copy.
- Preservation or final-copy failure logs the failed operation and creates no
  tag/commit for that version. Preservation failure follows existing skip policy;
  assembly failure returns nonzero before staging.
- Re-running an existing tag leaves its object identity and contents unchanged.
- MODE=sources retains its existing packaging/SPECS compatibility copy layout.

## Failure model
- Actors and deployments: local operator running the Bash importer, normally
  in Rocky 9/10 containers; tests stub RPM/network boundaries in temporary repos.
- Invariants and assets: original spec bytes, changelog, existing tag identities;
  sanitizers still apply only to the build copy.
- Accepted failures: existing prep failure skip semantics and partially assembled
  uncommitted worktree after copy failure; transactional importer recovery is
  outside this change and unnecessary to prevent an incorrect commit.
- Other owners: historical backfill and sources-layout changes belong to future
  separately requested work; RPM toolchain installation remains container setup.

## Validation
`tests/original-kernel-spec.sh` runs the real importer and Git assembly with
stubbed curl/rpm/rpmbuild and controlled cp failures.
- Mode: focused-test; original bytes, changelog, sanitizer separation, extraction
  fallback and partial fallback-copy failures, ignored destination, root replacement and repeat-tag stability; baseline red is absent
  kernel.spec at the imported tag; green: `bash tests/original-kernel-spec.sh`.
- Mode: focused-test; failed preservation and final copy; baseline red is an
  incorrectly successful import/tag or missing diagnostic; same green command.
- Mode: focused-test; unchanged sources packaging layout; same green command.
- Formatting: existing shellcheck and shfmt recipes, all existing shell tests.
- No full remote kernel imports: fixtures exercise this file-copy contract;
  RPM %prep execution and compilation behavior are unchanged.
