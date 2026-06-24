## 2026-06-23 - Workflow option help advertises project-authored workflows

- Updated the Thor `--workflow` help for `hive init` and `hive new` to list the
  built-in workflow names and explicitly state that project-authored workflows
  are also valid.
- Both commands share the same `Hive::CLI.workflow_option_desc` helper, leaving
  one future seam for any dynamic, project-aware help rendering.
