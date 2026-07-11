---
name: bootstrap-project
description: Phase-0 bootstrap for greenfield ("from scratch") projects. Interview the human into an approved spec (docs/spec.md), scaffold with the ecosystem's own generator, install CI + CLAUDE.md + the agentic-ci engine + declared trust boundaries, arm branch protection, and verify the brownfield preconditions so the normal loop takes over. Use when starting a NEW project that should end up running the agentic-ci loop.
---

# bootstrap-project -- manufacture the brownfield preconditions

The agentic-ci engine is brownfield-only: every gate stands on a green default
branch, load-bearing CI, and declared trust boundaries. A from-scratch project
has none of those, so it must not START on the loop. This skill is the phase-0
bootstrap whose deliverable is exactly those preconditions. It changes NOTHING
in the engine -- everything greenfield-specific is data (spec, boundaries,
manifest) plus this procedure, so there is one engine to maintain, not two.

A new repo has no tests, so the non-LLM ground truth the safety model needs is
staged in deliberately:

| Stage | Non-LLM ground truth | Exists when |
|-------|----------------------|-------------|
| 0 | Human review of every merge + build/typecheck/lint in CI | first commit (generator scaffolds are green) |
| 1 | Smoke test in CI: the app starts and answers | the walking-skeleton task merges |
| 2 | Acceptance tests per feature, criteria frozen in the human-approved manifest | each feature task |
| 3 | Full brownfield posture; auto-merge defensible | a human flips `AUTO_MERGE_ENABLED` at the checkpoint |

The stage-2 substitution is the load-bearing idea: LLM-written tests validating
LLM-written code is circular, and the circle is broken by where the acceptance
criteria COME FROM -- the human-approved spec/manifest, frozen before
implementation. Review then asks a mechanical question: do the tests encode the
listed criteria, and does the code pass them?

## Phase -1 -- spec (interactive; do NOT scaffold yet)

1. Interview the user. Capture concretely:
   - goals and NON-goals (what this project deliberately will not do);
   - stack: framework, language, package manager, test runner -- prefer what
     the user already knows over what benchmarks well;
   - trust boundaries BEFORE any code exists: what will touch money, auth,
     admin, uploads, PII, external APIs (these become `sensitive-paths.txt`);
   - the walking skeleton: the thinnest end-to-end slice (one page renders /
     one endpoint answers) and how to observe it -- that observation is the
     future smoke test;
   - an ordered feature list, each with enumerated, testable acceptance
     criteria. These become task bodies nearly verbatim; vague criteria here
     become wasted fix rounds later, and fix rounds are the expensive loop;
   - deploy target, noted as OUT of automation scope (a human deploys; CI
     smokes a locally started app, never production).
2. Write the spec to a SCRATCH file first, not the project directory --
   scaffold generators refuse or complain about non-empty directories.
   Sections: Goals / Non-goals / Stack / Trust boundaries / Walking skeleton /
   Features (each with acceptance criteria).
3. Present it for approval and iterate. Proceed only on explicit approval.
   This human gate is what later substitutes for the missing test suite.

## Phase 0 -- bootstrap (ends with a verified brownfield repo)

1. Scaffold with the ecosystem's OWN generator -- never hand-write boilerplate
   a generator produces (it is deterministic, green, and thousands of lines
   that never pass through a model): `npx create-next-app@latest`,
   `npm create vite@latest`, `django-admin startproject`, `cargo new`,
   `dotnet new`. If the ecosystem has no official generator (e.g. Flask),
   write the minimal canonical skeleton (app factory, one route, test config)
   and keep it under ~100 lines.
2. `git init` if the generator did not; move the approved spec to
   `docs/spec.md`; commit.
3. Write `CLAUDE.md` from the template below, filling in the stack's real
   commands. It is the context carrier every future cold `@claude` run reads
   instead of re-deriving the project.
