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

### Out of scope: greenfield ("from scratch")

Building a project from scratch is NOT covered, and should not be forced into
this template. It violates the one invariant everything here rests on: there is
no green main, no load-bearing CI, and no trust boundaries yet, so every gate
(auto-merge's CI check, risk classification, keep-main-green sequencing) has
nothing to stand on.

Treat greenfield as a separate **phase-0 bootstrap** whose deliverable is exactly
this loop's preconditions: scaffold + CI + `CLAUDE.md` + `sensitive-paths.txt` +
branch protection. When phase-0 produces those, hand off to this loop.

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
6. Install the planning skill: copy `skills/split-task/` to
   `~/.claude/skills/split-task/`.
7. Branch protection on the default branch with CI (build/lint/test) as REQUIRED
   checks. Mandatory before enabling auto-merge -- no human reviews low-risk PRs,
   so the tests are the gate.

## What's inside

- `workflows/claude.yml` -- `@claude` issue -> implement -> draft PR + `@codex review`
- `workflows/codex-bridge.yml` -- Codex feedback -> capped, head-bound `@claude fix`
- `workflows/risk-label.yml` -- label a PR from `classify-risk.sh`
- `workflows/task-dispatcher.yml` -- stateless multi-task chain (one PR at a time)
- `workflows/auto-merge.yml` -- auto-merge low-risk PRs (OFF by default)
- `scripts/classify-risk.sh` -- deterministic risk from the diff
- `scripts/dispatch-tasks.sh` -- dispatcher logic (stateless, GitHub-derived state)
- `auto/sensitive-paths.txt` -- per-repo trust boundaries (you edit this)
- `auto-tasks/README.md` -- manifest schema for multi-task work
- `skills/split-task/` -- planning skill that writes a task manifest

## Security notes

- `classify-risk.sh` and `sensitive-paths.txt` are always read from the DEFAULT
  branch, never a PR checkout -- a PR must not be able to reclassify itself.
- Effective risk is always RECOMPUTED from the diff, never trusted from a label
  (Claude can set labels). Auto-merge and the bridge both recompute.
- `classify-risk.sh` fails safe to human-required on an empty/unknown diff or a
  300-file compare cap.
