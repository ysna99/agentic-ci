# auto-tasks

Manifests that drive the **stateless auto-task dispatcher**
(`.github/workflows/task-dispatcher.yml` -> `.github/scripts/dispatch-tasks.sh`).

Each plan lives in its own subdirectory:

```
.github/auto-tasks/<slug>/
  plan.md      # the approved plan (provenance; optional)
  tasks.json   # ordered, immutable task manifest
```

## tasks.json: an immutable spec

You author it once; the dispatcher **never writes it back**. There are no
`status`, `issue`, or `order` fields: array order is the order, and task state is
derived from GitHub on every run (see below).

```json
{
  "slug": "refactor-foo",
  "paused": false,
  "max_tasks": 20,
  "tasks": [
    { "id": 1, "title": "Extract helper", "body": "what @claude should do", "depends_on": [] },
    { "id": 2, "title": "Migrate callers", "body": "...", "depends_on": [1] }
  ]
}
```

- `slug`: kebab id for the chain; also the label prefix (`at:<slug>-<id>`).
- `paused`: `true` freezes the whole manifest.
- `max_tasks`: hard cap on how many task issues this manifest will ever open.
- `tasks[]`: `id` (unique integer), `title`, `body` (the `@claude` instruction),
  `depends_on` (ids that must be **done** first).

## Derived state (no stored progress)

Each run derives every task's state from issues/PRs. Nothing is persisted, so
there is no write to the protected default branch:

| State | Meaning |
|-------|---------|
| **PENDING**   | no `at:<slug>-<id>` issue exists yet |
| **IN_FLIGHT** | that issue exists, is open, and no merged PR has completed it |
| **DONE**      | a merged PR with head `claude/issue-<N>-*` exists (`N` = the task's issue number) |
| **BLOCKED**   | the issue is **closed** and there is no such merged PR (a human said no) |

Task-to-issue binding is the unique label **`at:<slug>-<id>`** the dispatcher puts
on each issue it opens (plus an `<!-- auto-task slug=... id=... -->` marker in the body).

## How it works

1. Generate a manifest with the `/split-task` skill (after the plan is reviewed).
2. Merge a PR that adds `<slug>/tasks.json` with `"paused": false`. That merge
   (a `pull_request: closed` event) kicks off the dispatcher. Or run the workflow
   manually (`gh workflow run "Auto task dispatcher"`).
3. The dispatcher opens the first eligible task (deps all **DONE**) as an `@claude`
   issue via `CLAUDE_PR_PAT`, one at a time, only when nothing is **IN_FLIGHT**,
   and advances one task per merged PR.
4. Each issue runs the normal build loop (draft PR, `@codex review`, bridge).
   A human reviews and merges every PR; **nothing is auto-merged**.
5. If a task issue is **closed without** a merged `claude/issue-<N>-*` PR, the
   dispatcher treats it as **BLOCKED**, comments once, and **stops the chain**.

## Controls

- **Stop:** set `"paused": true`, or set repo variable `AUTO_TASKS_ENABLED=false`.
- **Resume after a block:** complete/reopen the blocked task, then re-run the
  workflow (`gh workflow run ...`) or merge any PR to re-trigger.
- Only one manifest progresses at a time (the first non-paused one with work left).

## Requirements

- Secret **`CLAUDE_PR_PAT`** (issues opened by the default `GITHUB_TOKEN` do not
  trigger `claude.yml`; a human-owned PAT does).
- The base loop (`claude.yml`, draft PR, Codex, bridge) unchanged.
- Workflow token needs only `contents: read` (checkout); all writes use the PAT.
