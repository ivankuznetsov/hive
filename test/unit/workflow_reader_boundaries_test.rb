require "test_helper"
require "ripper"

class WorkflowReaderBoundariesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  UNION_READS = %w[
    all_stage_dirs all_active_stage_dirs all_stage_names all_terminal_stage_dirs
    resolve_stage_ref_across_workflows stage_ref_hint stages_for_project
  ].freeze

  # Exact, occurrence-level inventory. Each entry is mirrored in the audited
  # reader table in wiki/modules/workflows.md; counts are significant so a
  # duplicate in an already-listed file fails just like a new file does.
  ALLOWED = [
    { path: "lib/hive/cli.rb", line: 30, method: "<top-level>", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/approve.rb", line: 265, method: "validate_stage_refs!", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/approve.rb", line: 276, method: "validate_stage_refs_from_active_view!", call: "Hive::Workflows.stage_ref_hint", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/approve.rb", line: 279, method: "validate_stage_refs_from_active_view!", call: "Hive::Workflows.stage_ref_hint", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/approve.rb", line: 291, method: "known_stage_ref?", call: "Hive::Workflows.resolve_stage_ref_across_workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/drop.rb", line: 125, method: "resolve_path_context", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/drop.rb", line: 166, method: "resolve_slug_context", call: "Hive::Workflows.stages_for_project", classification: "project-operation-facade", reason: "Delegates project-specific stage resolution to the Project-owned operation." },
    { path: "lib/hive/commands/drop.rb", line: 204, method: "resolve_slug_context", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/drop.rb", line: 244, method: "raise_wrong_stage_if_slug_exists_elsewhere!", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/drop.rb", line: 245, method: "raise_wrong_stage_if_slug_exists_elsewhere!", call: "Hive::Workflows.all_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/drop.rb", line: 261, method: "raise_wrong_stage_if_slug_exists_elsewhere!", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/drop.rb", line: 263, method: "raise_wrong_stage_if_slug_exists_elsewhere!", call: "Hive::Workflows.resolve_stage_ref_across_workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/drop.rb", line: 561, method: "active_stage_dirs", call: "Hive::Workflows.all_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/drop.rb", line: 572, method: "archive_stage_dirs", call: "Hive::Workflows.all_terminal_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/init.rb", line: 774, method: "fieldless_in_flight_tasks", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/init.rb", line: 775, method: "fieldless_in_flight_tasks", call: "Hive::Workflows.all_terminal_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/commands/init.rb", line: 1388, method: "resolve_workflow_choice", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/init.rb", line: 1407, method: "resolve_workflow_choice", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/status.rb", line: 800, method: "prepare_project", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/status.rb", line: 1247, method: "render_project", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/status.rb", line: 1901, method: "capture_workflow_generations", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/commands/status.rb", line: 1925, method: "workflow_stage_dirs", call: "Hive::Workflows.all_stage_dirs", classification: "generation-or-compatibility", reason: "Production uses captured data; the live fallback is synchronized compatibility only." },
    { path: "lib/hive/commands/status.rb", line: 1929, method: "workflow_active_stage_dirs", call: "Hive::Workflows.all_active_stage_dirs", classification: "generation-or-compatibility", reason: "Production uses captured data; the live fallback is synchronized compatibility only." },
    { path: "lib/hive/commands/status.rb", line: 1933, method: "workflow_terminal_stage_dirs", call: "Hive::Workflows.all_terminal_stage_dirs", classification: "generation-or-compatibility", reason: "Production uses captured data; the live fallback is synchronized compatibility only." },
    { path: "lib/hive/commands/status.rb", line: 1937, method: "workflow_ids", call: "Hive::Workflows::Registry.ids", classification: "generation-or-compatibility", reason: "Production uses captured data; the live fallback is synchronized compatibility only." },
    { path: "lib/hive/commands/workflow.rb", line: 213, method: "validate_id!", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow.rb", line: 225, method: "unavailable_id?", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/list.rb", line: 33, method: "built_in_rows", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/remove.rb", line: 79, method: "ownership_error", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/validate.rb", line: 139, method: "resolve_read_only!", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/validate.rb", line: 148, method: "resolve_read_only!", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/validate.rb", line: 150, method: "resolve_read_only!", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/validate.rb", line: 177, method: "read_only_workflow_ids", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/commands/workflow/validate.rb", line: 190, method: "origin", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2154, method: "find_post_advance_state_file", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2155, method: "find_post_advance_state_file", call: "Hive::Workflows.all_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2161, method: "find_post_advance_state_file", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2162, method: "find_post_advance_state_file", call: "Hive::Workflows.all_stage_dirs", classification: "compatibility-current-view", reason: "Serialized or boot-time compatibility read; not a project-specific shortcut." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2983, method: "stage_rank", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 2984, method: "stage_rank", call: "Hive::Workflows.all_stage_dirs", classification: "generation-or-compatibility", reason: "Production uses captured data; the live fallback is synchronized compatibility only." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 3020, method: "workflow_stage_dirs_by_project", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 3021, method: "workflow_stage_dirs_by_project", call: "Hive::Workflows.all_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 3024, method: "workflow_stage_dirs_by_project", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/daemon/dispatcher.rb", line: 3025, method: "workflow_stage_dirs_by_project", call: "Hive::Workflows.all_stage_dirs", classification: "compatibility-current-view", reason: "Serialized or boot-time compatibility read; not a project-specific shortcut." },
    { path: "lib/hive/daemon/patrol_fix_runtime.rb", line: 85, method: "task_materializer", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/daemon/stale_agent_healer.rb", line: 333, method: "controller_workflow?", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/daily_digest/project_source.rb", line: 40, method: "initialize", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/daily_digest/project_source.rb", line: 41, method: "initialize", call: "registry.workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/dependency_snapshot.rb", line: 472, method: "dependency_tasks_for_reference", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/dependency_snapshot.rb", line: 599, method: "admission_tasks", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/dependency_snapshot.rb", line: 603, method: "active_stage_dirs_for", call: "Hive::Workflows.all_active_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/dependency_snapshot.rb", line: 607, method: "terminal_stage_dirs_for", call: "Hive::Workflows.all_terminal_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/dependency_snapshot.rb", line: 639, method: "admission_task", call: "Hive::Workflows::Registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/operational_status.rb", line: 32, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/patrol_fix/successor_materializer.rb", line: 118, method: "default_workflow_info", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/recovery/retry_policy.rb", line: 40, method: "resolve_descriptor", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/recovery/retry_policy.rb", line: 41, method: "resolve_descriptor", call: "registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/recovery/retry_policy.rb", line: 44, method: "resolve_descriptor", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/recovery/retry_policy.rb", line: 45, method: "resolve_descriptor", call: "Hive::Workflows::Registry.fetch", classification: "compatibility-current-view", reason: "Serialized or boot-time compatibility read; not a project-specific shortcut." },
    { path: "lib/hive/stages.rb", line: 16, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/stages.rb", line: 17, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/stages.rb", line: 18, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/stages/resolver.rb", line: 77, method: "resolve", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/task.rb", line: 38, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/task.rb", line: 39, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/task.rb", line: 67, method: "capture_workflow_generation", call: "Hive::Workflows::Registry.workflows", classification: "bounded-generation-copy", reason: "Copies the live registry into the existing generation inside caller-owned Project operation." },
    { path: "lib/hive/task.rb", line: 234, method: "resolve_workflow", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/task.rb", line: 235, method: "resolve_workflow", call: "registry.workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/task.rb", line: 348, method: "warn_if_unregistered_project_default", call: "Hive::Workflows::Registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/task_action.rb", line: 1197, method: "task_workflow", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/task_resolver.rb", line: 141, method: "find_slug_across_projects", call: "Hive::Workflows.stages_for_project", classification: "project-operation-facade", reason: "Delegates project-specific stage resolution to the Project-owned operation." },
    { path: "lib/hive/task_resolver.rb", line: 153, method: "find_id_across_projects", call: "Hive::Workflows.stages_for_project", classification: "project-operation-facade", reason: "Delegates project-specific stage resolution to the Project-owned operation." },
    { path: "lib/hive/workflow_selection.rb", line: 9, method: "fetch!", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/workflow_selection.rb", line: 20, method: "fetch!", call: "registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflow_selection.rb", line: 25, method: "fetch!", call: "registry.ids", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflow_selection.rb", line: 36, method: "valid_names", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/workflow_selection.rb", line: 37, method: "valid_names", call: "registry.ids", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflow_selection.rb", line: 43, method: "valid_names", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/workflow_selection.rb", line: 44, method: "valid_names", call: "Hive::Workflows::Registry.ids", classification: "compatibility-current-view", reason: "Serialized or boot-time compatibility read; not a project-specific shortcut." },
    { path: "lib/hive/workflows.rb", line: 48, method: "<top-level>", call: "Hive::Workflows::Registry.default", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "lib/hive/workflows.rb", line: 169, method: "all_stage_dirs", call: "Registry.all", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 173, method: "all_active_stage_dirs", call: "Registry.all", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 177, method: "all_stage_names", call: "Registry.all", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 186, method: "all_terminal_stage_dirs", call: "Registry.all", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 201, method: "stage_ref_hint", call: "all_stage_dirs", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 201, method: "stage_ref_hint", call: "all_stage_names", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 215, method: "resolve_stage_ref_across_workflows", call: "Registry.all", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 223, method: "resolve_stage_ref_across_workflows", call: "stage_ref_hint", classification: "union-internal", reason: "Internal union plumbing; project-dependent callers must hold Project operation ownership." },
    { path: "lib/hive/workflows.rb", line: 249, method: "stages_for_project", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/workflows.rb", line: 250, method: "stages_for_project", call: "all_stage_dirs", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflows.rb", line: 252, method: "stages_for_project", call: "resolve_stage_ref_across_workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflows.rb", line: 276, method: "assert_known_stage_filter!", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "lib/hive/workflows.rb", line: 277, method: "assert_known_stage_filter!", call: "stage_ref_hint", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflows.rb", line: 278, method: "assert_known_stage_filter!", call: "resolve_stage_ref_across_workflows", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "lib/hive/workflows.rb", line: 287, method: "assert_known_stage_filter!", call: "Hive::Workflows::Project.synchronize", classification: "compatibility-current-view", reason: "Legacy no-root or path-only branch is serialized but is not project-specific." },
    { path: "lib/hive/workflows.rb", line: 287, method: "assert_known_stage_filter!", call: "stage_ref_hint", classification: "compatibility-current-view", reason: "Serialized or boot-time compatibility read; not a project-specific shortcut." },
    { path: "lib/hive/workflows/project.rb", line: 181, method: "registered_stage_names", call: "Hive::Workflows::Registry.all", classification: "project-internal", reason: "Project owns this registry read while installing or validating the active view." },
    { path: "lib/hive/workflows/project.rb", line: 320, method: "assert_descriptor_loadable!", call: "Hive::Workflows::Registry.project_registrations", classification: "project-internal", reason: "Project owns this registry read while installing or validating the active view." },
    { path: "web/app/models/board.rb", line: 111, method: "workflows_for", call: "registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "web/app/models/board.rb", line: 119, method: "workflows_for", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "web/app/models/board.rb", line: 123, method: "workflows_for", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "web/app/models/init_setup.rb", line: 39, method: "workflows", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." },
    { path: "web/app/models/task.rb", line: 615, method: "workflow_descriptor", call: "Hive::Workflows::Project.with_active_workflows", classification: "project-operation", reason: "Activates the selected root and holds its registry view through the enclosing block." },
    { path: "web/app/models/task.rb", line: 616, method: "workflow_descriptor", call: "registry.fetch", classification: "operation-scoped-read", reason: "The enclosing production path reads this value inside the selected Project operation or from its bounded copy." },
    { path: "web/app/models/task.rb", line: 619, method: "workflow_descriptor", call: "Hive::Workflows::Registry::WORKFLOWS", classification: "built-in-only", reason: "Reads the frozen built-in descriptor set and cannot observe a project overlay." }
  ].freeze

  def test_every_live_workflow_reader_has_an_exact_classification
    actual = workflow_reader_occurrences
    expected_keys = ALLOWED.map { |entry| occurrence_key(entry) }
    actual_keys = actual.map { |entry| occurrence_key(entry) }

    assert_equal expected_keys.tally, actual_keys.tally,
                 "workflow reader inventory drifted:\n#{actual.map(&:inspect).join("\n")}"
  end

  def test_wiki_reader_table_matches_the_executable_allowlist
    assert_equal ALLOWED, wiki_reader_entries
  end

  def test_new_reader_in_an_unlisted_file_is_rejected
    actual = reader_occurrences_for(
      "lib/hive/unlisted_reader.rb",
      "def leaked\n  Hive::Workflows::Registry.ids\nend\n"
    )

    refute inventory_matches?([], actual)
  end

  def test_duplicate_reader_in_an_already_listed_file_is_rejected
    actual = reader_occurrences_for(
      "lib/hive/duplicate_reader.rb",
      "def duplicate\n  Hive::Workflows::Registry.ids; Hive::Workflows::Registry.ids\nend\n"
    )

    refute inventory_matches?([ actual.first ], actual)
  end

  def test_comments_and_string_literals_are_not_readers
    actual = reader_occurrences_for(
      "lib/hive/comment_only.rb",
      "# Hive::Workflows::Registry.ids\nTEXT = 'Hive::Workflows.all_stage_dirs'\n"
    )

    assert_empty actual
  end

  private

  def workflow_reader_occurrences
    Dir[File.join(ROOT, "{lib,web/app}", "**", "*.rb")].sort.flat_map do |absolute_path|
      path = absolute_path.delete_prefix("#{ROOT}/")
      reader_occurrences_for(path, File.read(absolute_path))
    end
  end

  def reader_occurrences_for(path, source)
    lines = code_lines(source)
    original_lines = source.lines
    workflow_aliases = source.include?("Hive::Workflows::Project.with_active_workflows")
    ranges = method_ranges(source)

    lines.each_with_index.flat_map do |line, index|
        next [] if line.strip.empty?

        calls = []
        calls.concat(line.scan(/Hive::Workflows::Project\.(?:with_active_workflows|synchronize|load!)/))
        calls.concat(line.scan(/Hive::Workflows::Registry(?:::WORKFLOWS|\.(?:all|ids|fetch|workflows|default|project_registrations))/))
        if workflow_aliases
          calls.concat(line.scan(/\bregistry\.(?:all|ids|fetch|workflows|default|project_registrations)\b/))
        end
        if path == "lib/hive/workflows.rb" || path.start_with?("lib/hive/workflows/")
          calls.concat(line.scan(/(?<!Workflows::)\bRegistry\.(?:all|ids|fetch|workflows|default|project_registrations)\b/))
        end
        calls.concat(line.scan(/Hive::Workflows\.(?:#{UNION_READS.join('|')})\b/))
        if path == "lib/hive/workflows.rb" && !line.match?(/^\s*def\s+(?:#{UNION_READS.join('|')})\b/)
          calls.concat(line.scan(/(?<![@.:\w])(?:#{UNION_READS.join('|')})\b/))
        end

        calls.map do |call|
          {
            path: path,
            line: index + 1,
            method: enclosing_method(ranges, index + 1),
            call: call,
            source: original_lines.fetch(index).strip.gsub(/\s+/, " ")
          }
        end
    end
  end

  def code_lines(source)
    lines = Array.new(source.lines.length) { +"" }
    Ripper.lex(source).each do |(line_no, _column), type, token, _state|
      next if %i[on_comment on_tstring_content on_heredoc_beg on_heredoc_end].include?(type)

      token.split("\n", -1).each_with_index do |part, offset|
        next if part.empty?

        lines.fetch(line_no - 1 + offset) << part
      end
    end
    lines
  end

  def occurrence_key(entry)
    entry.values_at(:path, :line, :method, :call)
  end

  def inventory_matches?(expected, actual)
    expected.map { |entry| occurrence_key(entry) }.tally ==
      actual.map { |entry| occurrence_key(entry) }.tally
  end

  def wiki_reader_entries
    body = File.read(File.join(ROOT, "wiki/modules/workflows.md"))
    match = body.match(/<!-- workflow-reader-inventory:start -->(.*?)<!-- workflow-reader-inventory:end -->/m)
    raise "workflow reader inventory is missing from wiki/modules/workflows.md" unless match

    table = match[1]
    table.lines.grep(/^\| `/).map do |line|
      location, method, call, classification, reason = line.split("|").drop(1).first(5).map(&:strip)
      path, line_number = location.delete("`").split(":", 2)
      {
        path: path,
        line: Integer(line_number, 10),
        method: method.delete("`"),
        call: call.delete("`"),
        classification: classification.delete("`"),
        reason: reason
      }
    end
  end

  def method_ranges(source)
    ranges = []
    walk = lambda do |value|
      if value.is_a?(RubyVM::AbstractSyntaxTree::Node)
        if %i[DEFN DEFS].include?(value.type)
          name = value.children.find { |child| child.is_a?(Symbol) }
          ranges << [ value.first_lineno, value.last_lineno, name.to_s ] if name
        end
        value.children.each { |child| walk.call(child) }
      elsif value.is_a?(Array)
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(RubyVM::AbstractSyntaxTree.parse(source))
    ranges
  end

  def enclosing_method(ranges, line)
    match = ranges.select { |first, last, _name| line.between?(first, last) }
                  .min_by { |first, last, _name| last - first }
    match ? match.fetch(2) : "<top-level>"
  end
end
