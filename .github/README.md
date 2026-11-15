# GitHub automation

## Documentation publishing

[The documentation workflow](./workflows/docs.yml) generates Vimdoc after CI
succeeds for a push to the default branch. Its publish job uses a dedicated GitHub
App to push changed help files; the workflow's built-in `GITHUB_TOKEN` has read
access. [The publisher](../scripts/publish-docs) skips artifacts if the default
branch has advanced beyond the validated commit.

### App configuration

1. Register a private GitHub App with **Contents: Read and write**. Disable
   webhooks; the existing workflow runs the publisher.
2. Install the App on **only this repository**.
3. Add the App's client ID as the repository Actions variable
   `DOCS_APP_CLIENT_ID`.
4. Generate an App private key and store the complete PEM file as the repository
   Actions secret `DOCS_APP_PRIVATE_KEY`.

The token action requests only Contents write access for the current repository
and revokes its token when the job finishes. See GitHub's
[App authentication guide](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow).

### Branch rules

Use two active branch rulesets targeting `master`:

- Require a pull request, with zero required approvals. Give only the publishing
  App **Always allow** bypass access; do not add an administrator bypass.
- Block force pushes and deletions, with no bypass actors.

Keep these rules separate because bypass applies to an entire ruleset. Retire the
overlapping classic branch protection only after the replacement rulesets are
active; otherwise its PR requirement will still block the App. See GitHub's
[ruleset configuration guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).