4. Write `.github/workflows/ci.yml` from the template below. Keep the single
   job named `checks`: branch protection pins that one name, so later
   verification (the skeleton's smoke test, real test suites) joins the SAME
   required check as new steps, without ever editing protection again.
5. Copy the engine VERBATIM from the agentic-ci repo: all five
   `.github/workflows/*.yml` engine files, `.github/scripts/*.sh`,
   `.github/auto-tasks/README.md`, `.github/pull_request_template.md`.
6. Write `.github/auto/sensitive-paths.txt` from the spec's Trust boundaries
   section -- one extended-regex fragment per line. ALWAYS include these two
   first (the agent's own instructions and the ground-truth document must
   never change without human eyes):

   ```
   ^CLAUDE\.md$
   ^docs/spec\.md$
   ```
7. Run the CI commands locally. Everything green before the first push.
8. Confirm with the user, then create the repo and push:
   `gh repo create <owner>/<name> --private --source . --push` (or `--public`).
   Protection is not armed yet; this is the only direct-to-default-branch push
   this project will ever get.
9. Arm and verify: `bash bootstrap/protect.sh <owner/repo>` from the
   agentic-ci checkout. It sets branch protection (required check `checks`,
   admins cannot bypass) and `MAX_FIX_ROUNDS`, then verifies the preconditions
   and prints what only a human can finish: the two secrets and the Codex app
   install. Re-run with `--verify` after those until it prints
   `ALL PRECONDITIONS PASS`. That line is the handoff: the repo now IS a
   brownfield repo, and nothing downstream is greenfield-specific.
10. Plan the work: run `/split-task` on `docs/spec.md`. It will choose the
    GREENFIELD (skeleton-first) strategy and write a paused manifest. Task 1
    is always the walking skeleton; merging it wires the smoke test into CI
    and makes CI load-bearing (stage 1).

## After the handoff

Activation and controls are the normal engine (`.github/auto-tasks/README.md`).
Expect the walking-skeleton PR to classify human-required (it touches
`.github/` to add the smoke step) -- that is correct, not a bug; it is the
moment CI becomes load-bearing, and a human should be looking. Auto-merge
stays OFF until the human flips `AUTO_MERGE_ENABLED` at the stage-3
checkpoint, once the accumulated acceptance tests have real teeth.

## CLAUDE.md template

```markdown
# CLAUDE.md

## Project
<one paragraph: what this is and who it serves. Full spec: docs/spec.md>

## Commands
- dev server: <cmd>
- build: <cmd>
- typecheck / lint: <cmd>
- tests: <cmd>

## Verification -- run after every change
<build + typecheck + lint + test commands>

Never push red: CI runs exactly these checks, and a red push wastes a full
review round. Fix failures locally first.

## GitHub Automation (when triggered by @claude)
- Work on a branch. Never push to the default branch. Never merge.
- Do NOT run `gh pr create`: a workflow opens a draft PR for you and requests
  the Codex review.
- Hand off the PR description by writing /tmp/pr_body.md (summary, reason,
  files touched, checks run with results). Do NOT add a "Risk level:" line --
  risk is classified deterministically from the diff.
- Task issues enumerate acceptance criteria. Implement ALL of them and add the
  tests that PROVE them in the SAME PR -- tests and implementation land
  together.
- If the change creates a new trust boundary (first payments / auth / admin /
  uploads / PII code), add the matching regex line to
  .github/auto/sensitive-paths.txt in the same PR.
- On "@claude fix Codex feedback": push fixes to the SAME PR branch. No new
  PR. Do not mark the PR ready for review and do not merge.
```

## ci.yml template

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  # Single job on purpose: branch protection pins the name "checks" as the
  # required status check, so later verification (the walking skeleton's smoke
  # test, real test suites) is added as STEPS here and becomes required
  # automatically -- protection is never edited again.
  checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # <setup runtime: actions/setup-node / setup-python / ... with lockfile cache>
      # <install dependencies>
      # <build>
      # <typecheck and lint>
      # <tests>
      # The walking-skeleton task adds the smoke step here:
      # <start the app in the background, curl the health endpoint, fail on non-200>
```

## Output summary to the user

- The spec path and its approval status.
- What was scaffolded and with which generator.
- The protect.sh verification result (or the outstanding manual items).
- The manifest path from /split-task and the reminder that it is paused.
