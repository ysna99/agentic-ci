# agentic-ci

Reusable GitHub automation for an agentic development loop:
**Claude = developer, Codex = reviewer, human = owner.**

Drop the `.github/` tree into a repo and an `@claude` issue becomes a branch and
a draft PR, Codex reviews it, Claude fixes the feedback (capped), and a human --
or auto-merge for low-risk changes -- merges. A stateless dispatcher chains
multi-step work one PR at a time, advancing on each merge.

## Scope: brownfield evolution

This template is a BROWNFIELD engine. It assumes the target repo already has:

- a working default branch with CI (build / lint / test) that is load-bearing,
- branch protection with those checks required,
- a `CLAUDE.md`, and
- its trust boundaries declared in `.github/auto/sensitive-paths.txt`.

The whole safety model rests on CI being a non-LLM ground truth. Both the
developer (Claude) and the reviewer (Codex) are LLMs, so a closed LLM-reviews-LLM
loop can mutually agree on something wrong -- tests are the only thing outside
that loop that can say "this is actually broken."

### Work types it covers

| Work type        | Split strategy      | Merge path                       |
|------------------|---------------------|----------------------------------|
| Refactoring      | sequential chain    | small PRs, main green between     |
| New features     | sequential / hybrid | single or chained PRs             |
| Version upgrades | atomic (one PR)     | human-required (touches manifests)|

`/split-task` picks the strategy (atomic / sequential / hybrid). The variation
between work types is DATA -- the manifest strategy plus the per-repo denylist --
not a fork of the workflow. That is what keeps everything on one pipeline.

Upgrades classify atomic and touch dependency manifests, so `classify-risk.sh`
flags them human-required and they never auto-merge. That falls out of the
existing mechanisms; there is no per-type workflow.

### Greenfield ("from scratch"): a separate entry ramp, same engine

Building from scratch cannot START on this loop: there is no green main, no
load-bearing CI, no trust boundaries, so every gate would have nothing to stand
on. It is not forced in. Instead, `skills/bootstrap-project` is a **phase-0
bootstrap** whose deliverable is exactly this loop's preconditions:

    spec -> generator scaffold -> CI + CLAUDE.md + engine copy +
    sensitive-paths.txt -> branch protection -> verified handoff

The engine files stay byte-identical to this template -- everything
greenfield-specific is data and skills, the same principle that keeps work-type
variation out of the workflows. From the first task on, the UNMODIFIED engine
runs.

Because a new repo has no tests, the non-LLM ground truth is staged in:

| Stage | Non-LLM ground truth                          | Exists when |
|-------|-----------------------------------------------|-------------|
| 0     | Human review of every merge + build/lint CI   | first commit (generator scaffolds are green) |
| 1     | Smoke test in CI (app starts and answers)     | walking-skeleton task merges |
| 2     | Acceptance tests per feature, criteria frozen in the approved manifest | each feature task |
| 3     | Full brownfield posture; auto-merge defensible | human flips `AUTO_MERGE_ENABLED` at the checkpoint |

Test discipline: each task's acceptance criteria are enumerated in the
human-approved manifest (written by `/split-task`'s greenfield strategy from
`docs/spec.md`), and tests land in the SAME PR as the implementation. Review
verifies code against human-frozen criteria -- that provenance is what breaks
the LLM-writes-tests-for-LLM-code circle. Auto-merge stays OFF until a human
arms it at the stage-3 checkpoint.

Start from scratch:

1. Run `/bootstrap-project` in the new project's directory (interview ->
   approved `docs/spec.md` -> scaffold with the ecosystem's generator ->
   CI + CLAUDE.md + engine + boundaries -> push).
2. `bash bootstrap/protect.sh <owner/repo>` from this repo's checkout; finish
   its manual checklist (secrets, Codex app); re-run with `--verify` until it
   prints ALL PRECONDITIONS PASS.
3. `/split-task docs/spec.md` -> paused manifest -> activate (see the
   auto-tasks README). Task 1, the walking skeleton, makes CI load-bearing.

