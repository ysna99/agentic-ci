---
name: split-task
description: Analyze an approved implementation plan, choose the right decomposition strategy (atomic / sequential / hybrid), propose tasks with rationale for human confirmation, then write a paused task manifest (tasks.json) for the auto-task dispatcher. Use after a plan is ready and you want to turn it into dispatchable GitHub issues.
---

# split-task — analyze a plan and write a (paused) task manifest

This skill turns an approved plan into an ordered task manifest that the
`task-dispatcher.yml` workflow can dispatch as sequential `@claude` issues. It does **not** create
issues, branches, or PRs, and it does **not** start any automation. It only writes a local file, and
that file is written **`paused: true`** — the chain starts only when the human deliberately activates
it (see "Activation" below).

## Inputs
- A plan: use the path in the skill args if given; otherwise the most recent file in `.claude/plans/`,
  or the plan in the current conversation (write it to a temp file first if needed).
- The target repository working tree (where the manifest will be written). Default:
  `KISA-website-client`. If the current directory is not that repo, ask the user for the path.
- Greenfield: the input is the approved `docs/spec.md` written by `/bootstrap-project`, and the
  target is the freshly bootstrapped repo (the current directory).

## Phase 1 — Analyze and classify the strategy

Read the plan and decide how it should be split, using these rules in order:

0. **GREENFIELD** (skeleton-first sequential) when the input is a project spec from
   `/bootstrap-project` (`docs/spec.md`) for a freshly bootstrapped repo, rather than a change to an
   existing codebase:
   - Task 1 is ALWAYS the walking skeleton: the thinnest end-to-end slice (one page renders / one
     endpoint answers), and its acceptance criteria include wiring the smoke test (start the app,
     hit it, fail on non-200) as a STEP inside the existing `checks` CI job. That PR touches
     `.github/` so it self-classifies human-required — expected: it is the moment CI becomes
     load-bearing, and a human should be looking.
   - Every later task is one feature slice that leaves `main` green on its own, sequential
     (`depends_on` the previous slice) unless the spec proves two slices genuinely independent.

