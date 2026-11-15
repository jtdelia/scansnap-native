# After creating a repository from this template

GitHub copies the files from a template, but not its labels, branch rules, secrets, or
settings. Do these steps once per new repository.

## 1. Run the setup script

```sh
scripts/setup-repo.sh
```

It creates the labels, sets squash-only merging, and makes the Actions token read-only by
default. It protects `main` so that pull requests need one approval and the `ci-success`
check, and only admins can create or change tags. It also walks you through the agent app
(step 2) and offers to store a Kiro API key (step 3).

Rulesets on private repositories need GitHub Pro, Team, or Enterprise. On the Free plan the
script warns and skips those steps. Everything else still works.

## 2. Create the agent GitHub app

`/oc` comments and `agent-ready` tasks push branches and open pull requests as a GitHub app
you own, which lets CI run on their pull requests. The AI review works without it. The
setup script does this step for you; to do it by hand:

1. [Register a GitHub App](https://github.com/settings/apps/new?name=my-agent&public=false&webhook_active=false&contents=write&issues=write&pull_requests=write)
   (for an organization, use its **Settings > Developer settings > GitHub Apps**). Make it
   private, turn off the webhook, and give it only **Contents**, **Issues**, and **Pull
   requests**, each read and write. The link pre-fills these.
2. On the app's page, generate a private key.
3. Store the app's credentials in the repository:

   ```sh
   gh variable set AGENT_APP_CLIENT_ID --body <client ID from the app's page>
   gh secret set AGENT_APP_PRIVATE_KEY < path/to/key.pem
   ```

4. Install the app, choosing **Only select repositories**.
5. Run the **Setup check** workflow from the Actions tab. It fails if the app is not
   installed, the credentials are wrong, or the app has more permissions than these three.

One app can serve every repository made from this template: repeat steps 3 to 5 for each.

Each run creates a token for this repository only, limited to those three permissions, and
revokes it when the job ends. The app cannot change workflows, secrets, or settings. Where
the rulesets from step 1 apply, it cannot create tags either, and pull requests it opens
need your approval to merge. Within a run, the agent may edit
files but can only run `make` targets and read-only git commands. Because it can edit the
`Makefile`, treat that as a guard against mistakes, not a hard boundary.

If an earlier version of this template had you install the
[opencode-agent](https://github.com/apps/opencode-agent) app, uninstall it from
[your installations](https://github.com/settings/installations). It can write workflows and
secrets on every repository it is installed on.

No AI model key is needed. The workflows choose a free OpenCode model on every run, and run
a pinned OpenCode 2 release whose checksum is verified. To upgrade OpenCode, change `VERSION`
and `SHA256` in `.github/actions/run-opencode/action.yml`; the comment there shows how to get
the digest. Each workflow limits the agent's tools with the
[permission rules](https://opencode.ai/v2/docs/permissions/) in its `OPENCODE_CONFIG_CONTENT`.

## 3. Optional: Kiro CLI fallback

If no free OpenCode model works, the AI review falls back to Kiro CLI using GPT 5.6 Luna.
That needs a `KIRO_API_KEY` repository secret, which requires a paid Kiro plan (Pro or
higher). Without the secret, the review is skipped with a warning when no free model is
available. To use a different model, change `KIRO_MODEL` in `opencode-review.yml`; run
`kiro-cli chat --list-models` to see the options.

```sh
gh secret set KIRO_API_KEY
```

## 4. Fill in the project specifics

An agent can do this step. Ask it to set up the repository, and it follows the Template
setup section of `AGENTS.md`.

- `Makefile`: replace the `lint`, `test`, and `build` placeholders with real commands.
  CI runs these targets, so no workflow changes are needed.
- `README.md`: replace the placeholders. Remove the template note once steps 1 to 3 are
  done.
- `AGENTS.md`: describe the project in the Project section.
- `LICENSE`: change it if this project needs something other than MIT.
- `.github/CODEOWNERS`: add other reviewers if needed.
- `.gitignore`: add entries for the project's language.

## How the automation works

| Workflow | Runs when | What it does |
| --- | --- | --- |
| `ci.yml` | Every pull request, and pushes to `main` | `make lint`, `make test`, `make build`, plus workflow linting, secret scanning, spelling, and EditorConfig checks. `ci-success` passes only if all of them do. |
| `pr-title.yml` | A pull request opens or its title changes | Checks the title is a conventional commit. |
| `opencode-review.yml` | A pull request opens ready for review, or a draft is marked ready | Reviews the change with a free OpenCode model, falling back to Kiro CLI. |
| `opencode.yml` | A maintainer comments `/oc <request>` | Answers the question or makes the change. |
| `agent-task.yml` | A build task gets the `agent-ready` label | Implements the task and opens a draft pull request. Skips the task if any issue under "Blocked by" is still open. |
| `setup-check.yml` | The setup script, or you, starts it | Fails unless the agent app is installed and limited to the permissions it needs. |

### Free model selection

Before each run, `.github/actions/pick-free-model` lists the models OpenCode offers for
free right now and picks the best one. If that model fails, the workflow retries once with
the next one. Edit `.github/opencode/models.json` to change the preferred order or exclude
models.

In private repositories, only models whose provider says it does not train on your data
qualify. The picker reads this from the OpenCode docs on every run, so if the docs change
or a model is undocumented, that model is skipped rather than risked.

### Agent workflow for build tasks

1. Write a **Plan** issue, then one **Build task** issue per step. Add each task as a
   sub-issue of the plan.
2. Add `agent-ready` to a task whose blockers are closed.
3. The agent opens a draft pull request titled from the task, with `Closes #<task>`.
4. Check CI and the diff, then mark it **Ready for review**. That starts the AI review.
5. Ask for changes with `/oc <request>` comments, or edit the branch yourself.
6. Approve the pull request and merge it. New pushes dismiss an earlier approval.
