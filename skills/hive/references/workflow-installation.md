# Install workflows from private Git repositories

## Availability and access

Direct Git import is unreleased. Before suggesting the command, inspect
`hive workflow --help` for `--from` and `--ref`. A source branch containing the
importer does not make it available in the user's installed Hive. If these
options are absent, explain that this build cannot perform direct Git imports;
do not claim a normal update already provides them.

The user needs read access to the repository and working Git authentication.
For GitHub HTTPS, the operator can use `gh auth login` and `gh auth setup-git`.
SSH uses their configured SSH identity. Never ask for a token in chat or put
credentials in a repository URL, task artifact or command example.

## Import into an initialized project

Use the requested project directory. The repository must contain
`workflows/ID.yml` and its stage instructions/assets under `workflows/ID/`.
The descriptor ID must match ID. Use the user's actual repository and workflow
ID in place of these examples:

```sh
hive workflow install weekly-news --from https://github.com/OWNER/PRIVATE-REPO.git
hive workflow validate weekly-news --json
```

A direct request to install the specified source authorizes the import; do not
add a second confirmation merely because the repository is private. An optional
read-only preview is available when the user wants to inspect the exact files
and commit before importing:

```sh
hive workflow install weekly-news --from https://github.com/OWNER/PRIVATE-REPO.git --dry-run --json
hive workflow install weekly-news --from https://github.com/OWNER/PRIVATE-REPO.git --ref FULL_COMMIT
```

Use the preview's `source_commit` as FULL_COMMIT for an exact-revision install.
An SSH source such as `git@github.com:OWNER/PRIVATE-REPO.git` also works. HEAD,
branch and tag requests resolve to a recorded commit. The command imports an
editable authored workflow and commits its files to Hive project state. The
`hive-source.json` receipt in the workflow directory records repository, ref,
commit and file hashes. Existing workflow IDs are never overwritten. Preserve
local edits and report a collision rather than deleting the existing workflow.

## Installation is not runtime setup

Inspect the source's README and instructions for machine-specific paths,
helper binaries/packages, catalogue or API access, model availability and state
initialization. Report missing prerequisites precisely. The importer does not
install dependencies, initialize research databases, execute source hooks,
configure credentials, create schedules, or start tasks. A successful import and
graph validation prove the files are installed, not that the workflow can run.

Direct Git imports use authored-project permissions. They are not
catalogue-reviewed Honeycomb packages. Managed `workflow update` and `remove`
do not manage these imports; subsequent owner edits use `hive workflow commit ID`.
Do not imply automatic upstream synchronization or runtime portability.