1. **ATOMIC** (one coordinated PR) if **either**:
   - splitting the work the natural way would leave `main` in a broken / un-buildable state at any
     intermediate merge (build fails, types don't compile, tests red); or
   - there is a single cross-cutting change everything else depends on that cannot stand green on its
     own — e.g. a framework or major-version upgrade, a shared type / interface / API-signature
     change used widely, or a config/runtime change.
   Typical: `Next 14 → 15`, `React 18 → 19`, renaming a core API used across the codebase.

2. **SEQUENTIAL** (decomposable, multi-task) if the work divides into multiple units that are each
   independently buildable, independently testable, and individually mergeable — every task leaves
   `main` green on its own.
   Typical: per-module migration, slice-by-slice rename, adding tests, breaking up a large file,
   incremental refactor.

3. **HYBRID** if there is an atomic core that must land first (task 1), followed by independent
   follow-ups that `depend_on` it.

The decisive test is always: *"if this task merged alone, would `main` still build and pass checks?"*
If no, it cannot be its own task — merge it into the atomic core.

## Phase 2 — Propose, then get human confirmation (REQUIRED)

Do **not** write the manifest yet. First present to the user:
- the chosen **strategy** and a short **rationale** (why atomic vs sequential vs hybrid, citing the
  ripple points / cross-cutting changes you found);
- the proposed **task list** (title + one-line scope + `depends_on` for each);
- for ATOMIC, a note if the single PR will be large/hard to review, and whether any safe seams exist.

Ask the user to confirm or adjust (merge tasks, re-split, reorder, change strategy). Only proceed once
they approve. This human gate on the *decomposition* is the cheap insurance against a bad split that
would poison the chain.

## Phase 3 — Write the manifest

After approval, write:
- `.github/auto-tasks/<slug>/tasks.json`
- `.github/auto-tasks/<slug>/plan.md` (a copy of the plan, for provenance)

where `<slug>` is a short kebab-case name for this plan.

### tasks.json schema (must match the dispatcher)
The manifest is an **immutable spec** — the dispatcher never writes it back. It derives task
state from GitHub (issues/PRs) each run, so there are **no `status`, `issue`, or `order` fields**;
array order is the order.
```json
{
  "slug": "<kebab-slug>",
  "strategy": "atomic | sequential | hybrid",
  "paused": true,
  "max_tasks": 20,
  "tasks": [
    { "id": 1, "title": "Short title", "body": "Self-contained instructions, acceptance criteria, and which checks to run (npx tsc --noEmit, npm run lint, npm test).", "depends_on": [] },
    { "id": 2, "title": "Short title", "body": "...", "depends_on": [1] }
  ]
}
```

Rules for the manifest:
- Always write `"paused": true`. The user activates deliberately.
- Do NOT add `status` / `issue` / `order` — the dispatcher derives all progress from GitHub
  (issue label `at:<slug>-<id>` + merged `claude/issue-<N>-*` PRs). Author only the fields above.
- `id`s are unique integers; `depends_on` lists the ids that must be **done** (merged) first.
- **Each `body` must be self-contained**: a fresh `@claude` run starts cold with no memory of other
  tasks or this plan, so include what to do, where in the codebase, acceptance criteria, and the
  checks to run. Do not reference sibling tasks by number.
- For ATOMIC work, emit a **single task** (the whole coordinated change) — do not artificially split.
- Keep `max_tasks` conservative; the dispatcher refuses to exceed it.
- Avoid sensitive paths unless a task is specifically about them; such PRs are auto-labeled
  `human-required` (the chain still works — it just waits at your merge gate).

GREENFIELD manifests additionally:
- Each `body` is the feature's enumerated acceptance criteria (a checklist copied from the approved
  spec) plus `See docs/spec.md#<section>` for context — reference the spec, don't restate it: bodies
  are echoed into issues, PR bodies, and every fix round, so repetition compounds token cost.
- Tests land in the SAME PR as the implementation (criteria-in-one-PR is the default). The review
  question is mechanical: do the tests encode the listed criteria, and does the code pass them?
  The criteria's human-approved provenance is what breaks the LLM-tests-LLM-code circle.
  EXCEPTION (opt-in, for genuinely subtle core logic only): a two-PR split — PR1 lands the criteria
  as skipped test skeletons plus fixtures (merges green), PR2 implements and unskips. It costs a
  second review round; never default to it.
- A task that creates a NEW trust boundary (first payments / auth / admin / uploads / PII code) must
  add the matching `.github/auto/sensitive-paths.txt` line in the same PR. That makes the PR
  human-required by construction — the boundary map only ever changes under human eyes.
- If the plan extends past the auto-merge maturity checkpoint (the stage table in the README), split
  into TWO manifests: `<slug>-core` (through the checkpoint) and `<slug>-more` (`paused: true`).
  The checkpoint is a human review — flipping the second manifest on (and, if satisfied,
  `AUTO_MERGE_ENABLED`) — not a dispatchable task; the dispatcher would hand a task to Claude, who
  cannot and must not arm autonomy levels.

## Activation (tell the user this after writing)

Nothing runs until the user activates. To start the chain:
1. Commit `.github/auto-tasks/<slug>/` to the repo (while `paused: true` it stays inert).
2. **Activate** by either: setting `"paused": false` and committing, OR running
   `gh workflow run task-dispatcher.yml`, OR setting repo variable `AUTO_TASKS_ENABLED=true`.

Then the dispatcher opens task #1 as an `@claude` issue and advances **one task per merged PR**. To
pause at any time, set `"paused": true` again (or `AUTO_TASKS_ENABLED=false`). The human merges every
PR; nothing is auto-merged.

## Output summary to the user
- The strategy chosen and why.
- The manifest path and task count.
- A reminder that it is `paused` and how to activate when ready.
