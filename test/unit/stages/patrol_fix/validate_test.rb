require_relative "fix_test"
require "hive/stages/patrol_fix/validate"

class PatrolFixValidateStageTest < Minitest::Test
  include HiveTestHelper

  def test_failed_deliberate_validation_is_durable_and_never_executes_reproduction_prose
    with_fixed_task do |task, worktrees, _owner, _head, _store|
      cfg = { "patrol" => { "commands" => { "test" => "ruby -e 'exit 7'" } } }

      result = Hive::Stages::PatrolFix::Validate.run!(task, cfg, worktree_root: worktrees)
      assert_equal :complete, result.fetch(:status)
      assert_equal "failed", result.dig(:receipt, "payload", "verdict")
      assert_equal [ "ordinary:test" ], result.dig(:receipt, "payload", "commands").map { |row| row.fetch("identity") }
      refute File.exist?("/tmp/never-from-prose")
    end
  ensure
    File.delete("/tmp/never-from-prose") if File.exist?("/tmp/never-from-prose")
  end

  def test_validation_runs_in_a_disposable_exact_head_checkout
    with_fixed_task do |task, worktrees, owner, expected_head, _store|
      checkout = nil
      ignored = File.join(owner.fetch("worktree"), "ignored-runtime")
      File.write(ignored, "authoritative-only\n")
      runner = lambda do |path, _commands|
        checkout = path
        refute_equal owner.fetch("worktree"), path
        assert_equal expected_head, PatrolFixStageFixture.git(path, "rev-parse", "HEAD").strip
        assert_equal "", PatrolFixStageFixture.git(path, "branch", "--show-current").strip
        refute File.exist?(File.join(path, "ignored-runtime"))
        File.write(File.join(path, "app.rb"), "puts :formatted\n")
        { "commands" => [] }
      end

      result = Hive::Stages::PatrolFix::Validate.run!(
        task, {}, command_runner: runner, worktree_root: worktrees
      )

      assert_equal :complete, result.fetch(:status)
      assert_equal "puts :fixed\n", File.read(File.join(owner.fetch("worktree"), "app.rb"))
      assert_equal "", PatrolFixStageFixture.git(owner.fetch("worktree"), "status", "--porcelain")
      refute File.exist?(checkout), "disposable validation checkout must be removed"
    end
  end

  def test_disposable_checkout_is_removed_when_the_validator_raises
    with_fixed_task do |task, worktrees, _owner, _head, store|
      checkout = nil
      runner = lambda do |path, _commands|
        checkout = path
        File.write(File.join(path, "partial.txt"), "discard me\n")
        raise "validator crashed"
      end

      error = assert_raises(RuntimeError) do
        Hive::Stages::PatrolFix::Validate.run!(
          task, {}, command_runner: runner, worktree_root: worktrees
        )
      end

      assert_equal "validator crashed", error.message
      refute File.exist?(checkout), "failed validation checkout must be removed"
      refute store.read_all.any? { |receipt| receipt["kind"] == "validation" }
    end
  end

  def test_cleanup_failure_does_not_discard_a_successful_validation
    with_fixed_task do |task, worktrees, _owner, _head, store|
      checkout = nil
      result = nil
      replacement = lambda do |**_kwargs|
        raise Hive::AgentGitGate::MaterializationFailed, "cleanup refused"
      end

      _, warning = capture_io do
        result = with_replaced_singleton_method(
          Hive::AgentGitGate, :remove_materialization, replacement
        ) do
          Hive::Stages::PatrolFix::Validate.run!(
            task, {}, command_runner: lambda { |path, _commands|
              checkout = path
              { "commands" => [] }
            }, worktree_root: worktrees
          )
        end
      end

      assert_equal :complete, result.fetch(:status)
      assert store.read_all.any? { |receipt| receipt["kind"] == "validation" }
      assert_includes warning, checkout
      assert_includes warning, "cleanup refused"
    ensure
      cleanup_leaked_checkout(task, checkout)
    end
  end

  def test_temporary_root_cleanup_failure_does_not_discard_a_successful_validation
    with_fixed_task do |task, worktrees, _owner, _head, store|
      checkout = nil
      leaked_root = nil
      result = nil
      replacement = lambda do |path|
        leaked_root = path
        raise Errno::ENOTEMPTY, path
      end

      _, warning = capture_io do
        result = with_replaced_singleton_method(Dir, :rmdir, replacement) do
          Hive::Stages::PatrolFix::Validate.run!(
            task, {}, command_runner: lambda { |path, _commands|
              checkout = path
              { "commands" => [] }
            }, worktree_root: worktrees
          )
        end
      end

      assert_equal :complete, result.fetch(:status)
      assert store.read_all.any? { |receipt| receipt["kind"] == "validation" }
      refute File.exist?(checkout)
      assert_equal File.dirname(checkout), leaked_root
      assert_includes warning, checkout
      assert_includes warning, "Directory not empty"
    ensure
      Dir.rmdir(leaked_root) if leaked_root && Dir.exist?(leaked_root)
    end
  end

  def test_cleanup_failure_does_not_mask_a_validator_error
    with_fixed_task do |task, worktrees, _owner, _head, store|
      checkout = nil
      error = nil
      replacement = lambda do |**_kwargs|
        raise Hive::AgentGitGate::MaterializationFailed, "cleanup refused"
      end

      _, warning = capture_io do
        error = with_replaced_singleton_method(
          Hive::AgentGitGate, :remove_materialization, replacement
        ) do
          assert_raises(RuntimeError) do
            Hive::Stages::PatrolFix::Validate.run!(
              task, {}, command_runner: lambda { |path, _commands|
                checkout = path
                raise "validator crashed"
              }, worktree_root: worktrees
            )
          end
        end
      end

      assert_equal "validator crashed", error.message
      refute store.read_all.any? { |receipt| receipt["kind"] == "validation" }
      assert_includes warning, checkout
      assert_includes warning, "cleanup refused"
    ensure
      cleanup_leaked_checkout(task, checkout)
    end
  end

  def test_external_authoritative_worktree_mutation_still_fails_closed
    with_fixed_task do |task, worktrees, owner, _head, store|
      checkout = nil
      runner = lambda do |path, _commands|
        checkout = path
        File.write(File.join(owner.fetch("worktree"), "app.rb"), "puts :external\n")
        { "commands" => [] }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Validate.run!(
          task, {}, command_runner: runner, worktree_root: worktrees
        )
      end

      assert_match(/validation changed the worktree bytes/, error.message)
      refute File.exist?(checkout), "disposable validation checkout must be removed"
      refute store.read_all.any? { |receipt| receipt["kind"] == "validation" }
    end
  end

  def test_materialization_failure_is_a_stage_error_and_does_not_run_commands
    with_fixed_task do |task, worktrees, _owner, _head, store|
      checkout = nil
      replacement = lambda do |**_kwargs|
        raise Hive::AgentGitGate::MaterializationFailed, "exact checkout refused"
      end
      cleanup_failure = lambda do |destination:, **_kwargs|
        checkout = destination
        raise Hive::AgentGitGate::MaterializationFailed, "cleanup refused"
      end

      error = nil
      _, warning = capture_io do
        error = with_replaced_singleton_method(
          Hive::AgentGitGate, :materialize, replacement
        ) do
          with_replaced_singleton_method(
            Hive::AgentGitGate, :remove_materialization, cleanup_failure
          ) do
            assert_raises(Hive::StageError) do
              Hive::Stages::PatrolFix::Validate.run!(
                task, {}, command_runner: ->(*) { flunk "must not run" },
                worktree_root: worktrees
              )
            end
          end
        end
      end

      assert_match(/validation checkout failed: exact checkout refused/, error.message)
      refute store.read_all.any? { |receipt| receipt["kind"] == "validation" }
      assert_includes warning, checkout
      assert_includes warning, "cleanup refused"
    ensure
      cleanup_leaked_checkout(task, checkout)
    end
  end

  private

  def with_fixed_task
    PatrolFixStageFixture.with_task(stage: "3-validate") do |task, root, manifest|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktrees = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root,
        slug: task.slug, worktree_root: worktrees
      )
      owner = custody.prepare!(
        generation: 1, evidence_digest: "a" * 64,
        base_revision: manifest.fetch("target_revision")
      )
      File.write(File.join(owner.fetch("worktree"), "app.rb"), "puts :fixed\n")
      File.write(File.join(owner.fetch("worktree"), ".gitignore"), "ignored-runtime\n")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "add", "app.rb", ".gitignore")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "commit", "-m", "Fix")
      payload = custody.capture!(generation: 1, evidence_digest: "a" * 64)
        .merge("validation_commands" => [])
      store.append!({
        "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
        "receipt_id" => "fix-1", "kind" => "fix", "stage" => "fix",
        "task" => manifest.fetch("task"),
        "evidence_revision" => manifest.fetch("evidence_revision"),
        "recorded_at" => "2026-08-20T12:01:00Z", "payload" => payload
      })
      yield task, worktrees, owner, payload.fetch("head_revision"), store
    end
  end

  def cleanup_leaked_checkout(task, checkout)
    return unless checkout

    root = File.dirname(checkout)
    unless Dir.exist?(root)
      PatrolFixStageFixture.git(task.project_root, "worktree", "prune", "--expire", "now")
      return
    end
    Hive::AgentGitGate.remove_materialization(
      repository_path: task.project_root, destination: checkout,
      destination_root: root, force: true
    )
    Dir.rmdir(root) if Dir.exist?(root)
  end
end
