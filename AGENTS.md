# Agent instructions

Read this before changing anything in this repository.

## Project

<!-- One paragraph: what this project is, its main language and framework, and where the
     important code lives. Update this when you create a repository from the template. -->

## Commands

- `make lint`: lint and format checks
- `make test`: the test suite
- `make build`: build the project
- `make check`: all three

Run `make lint` and `make test` before you say a change works.

## Template setup

This repository starts as a template. It is unconfigured while a `make` target prints
"not configured yet" or the Project section above is empty.

- **The template itself keeps its placeholders.** If `gh repo view --json isTemplate`
  reports `true`, this is the template source: report placeholder output under
  Verification and leave setup alone unless the user confirms they are converting the
  template into a project.
- **Report placeholders as unconfigured.** When a `make` target prints "not configured
  yet", say that under Verification and suggest setting up the repository.
- **Setup is its own task.** When asked to set up the repository, do step 4 of
  `docs/TEMPLATE_SETUP.md` in one pull request. Take the real commands from the project's
  own files, such as `package.json`, `pyproject.toml`, or `Package.swift`. In a monorepo,
  the targets cover every package. If there is no code yet to choose tools from, ask
  which language and tools to use.
- **Setup is done** when the Project section describes the project, the README
  placeholders are filled in, each `make` target runs the project's real tools or prints
  why it has nothing to do, and `make check` passes. `LICENSE`, `CODEOWNERS`, and
  `.gitignore` may stay unchanged if the pull request says why.
- **Leave steps 1 to 3 to a human.** They need GitHub admin access, a browser, and
  secrets. List them in the pull request.

## How to work

- **One task, one pull request.** Implement only what the issue asks. Leave anything listed
  under "Out of scope" alone, and do not refactor or reformat unrelated code.
- **Follow existing patterns.** Match the naming, structure, and style of nearby code
  before introducing anything new.
- **Test behavior changes.** Add or update tests for what you change.
- **Ask instead of guessing.** If a task is ambiguous, stop and explain what is missing
  rather than inventing requirements.
- **Never commit secrets,** credentials, or `.env` files.

## Pull requests

- The title is a conventional commit: `type(scope): summary`, where type is one of
  `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, or `revert`.
- Fill in every section of `.github/pull_request_template.md`. Under Verification, list
  the commands you ran and what they showed. "Tests pass" alone is not enough.
- Link the issue with `Closes #<number>`.
