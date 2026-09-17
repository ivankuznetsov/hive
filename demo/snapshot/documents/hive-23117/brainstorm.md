## Round 1
### Q1. Should the first release create only new workflows, or must natural-language requests also support modifying an existing custom workflow? The proposed v1 boundary is create-only: inspect existing workflows for conventions and collisions, but never overwrite or edit one.
### A1.

The first release is create-only. It may inspect existing workflows for local
conventions and ID collisions, but must never overwrite or partially edit one.
On an ID collision, stop and propose a new ID. Treat modification of existing
workflows as a separate future capability requiring a diff preview and a
rollback design.

### Q2. When a request omits implementation details, should the creator default to inheriting the project's agent/model settings, granting only stage-required permissions, using automatic sequential transitions, and adding a human checkpoint only when the requested intent implies one?
### A2.

Inherit the project and Hive agent/model settings, use automatic sequential
transitions, and add a human checkpoint only when the user requested one or
immediately before a genuinely irreversible or high-consequence action. For
ordinary locally owned agent stages, preserve Hive's established single-user
trust model and default to `yolo`; do not reintroduce a least-privilege
permission ceremony. Do not infer specialized models, branching, or extra
approval gates without a material need. List every applied default in the
completion summary.

### Q3. For an uninitialized target directory, may the skill initialize Hive in place with the authoritative `hive init --new-workflow` path and inferred neutral defaults, asking only if initialization would alter an existing non-Hive project choice that has no safe default?
### A3.

Require one explicit confirmation before running `hive init --new-workflow` in
an uninitialized directory. The preview must identify the target and disclose
the project-level files, state worktree, hooks or timers, global registration,
and background automation it may create. After approval, use neutral minimal
defaults plus the requested workflow without further questions about harmless
inferences. Do not choose a starter template automatically or use `--force` on
a dirty or existing project without separate authorization.

### Q4. In the editorial acceptance example, should “three-stage” mean `research -> draft -> publish`, with a blocking human approval checkpoint before the transition into `publish`, and should the end-to-end test assert that exact interpretation?
### A4.

No. Interpret the requested three-stage workflow as `research -> draft ->
approval`. Approval is an explicit durable human stage, not a hidden checkpoint
before an automatic publish action. Approval records a publish-ready artifact
and completes the workflow; rejection returns the task to `draft`. Add an
external publishing stage only when the user separately specifies its
destination and authorization. The end-to-end test must assert these exact
three stages and both approval outcomes.

### Q5. Is current-main Hive/OpenClaw compatibility sufficient for v1, or must the packaged skill also work with older released Hive descriptor/schema versions? The proposed boundary is current main plus the repository's normal supported compatibility surface.
### A5.

Target current `main` plus the repository's normal supported compatibility
matrix. Generate only the authoritative current descriptor/schema through the
Hive CLI; do not add v1-specific adapters for older schema versions. Detect an
installed Hive version that is too old before mutation and return the exact
minimum version and upgrade instruction. Once released, public documentation
must describe the latest stable behavior rather than unreleased `main` behavior.

### Q6. Should successful creation stop after validation and report the exact next task command, or may it immediately create/run the first task when the user's original request explicitly asks for that? The proposed default is no task side effect unless explicitly requested.
### A6.

By default, stop after creating and validating the workflow and report the exact
`hive new ... --workflow <id>` command. If the original request explicitly asks
to create or run the first task, the creator may do so automatically after the
workflow loads successfully and any required `hive init` confirmation has been
granted. Retries must not create duplicate tasks. When a task is created,
return its slug, current stage, daemon status, and expected next transition.

## Requirements

