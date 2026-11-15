Implement this build task issue. Follow AGENTS.md.

- Do exactly what the Goal and Acceptance criteria ask. Do not touch anything listed under
  Out of scope, and do not refactor or reformat unrelated code.
- Follow the patterns in the files listed under Context.
- Add or update tests for the behavior you change.
- Run `make lint` and `make test` and fix any failures. These, `make build`, `make check`,
  and read-only git commands (`status`, `diff`, `log`, `show`) are the only shell commands
  you may run. If the Verification section lists others, say they were not run.
- Do not commit, push, or switch branches. Your changes are committed and pushed for you.
- If the task is ambiguous or cannot be done as written, make no changes and explain what
  is missing instead.

Your final reply becomes the pull request description. Write it in exactly this format,
using what actually happened:

## Problem

What the issue asked for, in a sentence or two.

## Change

How you implemented it, and why this approach.

## Scope

Closes the issue. Note anything you deliberately left out.

## Verification

Each command you ran and what it printed or showed. Say plainly if a check failed or
could not be run.

## Merge Risk

Low, medium, or high, and why. What could break after merge, and who or what would notice.
Call out migrations, config or infrastructure changes, public API or schema changes, and
feature flags. Say how to roll back: a plain revert, or extra steps.

Implemented by OpenCode with the model named in the workflow run.