## Apply to a repo

1. Copy `.github/` into the target repo.
2. Declare this repo's trust boundaries in `.github/auto/sensitive-paths.txt`
   (one extended-regex fragment per line; `#` comments ignored). The universal
   boundaries are already built in -- add only repo-specific paths.
3. Secrets: `CLAUDE_PR_PAT` (fine-grained PAT: Contents RW, Pull requests RW,
   Issues RW, Metadata R; no workflow scope) and `ANTHROPIC_API_KEY`.
4. Repo variables (all optional, safe defaults):
   - `AUTO_TASKS_ENABLED=true` to arm the multi-task dispatcher
   - `AUTO_MERGE_ENABLED=true` to arm auto-merge (requires step 7)
   - `MAX_FIX_ROUNDS` (default 3)
   - `CODEX_BOT_LOGIN` (default `chatgpt-codex-connector[bot]`)
5. Install the official Codex GitHub review app on the repo.
6. Install the skills: copy `skills/split-task/` (and, if you start new
   projects, `skills/bootstrap-project/`) into `~/.claude/skills/`.
7. Branch protection on the default branch with CI (build/lint/test) as REQUIRED
   checks, and "Do not allow bypassing the above settings" enabled -- the PAT
   owner is usually an admin, and without it the merge API lets admins past red
   required checks. Mandatory before enabling auto-merge -- no human reviews
   low-risk PRs, so the tests are the gate (auto-merge evaluates exactly the
   REQUIRED checks, via `gh pr checks --required`).

## What's inside

- `workflows/claude.yml` -- `@claude` issue -> implement -> draft PR + `@codex review`
- `workflows/codex-bridge.yml` -- Codex feedback -> capped, head-bound `@claude fix`
- `workflows/risk-label.yml` -- label a PR from `classify-risk.sh`
- `workflows/task-dispatcher.yml` -- stateless multi-task chain (one PR at a time)
- `workflows/auto-merge.yml` -- auto-merge low-risk PRs (OFF by default)
- `scripts/classify-risk.sh` -- deterministic risk from the diff
- `scripts/effective-risk.sh` -- stricter-of(body, diff) risk; the one source the
  bridge, the label, and auto-merge all gate on
- `scripts/dispatch-tasks.sh` -- dispatcher logic (stateless, GitHub-derived state)
- `auto/sensitive-paths.txt` -- per-repo trust boundaries (you edit this)
- `auto-tasks/README.md` -- manifest schema for multi-task work
- `skills/split-task/` -- planning skill that writes a task manifest
- `skills/bootstrap-project/` -- phase-0 greenfield bootstrap (spec -> scaffold
  -> engine -> verified handoff)
- `bootstrap/protect.sh` -- one-shot arming (branch protection + vars) and
  verification of the brownfield preconditions; the greenfield handoff gate

## Security notes

- `classify-risk.sh` and `sensitive-paths.txt` are always read from the DEFAULT
  branch, never a PR checkout -- a PR must not be able to reclassify itself.
- Effective risk is always RECOMPUTED from the diff, never trusted from a label
  (Claude can set labels). Auto-merge and the bridge both recompute, through the
  shared `effective-risk.sh`.
- `classify-risk.sh` fails safe to human-required on an empty/unknown diff, a
  300-file compare cap, or a malformed regex in `sensitive-paths.txt` (a config
  typo must not silently disable the sensitive check).
- Fork PRs are excluded from both the bridge and auto-merge: the loop only
  operates on same-repo `claude/*` branches, so a drive-by author can never
  reach the automated fix or merge paths.
- Auto-merge requires the LATEST Codex review on the exact current head to be
  APPROVED, and merges with `--match-head-commit` -- a push landing between
  evaluation and merge fails the merge instead of sneaking in unreviewed.
- Claude's PRs stay drafts until auto-merge's gates all pass (simple + approved
  + required checks green); passing them is what flips the PR ready and merges
  it. Every other PR waits for a human to undraft and merge.