- **Actor:** A Hive/OpenClaw user describes a new project-local workflow in ordinary language and expects the agent to create, validate, and clearly report it without requiring knowledge of Hive's descriptor format.
- **Capability boundary:** The first release creates new workflows only. It may inspect project configuration, built-in templates, and existing custom workflows for conventions and ID collisions, but it must never overwrite or partially edit an existing workflow. Existing-workflow modification is future work requiring a diff preview and rollback design.
- **Packaging and discovery:** Expose the capability as a dedicated triggerable `hive-workflow-creator` AgentSkill when the current OpenClaw package supports multiple skills; otherwise expose an equivalently named, focused capability through the bundled Hive skill. Installation and packaging must make it discoverable to OpenClaw users rather than leaving an unreferenced skill file.
- **Initialized-project flow:** Inspect the target project, infer a valid non-reserved workflow ID, ordered stages, outcomes and artifacts, reusable skills or instructions, agent/model assignments, transitions, permissions, and checkpoints. Reuse a built-in template only when it genuinely matches the request; otherwise create a neutral custom workflow rather than forcing it into coding, research, or writing.
- **Fresh-project flow:** Before `hive init --new-workflow`, show one explicit confirmation naming the target and disclosing the project files, state worktree, hooks or timers, global registration, and background automation initialization may create. After approval, use neutral minimal defaults and create the requested workflow without further questions for harmless inferences. Never choose a starter template automatically or use `--force` on a dirty or existing project without separate authorization.
- **Authoritative creation path:** Use `hive workflow new` or `hive init --new-workflow` to scaffold the current supported descriptor and stage instruction files, then fill those generated files. Preserve existing project configuration and workflows; do not invent a parallel format.
- **Inference defaults:** Inherit the project's Hive agent/model settings, use automatic sequential transitions, and add a human checkpoint only when explicitly requested or immediately before a genuinely irreversible or high-consequence action. Do not infer specialized models, branching, or extra approval gates without material need.
- **Permission default:** Preserve Hive's established single-user trust model and use `yolo` for ordinary locally owned agent stages rather than adding a new least-privilege permission ceremony. External or high-consequence actions still require the destination and necessary authorization to be explicit.
- **Questions:** Ask only when alternatives would materially change behavior and cannot be inferred safely. List every default applied in the completion summary.
- **Safety and compatibility:** Reject reserved or colliding IDs before mutation. On collision, stop and propose a new ID. Detect an installed Hive version that is too old before mutation and report the exact minimum version and upgrade instruction. Target current `main` plus the repository's normal compatibility matrix, with no adapters for older descriptors; released public docs describe latest-stable behavior.
- **Validation:** Validate YAML and frontmatter, load the workflow through Hive, and verify its stages and transitions before reporting success. Focused contract, package/install, YAML, and end-to-end tests must cover the natural-language creation path; the full suite, coverage, lint, and skill validation must pass.
- **Completion behavior:** By default, stop after successful validation and report exactly which files and defaults were created plus the exact `hive new ... --workflow <id>` command. Only create or run the first task when the original request explicitly asks; retries must not create duplicates. When created, report the task slug, current stage, daemon status, and expected next transition.
- **Documentation:** Add a complete worked example and concise schema, stage-design, checkpoint, permission, testing, and common-mistake references. Update the bundled OpenClaw skill docs and `docs/workflows.md` so the natural-language and manual CLI paths are both discoverable. Coordinate public wording with hive-site task #23116 without making that website work a blocker.
- **Acceptance example - editorial happy path:** “Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing” creates and loads `research -> draft -> approval`. Approval is a durable human stage that records a publish-ready artifact and completes the workflow; it does not publish externally.
- **Acceptance example - editorial rejection:** Rejecting the approval returns the task to `draft`; the end-to-end fixture proves both approval outcomes and expected routing. An external publishing stage appears only when the user separately supplies its destination and authorization.
- **Acceptance example - collision:** A request whose inferred ID already exists makes no workflow changes, explains the collision, and proposes an available ID.
- **Acceptance example - fresh project:** An uninitialized directory remains unchanged until the user approves the disclosed initialization preview, after which the workflow is scaffolded and loadable without unrelated project choices being overwritten.
- **Acceptance example - task side effects:** A creation-only request produces no task. An explicit create/run request creates at most one task after successful load validation and returns its operational status and next transition.

<!-- COMPLETE -->
