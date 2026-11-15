# Issue tracker: beads

Issues and specs for this repo live in beads, a dependency-aware issue tracker configured in `.beads/` and committed with the repo. Use the `bd` CLI for all operations; pass `--json` when you need to parse output.

## Conventions

- **Create an issue**: `bd create "Title" -d "..."`. For multi-line bodies use `--body-file -` with a heredoc. Add `-l <label>` and `-p <0-4>` as needed.
- **Read an issue**: `bd show <id> --json`.
- **List issues**: `bd list --json` with `--status` and `--label` filters. `bd ready --json` lists open issues with no open blockers.
- **Make an issue a child of a parent**: `bd create "..." --parent <parent-id>`. List children with `bd children <parent-id>`.
- **Comment on an issue**: `bd comment <id> "..."`.
- **Apply / remove labels**: `bd update <id> --add-label "..."` / `--remove-label "..."`.
- **Close**: `bd close <id> --reason "..."`.

Issue IDs look like `yomi-a3f2dd`.

## Sharing

The database itself is gitignored. Two things carry issues between machines:

- `sync.remote` and the Dolt remote `origin` point at this GitHub repo. `bd sync` pulls, checks for conflicts, and pushes the Dolt database there (`bd dolt pull` / `bd dolt push` do one direction).
- `export.auto` is on, so `bd` writes `.beads/issues.jsonl` after writes. Commit it with the change it belongs to. It is an export, not the source of truth.

On a fresh clone, run `bd bootstrap` (tested with `bd` 1.3.4). It clones from the Dolt remote when GitHub has Dolt data, and otherwise imports `.beads/issues.jsonl`.

## Which tracker owns the work

Beads is where the engineering skills create and triage issues. GitHub issues stay in use for the `agent-ready` workflow (`.github/workflows/agent-task.yml`) and for bug reports and feature requests filed through the issue templates.

- **PR for a GitHub issue**: link it with `Closes #<number>`, as `AGENTS.md` says.
- **PR for a bead**: merging does not close it. Put the bead ID in the PR body, and run `bd close <id>` once the PR merges.

## When a skill says "publish to the issue tracker"

Create a bead with `bd create`.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single bead with **child** beads as tickets.

- **Map**: a bead labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `bd create "..." -l wayfinder:map`.
- **Child ticket**: `bd create "..." --parent <map-id> -l wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: `bd dep add <blocked-id> <blocker-id>`. A ticket is unblocked when every blocker is closed.
- **Frontier query**: `bd ready --parent <map-id> --unassigned --json`; first in map order wins.
- **Claim**: `bd update <id> --claim`, the session's first write.
- **Resolve**: `bd comment <id> "<answer>"`, then `bd close <id>`, then append a context pointer to the map's Decisions-so-far.
