require "test_helper"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/stack"
require "hive/dependency_snapshot"
require "hive/task_meta"

# `hive stack` changes an existing task's dependency at any unfinished stage.
# These scenarios drive the real command against an initialised project and
# its hive/state branch, then read the result back through the same admission
# context status and the daemon use.
class StackTest < Minitest::Test
  include HiveTestHelper

  def test_stacks_an_existing_task_commits_and_admission_sees_the_wait
    with_project do |dir, project|
      create_task(project, "base-task")
      dependent = create_task(project, "dependent-task")

      payload = stack("dependent-task", on: [ "base-task" ])

      assert_equal "base-task", Hive::TaskMeta.read(dependent)[:depends_on]
      assert_equal true, payload.fetch("changed")
      assert_equal true, payload.fetch("committed")
      assert_nil payload.fetch("previous_depends_on")
      assert_equal "wait", payload.dig("dependency", "state")
      assert_equal [ { "reference" => "base-task", "blocked_by" => "base-task",
                       "dependency_stage" => "1-inbox", "required_gate" => "8-finalize" } ],
                   payload.dig("dependency", "unmet_dependencies")
      assert_equal "hive: 1-inbox/dependent-task stacked on base-task", last_commit_subject(dir)

      verdict = admission_verdict(dir, project, "dependent-task")
      assert verdict.wait?
      assert_equal "base-task", verdict.blocked_by
    end
  end

  def test_restack_replaces_an_existing_dependency_and_clear_removes_it
    with_project do |dir, project|
      create_task(project, "first-base")
      create_task(project, "second-base")
      dependent = create_task(project, "dependent-task", depends_on: "first-base")

      payload = stack("dependent-task", on: [ "second-base" ])
      assert_equal "second-base", Hive::TaskMeta.read(dependent)[:depends_on]
      assert_equal "first-base", payload.fetch("previous_depends_on")

      cleared = stack("dependent-task", clear: true)
      assert_nil Hive::TaskMeta.read(dependent)[:depends_on]
      refute_includes File.read(File.join(dependent, "meta.yml")), "depends_on"
      assert_equal "clear", cleared.dig("dependency", "state")
      assert_equal "hive: 1-inbox/dependent-task unstacked", last_commit_subject(dir)
      assert admission_verdict(dir, project, "dependent-task").clear?
    end
  end

  def test_repeated_on_writes_a_scheduling_only_list_and_says_so
    with_project do |_dir, project|
      create_task(project, "api-task")
      create_task(project, "ui-task")
      dependent = create_task(project, "release-task")

      payload, err = stack_with_io("release-task", on: %w[api-task ui-task])

      assert_equal %w[api-task ui-task], Hive::TaskMeta.read(dependent)[:depends_on]
      assert_equal %w[9-done 9-done],
                   payload.dig("dependency", "unmet_dependencies").map { |unmet| unmet["required_gate"] }
      assert_includes err, "scheduling-only"
    end
  end

  def test_same_declaration_is_a_no_op_without_a_commit
    with_project do |dir, project|
      create_task(project, "base-task")
      create_task(project, "dependent-task", depends_on: "base-task")
      before = last_commit_subject(dir)

      payload = stack("dependent-task", on: [ "base-task" ])

      assert_equal false, payload.fetch("changed")
      assert_equal false, payload.fetch("committed")
      assert_equal before, last_commit_subject(dir)
    end
  end

  def test_restacks_a_task_past_execute_and_warns_that_the_branch_is_not_rebased
    with_project do |dir, project|
      create_task(project, "base-task")
      inbox = create_task(project, "dependent-task")
      executing = move_task(dir, inbox, "4-execute")
      File.write(File.join(executing, "worktree.yml"),
                 { "path" => "/tmp/nowhere", "base_branch" => "main", "base_ref" => "refs/heads/main" }.to_yaml)

      payload, err = stack_with_io("dependent-task", on: [ "base-task" ])

      assert_equal "4-execute", payload.fetch("stage")
      assert_equal "base-task", Hive::TaskMeta.read(executing)[:depends_on]
      assert_includes err, "already has a worktree branched from refs/heads/main"
      assert_includes err, "does not rebase it"
      assert_equal "hive: 4-execute/dependent-task stacked on base-task", last_commit_subject(dir)
    end
  end

  def test_missing_prerequisite_is_written_and_reported_as_an_admission_hold
    with_project do |_dir, project|
      dependent = create_task(project, "dependent-task")

      payload, err = stack_with_io("dependent-task", on: [ "ghost-task" ])

      assert_equal "ghost-task", Hive::TaskMeta.read(dependent)[:depends_on]
      assert_equal "admission_error", payload.dig("dependency", "state")
      assert_equal "dependency_task_missing", payload.dig("dependency", "admission_error", "reason_code")
      assert_includes err, "held until this resolves: dependency_task_missing"
    end
  end

  def test_refuses_an_edge_that_closes_a_cycle_and_leaves_metadata_untouched
    with_project do |dir, project|
      upstream = create_task(project, "upstream-task")
      create_task(project, "downstream-task", depends_on: "upstream-task")
      before = last_commit_subject(dir)

      error = assert_raises(Hive::Commands::Stack::Refusal) do
        stack("upstream-task", on: [ "downstream-task" ])
      end

      assert_equal "dependency_cycle", error.error_kind
      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_includes error.message,
                      "#{project}:upstream-task -> #{project}:downstream-task -> #{project}:upstream-task"
      assert_nil Hive::TaskMeta.read(upstream)[:depends_on]
      assert_equal before, last_commit_subject(dir)
    end
  end

  def test_refuses_a_self_reference
    with_project do |_dir, project|
      create_task(project, "lonely-task")

      error = assert_raises(Hive::Commands::Stack::Refusal) { stack("lonely-task", on: [ "lonely-task" ]) }

      assert_equal "dependency_cycle", error.error_kind
    end
  end

  def test_plan_frontmatter_must_agree_and_matching_it_repairs_a_mismatch
    with_project do |dir, project|
      create_task(project, "planned-base")
      create_task(project, "other-base")
      dependent = create_task(project, "dependent-task", depends_on: "other-base")
      File.write(File.join(dependent, "plan.md"), "---\ndepends_on: planned-base\n---\n# Plan\n")
      assert_equal "plan_dependency_mismatch",
                   admission_verdict(dir, project, "dependent-task").admission_error.reason_code

      error = assert_raises(Hive::DependencyAdmissionError) do
        stack("dependent-task", on: [ "another-base" ])
      end
      assert_equal "plan_dependency_mismatch", error.reason_code
      assert_equal "planned-base", error.offending_ref
      assert_includes error.safe_correction, File.join(dependent, "plan.md")
      assert_equal "other-base", Hive::TaskMeta.read(dependent)[:depends_on]

      clear_error = assert_raises(Hive::DependencyAdmissionError) { stack("dependent-task", clear: true) }
      assert_equal "plan_dependency_missing", clear_error.reason_code

      stack("dependent-task", on: [ "planned-base" ])
      assert_equal "planned-base", Hive::TaskMeta.read(dependent)[:depends_on]
      assert admission_verdict(dir, project, "dependent-task").wait?
    end
  end

  def test_refuses_a_task_in_its_terminal_stage
    with_project do |dir, project|
      create_task(project, "base-task")
      done = move_task(dir, create_task(project, "finished-task"), "9-done")

      error = assert_raises(Hive::WrongStage) { stack("finished-task", on: [ "base-task" ]) }

      assert_equal "9-done", error.current_stage
      assert_nil Hive::TaskMeta.read(done)[:depends_on]
    end
  end

  def test_usage_and_grammar_refusals
    with_project do |_dir, project|
      create_task(project, "some-task")

      neither = assert_raises(Hive::Commands::Stack::Refusal) { stack("some-task") }
      assert_equal "usage", neither.error_kind
      both = assert_raises(Hive::Commands::Stack::Refusal) do
        stack("some-task", on: [ "x-task" ], clear: true)
      end
      assert_equal "usage", both.error_kind
      invalid = assert_raises(Hive::Commands::Stack::Refusal) { stack("some-task", on: [ "Not A Slug" ]) }
      assert_equal "invalid_dependency", invalid.error_kind
      cross_numeric = assert_raises(Hive::Commands::Stack::Refusal) { stack("some-task", on: [ "#{project}:42" ]) }
      assert_equal "invalid_dependency", cross_numeric.error_kind
    end
  end

  def test_a_live_task_lease_refuses_with_a_retryable_error
    with_project do |_dir, project|
      create_task(project, "base-task")
      dependent = create_task(project, "dependent-task")
      publish_test_task_lease(dependent, "op" => "execute")

      error = assert_raises(Hive::ConcurrentRunError) { stack("dependent-task", on: [ "base-task" ]) }

      assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      assert_nil Hive::TaskMeta.read(dependent)[:depends_on]
    end
  end

  def test_a_failed_hive_state_commit_restores_the_previous_metadata
    with_project do |_dir, project|
      create_task(project, "base-task")
      dependent = create_task(project, "dependent-task")
      before = File.binread(File.join(dependent, "meta.yml"))

      failing_ops = Object.new
      failing_ops.define_singleton_method(:hive_commit) { |**| raise Hive::GitError, "simulated commit failure" }
      with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { failing_ops }) do
        assert_raises(Hive::GitError) { stack("dependent-task", on: [ "base-task" ]) }
      end

      assert_equal before, File.binread(File.join(dependent, "meta.yml"))
    end
  end

  def test_json_success_and_error_documents_match_the_schema
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-stack"))))
    with_project do |_dir, project|
      create_task(project, "base-task")
      create_task(project, "dependent-task")

      out, = capture_io do
        Hive::Commands::Stack.new("dependent-task", on: [ "base-task" ], json: true).call
      end
      success = JSON.parse(out)
      assert schemer.valid?(success), schemer.validate(success).map { |e| e["error"] }.inspect
      assert_equal "hive-stack", success.fetch("schema")

      out, = capture_io do
        assert_raises(Hive::Commands::Stack::Refusal) do
          Hive::Commands::Stack.new("dependent-task", on: [ "dependent-task" ], json: true).call
        end
      end
      failure = JSON.parse(out)
      assert schemer.valid?(failure), schemer.validate(failure).map { |e| e["error"] }.inspect
      assert_equal "dependency_cycle", failure.fetch("error_kind")
      assert_equal 64, failure.fetch("exit_code")
    end
  end

  def test_prerequisite_at_its_gate_is_clear_and_clearing_nothing_is_a_no_op
    with_project do |dir, project|
      move_task(dir, create_task(project, "landed-task"), "8-finalize")
      create_task(project, "follow-up-task")

      clear_noop = stack("follow-up-task", clear: true)
      assert_equal false, clear_noop.fetch("changed")

      out, = capture_io { Hive::Commands::Stack.new("follow-up-task", on: [ "landed-task" ]).call }
      assert_includes out, "not blocked: every prerequisite has reached its gate"
      out, = capture_io { Hive::Commands::Stack.new("follow-up-task", clear: true).call }
      assert_includes out, "no longer depends on another task"
      out, = capture_io { Hive::Commands::Stack.new("follow-up-task", clear: true).call }
      assert_includes out, "has no dependency; nothing changed"
    end
  end

  def test_explicit_project_reference_is_noted_as_scheduling_only
    with_project do |_dir, project|
      create_task(project, "base-task")
      dependent = create_task(project, "dependent-task")

      _payload, err = stack_with_io("dependent-task", on: [ "#{project}:base-task" ])

      assert_equal "#{project}:base-task", Hive::TaskMeta.read(dependent)[:depends_on]
      assert_includes err, "explicit project:slug prerequisite gates scheduling only"
    end
  end

  def test_unreadable_worktree_pointer_still_produces_the_not_rebased_note
    with_project do |dir, project|
      create_task(project, "base-task")
      create_task(project, "other-base")
      executing = move_task(dir, create_task(project, "dependent-task"), "4-execute")

      File.write(File.join(executing, "worktree.yml"), "just a string\n")
      _payload, err = stack_with_io("dependent-task", on: [ "base-task" ])
      assert_includes err, "already has a worktree branched from its recorded base"

      File.write(File.join(executing, "worktree.yml"), "path: [unterminated\n")
      _payload, err = stack_with_io("dependent-task", on: [ "other-base" ])
      assert_includes err, "already has a worktree branched from its recorded base"
    end
  end

  def test_refuses_dependency_stacking_on_a_draft_pr_workflow
    with_registered_workflow(draft_pr_workflow) do
      with_project do |dir, _project|
        folder = File.join(dir, ".hive-state", "stages", "1-inbox", "async-task")
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "request.md"), "# fix\n")
        Hive::TaskMeta.write(folder, id: 90, slug: "async-task", display_name: nil, workflow: "async_fix")

        error = assert_raises(Hive::Commands::Stack::Refusal) { stack(folder, on: [ "base-task" ]) }

        assert_equal "unsupported_workflow", error.error_kind
        assert_nil Hive::TaskMeta.read(folder)[:depends_on]
      end
    end
  end

  def test_invalid_metadata_is_refused_as_config_without_rewriting_it
    with_project do |_dir, project|
      dependent = create_task(project, "dependent-task")
      meta = File.join(dependent, "meta.yml")
      File.write(meta, "#{File.read(meta)}plan_review_required: maybe\n")
      before = File.binread(meta)

      error = assert_raises(Hive::ConfigError) { stack("dependent-task", on: [ "base-task" ]) }

      assert_includes error.message, "repair meta.yml by hand"
      assert_equal before, File.binread(meta)
    end
  end

  def test_project_enrollment_must_be_exactly_one_entry
    with_project do |_dir, project|
      dependent = create_task(project, "dependent-task")
      entry = Hive::Config.registered_projects.find { |row| row["name"] == project }

      [ [], [ entry, entry.merge("name" => "#{project}-copy") ] ].each do |entries|
        error = with_replaced_singleton_method(Hive::Config, :registered_projects, ->(*, **) { entries }) do
          assert_raises(Hive::ConfigError) { stack(dependent, on: [ "base-task" ]) }
        end
        assert_match(/not enrolled|enrolled more than once/, error.message)
      end
    end
  end

  def test_a_task_that_vanishes_mid_update_is_a_retryable_stale_task
    with_project do |_dir, project|
      create_task(project, "base-task")
      create_task(project, "dependent-task")

      with_replaced_singleton_method(Hive::TaskMeta, :observe, ->(*) { nil }) do
        assert_raises(Hive::TaskMeta::StaleTask) { stack("dependent-task", on: [ "base-task" ]) }
      end

      stale = Hive::TaskMeta::UpdateResult.new(status: :stale, value: nil)
      with_replaced_singleton_method(Hive::TaskMeta, :rewrite, ->(*, **) { stale }) do
        error = assert_raises(Hive::TaskMeta::StaleTask) { stack("dependent-task", on: [ "base-task" ]) }
        assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      end
    end
  end

  private

  def draft_pr_workflow
    Hive::Workflow.new(
      id: :async_fix,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "request.md", kind: :inert),
        Hive::Workflow::Stage.new(
          name: "fix", index: 2, state_file: "fix-report.md", kind: :agent,
          workspace: :worktree, handoff: :draft_pr, deliverable: "fix-report.md"
        )
      ]
    )
  end

  def with_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield dir, File.basename(dir)
      end
    end
  end

  def create_task(project, slug, depends_on: nil)
    capture_io do
      Hive::Commands::New.new(project, slug.tr("-", " "), slug_override: slug, depends_on: depends_on).call!
    end
    Dir[File.join(Hive::Config.registered_projects.find { |entry| entry["name"] == project }.fetch("path"),
                  ".hive-state", "stages", "*", slug)].first
  end

  def move_task(dir, folder, stage)
    destination = File.join(dir, ".hive-state", "stages", stage, File.basename(folder))
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.mv(folder, destination)
    destination
  end

  def stack(target, on: nil, clear: false)
    stack_with_io(target, on: on, clear: clear).first
  end

  def stack_with_io(target, on: nil, clear: false)
    payload = nil
    _, err = capture_io do
      payload = Hive::Commands::Stack.new(target, on: on, clear: clear).call
    end
    [ payload, err ]
  end

  def admission_verdict(dir, project, slug)
    Hive::DependencySnapshot.admission_context([
      { "name" => project, "path" => dir, "repository_identity" => nil }
    ]).verdict(project: project, slug: slug)
  end

  def last_commit_subject(dir)
    `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
  end
end
