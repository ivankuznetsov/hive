## hive workflow new --template (sample workflow seeds)

`hive workflow new ID` previously always scaffolded the bare `blank`
inbox->work->done stub with a placeholder `work.md`. Generalized the scaffolder
to named templates: a template is a directory under `templates/workflows/`
carrying `descriptor.yml.erb` plus one `.md` instruction per agent stage. The
new `--template NAME` flag seeds from a sample instead of the stub — the
descriptor is rendered with the user's ID and every stage instruction is copied
verbatim (real content, not "Edit this file").

Shipped two samples: `writing` (inbox->research->draft->edit->done) and
`research` (inbox->gather->synthesize->report->done). Unknown templates are a
USAGE error listing the available names (also in the `--json` `expected`
array). The blank default, `hive init --new-workflow` (which shares the
scaffolder), and the `hive-workflow-new` JSON schema (single `instruction_path`
= the first stage's instruction) are unchanged. Multi-stage templates print
`edit: <id>/ (N stage instructions to fill in)` pointing at the directory.

Refreshed [[commands/workflow]].
