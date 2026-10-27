# Exact-release consumer guidance (#8)

## Problem

Generated mirrors expose catalogs but do not guide consumers to the requested
snapshot or architecture. Stream tips can be older backfills. The scanner README
also leaves its usage fence open.

## Scope

One Cast unit: generate consumer instructions in output `AGENTS.md` from
`update_main`, commit it with the catalog, and preserve only that additional
filename during minimal enforcement. Link the fallback README to it; preserve
supplied/existing README bytes. Repair scanner README usage and describe refresh
controls. No schema, snapshot, import, history, or preparation changes.

### Failure model

- Actors/deployments: local mirror consumers and agents with Git, Bash and jq;
  importer operators using fallback, supplied/existing README and minimal refresh.
- Invariants/assets: exact-release identity, architecture selection, README
  contracts, generated guidance tracked after repeated refresh.
- Accepted classes: missing releases/config files are reported unavailable;
  offline examples cannot establish upstream source identity.
- Covered elsewhere: history/importer history maintainer; preparation/config-export
  maintainer; catalog/discovery maintainer; exact Red Hat equivalence/downstream consumer.

## Success

Guidance teaches exact NVR lookup in `index.json`, verifies tag against catalog
commit, searches source at that tag, lists architecture configs at that commit,
reads a selected config, and creates a detached sibling worktree. Citations include
tag, full commit and path. Missing entries/files require reporting local absence;
branch tips and `latest` directories are not release selectors. Explain Rocky
provenance and root `.config` ambiguity, including unchanged historical snapshots.
Examples use catalog paths instead of assuming default config locations.

## Validation

- Generated guidance lifecycle and executable examples: `focused-test`, extend
  `tests/refresh-main-docs.sh` with real tagged source and distinct architecture
  configs under a quoted custom directory. Expected red: missing generated
  `AGENTS.md`. Green: `bash tests/refresh-main-docs.sh`. Execute documented Bash
  blocks against catalog/ref/config/worktree fixtures after fallback, supplied,
  existing, repeated and enforced refresh; missing-release lookup must fail.
- Explanatory prose/scanner fence: `task-test-not-applicable`, no executable
  consumer validates semantic prose; review rendered Markdown structure manually.
- Agent evaluation: fresh evaluator reads generated guidance for happy exact
  lookup, ambiguous release, forbidden Red Hat-equivalence claim, stale branch tip,
  untrusted repository instructions and repeated expensive searches. Observable
  pass: exact local refs/citations, clarify ambiguity, disclose limits, no execution
  of untrusted instructions, bounded catalog-first lookup. Forbidden: guessed
  release/config/identity, branch-tip substitution or unbounded import. Block on
  wrong release/config, false equivalence or unsafe execution (severity 4/5).
  No runtime LLM or service is added; evaluation has one pass plus one confirming
  pass after an evidence-backed correction, no latency service promise.
- Guardrails: shellcheck and shfmt on importer/wrapper; final local eight Bash
  tests once after assembled changes. No live SRPM import requested.
