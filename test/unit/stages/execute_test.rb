require "test_helper"
require "hive/stages/execute"
require "hive/markers"

class HiveStagesExecuteTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :worktree_yml_path, :project_root, :slug, :reviews_dir, :depends_on, :id, keyword_init: true)

  FakeWorktree = Struct.new(:path, :create_calls, keyword_init: true) do
    def create!(branch_name, default_branch:, base_override: nil)
      create_calls << { branch_name: branch_name, default_branch: default_branch, base_override: base_override }
      FileUtils.mkdir_p(path)
    end

    def write_pointer!(task_folder, branch_name, execute_base_head: nil,
                       base_branch: nil, base_oid: nil, repository: nil)
      data = {
        "path" => path,
        "branch" => branch_name,
        "execute_base_head" => execute_base_head
      }
      data["base_branch"] = base_branch if base_branch
      data["base_oid"] = base_oid if base_oid
      data["repository"] = repository if repository
      File.write(File.join(task_folder, "worktree.yml"), data.to_yaml)
    end
  end

  FakeGit = Struct.new(:head, :branch, :dirty, :ancestor_result, :raise_head, :raise_ancestor, keyword_init: true) do
    def head_sha
      raise Hive::GitError, "head failed" if raise_head

      head
    end

    def current_branch
      branch
    end

    def status_short
      dirty ? " M file.txt\n" : ""
    end

    def ancestor?(_base, _head)
      raise Hive::GitError, "ancestor failed" if raise_ancestor

      ancestor_result
    end
  end

  def test_run_checks_plan_review_before_identity_or_worktree_initialization
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      identity_calls = 0
      guard = lambda do |**|
        raise Hive::PlanReview::TransitionBlocked, "review blocked"
      end

      with_replaced_singleton_method(
        Hive::PlanReview::TransitionGuard, :validate_execute_entry!, guard
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :capture_implementation_identity, lambda { |*|
            identity_calls += 1
          }
        ) do
          assert_raises(Hive::PlanReview::TransitionBlocked) do
            Hive::Stages::Execute.run!(task, "worktree_root" => File.join(dir, "worktrees"))
          end
        end
      end

      assert_equal 0, identity_calls
      refute File.exist?(task.worktree_yml_path)
      refute Dir.exist?(File.join(dir, "worktrees", task.slug))
    end
  end

  def test_apply_execute_outcome_publishes_projection_before_compatibility_marker
    with_tmp_git_repo do |worktree|
      with_tmp_dir do |dir|
        task = build_task(dir)
        task.project_root = worktree
        task.define_singleton_method(:worktree_path) { worktree }
        write_plan(task)
        baseline = Hive::GitOps.new(worktree).head_sha
        store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
        policy = Hive::Workflows::Coding::DESCRIPTOR.stage_named("execute").condition_policy.to_h
        attempt = store.create_launching(
          attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
          task_id: task.id.to_s, project: "demo", task_slug: task.slug,
          intended_stage: "4-execute", task_generation: "owner-1",
          ownership_generation: "owner-1", task_input_epoch: 1,
          progress_token: Digest::SHA256.hexdigest(Hive::TaskProjection.canonical_json(policy)),
          provider: "codex", worker_argv: [ "hive", "run", task.folder ],
          claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
          starting_revision: baseline, retry_charge: 0,
          inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
        )
        cfg = { "conditions" => { "authority" => "markers",
                                  "stages" => { "4-execute" => "conditions" } } }
        original = Hive::Markers.method(:set)
        observed = []
        Hive::Markers.define_singleton_method(:set) do |path, name, attrs = {}|
          projection_path = File.join(File.dirname(path), "task-projection.json")
          journal_path = File.join(File.dirname(path), "task-journal.jsonl")
          observed << [ File.exist?(journal_path), File.exist?(projection_path), name ]
          original.call(path, name, attrs)
        end

        with_env("HIVE_ATTEMPT_STORE_ROOT" => File.join(dir, "attempts")) do
          with_attempt_context(
            attempt_id: attempt.attempt_id, task_generation: 1,
            ownership_generation: attempt.ownership_generation
          ) do
            File.write(File.join(worktree, "change.txt"), "change\n")
            run!("git", "-C", worktree, "add", "change.txt")
            run!("git", "-C", worktree, "commit", "-m", "change", "--quiet")
            result = Hive::Stages::Execute.apply_execute_outcome(
              task, cfg, worktree, baseline,
              marker_name: :execute_complete, attrs: {}, commit: "execute_complete",
              status: :execute_complete
            )
            assert_equal :execute_complete, result.fetch(:status)
          end
        end
        assert_equal [ [ true, true, :execute_complete ] ], observed
      ensure
        Hive::Markers.define_singleton_method(:set, original) if original
      end
    end
  end

  def test_run_exits_when_worktree_pointer_path_is_missing
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "missing-worktree"), "branch" => task.slug)

      _out, err, status = with_captured_exit { Hive::Stages::Execute.run!(task, {}) }

      assert_equal 1, status
      assert_includes err, "worktree pointer present but worktree missing"
    end
  end

  def test_run_rejects_routed_identity_before_initializing_stage_state
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      worktree_root = File.join(dir, "worktrees")

      with_replaced_singleton_method(
        Hive::Stages::Execute, :capture_implementation_identity,
        ->(_task, _cfg) { raise Hive::ConfigError, "unsupported routed effort" }
      ) do
        error = assert_raises(Hive::ConfigError) do
          Hive::Stages::Execute.run!(task, "worktree_root" => worktree_root)
        end

        assert_equal "unsupported routed effort", error.message
      end

      refute Dir.exist?(task.reviews_dir)
      refute File.exist?(task.worktree_yml_path)
      refute File.exist?(task.state_file)
      refute Dir.exist?(File.join(worktree_root, task.slug))
    end
  end

  def test_run_pass_waits_when_new_head_is_not_descendant
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "new-head", branch: task.slug, dirty: false, ancestor_result: false)

      result = with_fake_git_and_spawn(git, status: :ok) do
        Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "execute_waiting_head_not_descendant", status: :execute_waiting }, result)
      assert_equal :execute_waiting, marker.name
      assert_equal "head_not_descendant", marker.attrs["reason"]
    end
  end

  def test_run_pass_makes_agent_owned_dirty_progress_recoverable
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: true, ancestor_result: true
      )

      result = with_fake_git_and_spawn(git, status: :ok) do
        Hive::Stages::Execute.run_pass(
          task, execute_cfg("pi"), File.join(dir, "worktree")
        )
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "execute_dirty_worktree", status: :error }, result)
      assert_equal :error, marker.name
      assert_equal "dirty_worktree", marker.attrs.fetch("reason")
    end
  end

  def test_run_pass_marks_error_when_ancestor_check_raises
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "new-head", branch: task.slug, dirty: false, ancestor_result: true, raise_ancestor: true)

      result = with_fake_git_and_spawn(git, status: :ok) do
        Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "execute_worktree_git_failed", status: :error }, result)
      assert_equal :error, marker.name
      assert_equal "worktree_git_failed", marker.attrs["reason"]
    end
  end

  def test_run_pass_marks_limits_reached_when_implementation_error_message_hits_quota
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = {
        status: :error,
        error_message: "limits reached for codex: You've hit your usage limit. " \
                       "Try again at Jul 18th, 2026 7:50 AM."
      }
      now = Time.utc(2026, 7, 12, 20, 0, 0)

      run_result = with_env("TZ" => "Europe/London") do
        with_replaced_singleton_method(Time, :now, -> { now }) do
          with_fake_git_and_spawn(git, result: result) do
            Hive::Stages::Execute.run_pass(task, execute_cfg("codex"), File.join(dir, "worktree"))
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "limits_reached", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs["reason"]
      assert_equal "codex", marker.attrs["provider"]
      assert_equal "implementer hit a usage/credit limit", marker.attrs["message"]
      assert_equal "2026-07-18T06:51:00Z", marker.attrs.fetch("retry_after")
    end
  end

  def test_run_pass_marks_limits_reached_when_limit_text_hits_quota
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = {
        status: :error,
        limit_text: "rate limit reached",
        error_message: "exit_code=1"
      }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("codex"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "limits_reached", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs["reason"]
      assert_equal "codex", marker.attrs["provider"]
      assert Time.parse(marker.attrs.fetch("retry_after")) > Time.now.utc
    end
  end

  def test_run_pass_preserves_typed_zero_exit_402_limit_classification
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(
        task, "path" => File.join(dir, "worktree"), "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = {
        status: :error,
        exit_code: 0,
        error_reason: "limits_reached",
        limit_text: "Prompt tokens limit exceeded: 25770 > 8471",
        error_message:
          '402: {"message":"Prompt tokens limit exceeded: 25770 > 8471","code":402}',
        provider_error: { kind: :provider_limit, provider: :pi, status_code: 402 }
      }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("pi"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "limits_reached", status: :error }, run_result)
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      assert_equal "pi", marker.attrs.fetch("provider")
      assert Time.parse(marker.attrs.fetch("retry_after")) > Time.now.utc
    end
  end

  def test_run_pass_preserves_non_limit_implementation_failure_marker
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = { status: :error, error_message: "exit_code=1 compile error" }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("codex"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "implementer_failed", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "implementer_failed", marker.attrs["reason"]
      assert_equal "codex", marker.attrs["provider"]
      assert_equal "error", marker.attrs["status"]
      assert_equal "exit_code=1 compile error", marker.attrs["message"]
      refute marker.attrs.key?("retry_after")
    end
  end

  def test_run_pass_attributes_failure_to_persisted_provider
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug,
                    "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = {
        status: :error, error_message: "401 unauthorized",
        implementation_provider: "codex"
      }

      with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("claude"), File.join(dir, "worktree"))
      end

      assert_equal "codex", Hive::Markers.current(task.state_file).attrs["provider"]
    end
  end

  def test_run_pass_detects_implementation_identity_journal_tampering
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug,
                    "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            agent_custody.call do
              File.write(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME), "tampered\n")
              { status: :ok }
            end
          }
        ) do
          result = Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
          assert_equal({ commit: "implementer_tampered", status: :error }, result)
        end
      end

      assert_includes Hive::Markers.current(task.state_file).attrs["files"],
                      Hive::TaskJournal::JOURNAL_BASENAME
    end
  end

  def test_execute_custody_protects_controller_workspace_receipts
    with_tmp_dir do |dir|
      task = build_task(dir)
      FileUtils.mkdir_p(File.join(task.folder, "context-receipts"))
      FileUtils.mkdir_p(File.join(task.folder, "activity-operations"))
      File.write(File.join(task.folder, "context-receipts", "older.launch.json"), "launch\n")
      File.write(File.join(task.folder, "context-receipts", "current.json.next"), "candidate\n")
      File.write(File.join(task.folder, "activity-operations", "operation.json"), "operation\n")

      protected = Hive::Stages::Execute.execute_protected_files(task)

      assert_includes protected, "task-projection.checkpoint.json"
      assert_includes protected, "context-receipts/older.launch.json"
      assert_includes protected, "activity-operations/operation.json"
      refute_includes protected, "context-receipts/current.json.next"
    end
  end

  def test_execute_custody_keeps_a_receipt_that_disappears_during_stat
    with_tmp_dir do |dir|
      task = build_task(dir)
      directory = File.join(task.folder, "activity-operations")
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "vanishing.json")
      File.write(path, "operation\n")
      original_lstat = File.method(:lstat)
      replacement = lambda do |candidate|
        raise Errno::ENOENT if candidate == path

        original_lstat.call(candidate)
      end

      protected = with_replaced_singleton_method(File, :lstat, replacement) do
        Hive::Stages::Execute.execute_protected_files(task)
      end
      assert_includes protected, "activity-operations/vanishing.json"
    end
  end

  def test_run_pass_batches_growing_controller_receipts_without_dropping_custody
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug,
                    "execute_base_head" => "base")
      receipt_dir = File.join(task.folder, "context-receipts")
      FileUtils.mkdir_p(receipt_dir)
      receipt_count = Hive::ArtifactFirewall::MAX_ENTRIES + 5
      receipt_count.times do |index|
        File.write(File.join(receipt_dir, format("receipt-%03d.launch.json", index)), "trusted\n")
      end
      tampered = File.join(receipt_dir, format("receipt-%03d.launch.json", receipt_count - 1))
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      launched = false

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            launched = true
            agent_custody.call do
              File.write(tampered, "agent forged\n")
              { status: :ok }
            end
          }
        ) do
          result = Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))

          assert_equal({ commit: "implementer_tampered", status: :error }, result)
        end
      end

      assert launched
      assert_equal "trusted\n", File.binread(tampered)
      assert_includes Hive::Markers.current(task.state_file).attrs.fetch("files"),
                      File.basename(tampered)
    end
  end

  def test_run_pass_keeps_controller_journal_writes_outside_implementer_custody
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug,
                    "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      journal = File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            File.write(journal, "controller session start\n")
            begin
              agent_custody.call { raise IOError, "provider failed" }
            ensure
              File.open(journal, "ab") { |file| file.write("controller session finish\n") }
            end
          }
        ) do
          error = assert_raises(IOError) do
            Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
          end
          assert_equal "provider failed", error.message
        end
      end

      assert_equal "controller session start\ncontroller session finish\n", File.binread(journal)
    end
  end

  def test_run_pass_restores_custody_before_propagating_spawn_exception
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      original_plan = File.binread(File.join(task.folder, "plan.md"))
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: false, ancestor_result: true
      )

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            agent_custody.call do
              File.write(File.join(task.folder, "plan.md"), "forged\n")
              raise IOError, "provider stream failed"
            end
          }
        ) do
          error = assert_raises(IOError) do
            Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
          end

          assert_equal "provider stream failed", error.message
        end
      end

      assert_equal original_plan, File.binread(File.join(task.folder, "plan.md"))
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "implementer_tampered", marker.attrs.fetch("reason")
    end
  end

  def test_run_pass_marks_spawn_exception_as_recoverable_implementation_failure
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: false, ancestor_result: true
      )

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            agent_custody.call { raise Errno::E2BIG, "pi" }
          }
        ) do
          assert_raises(Errno::E2BIG) do
            Hive::Stages::Execute.run_pass(
              task, execute_cfg("pi"), File.join(dir, "worktree")
            )
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "implementer_failed", marker.attrs.fetch("reason")
      assert_equal "pi", marker.attrs.fetch("provider")
      assert_equal "exception", marker.attrs.fetch("status")
      assert_equal "Errno::E2BIG", marker.attrs.fetch("exception_class")
      assert_equal "Argument list too long - pi", marker.attrs.fetch("message")
    end
  end

  def test_run_pass_does_not_write_a_marker_when_custody_validation_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: false, ancestor_result: true
      )

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::ArtifactFirewall, :validate_and_restore,
          ->(_manifest, _snapshot) { raise Hive::ArtifactFirewall::InvalidSnapshot, "broken" }
        ) do
          with_replaced_singleton_method(
            Hive::Stages::Execute, :spawn_implementation,
            lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
              agent_custody.call { { status: :ok } }
            }
          ) do
            assert_raises(Hive::ArtifactFirewall::InvalidSnapshot) do
              Hive::Stages::Execute.run_pass(
                task, execute_cfg("pi"), File.join(dir, "worktree")
              )
            end
          end
        end
      end

      assert_equal :none, Hive::Markers.current(task.state_file).name
    end
  end

  def test_run_pass_marks_admitted_provider_failure_before_propagating_it
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: false, ancestor_result: true
      )
      routing = {
        "mode" => "explicit",
        "policy_digest" => "a" * 64,
        "decision" => {},
        "route" => {
          "route_id" => "codex-a/codex-e2e-model",
          "provider_account_id" => "codex-a",
          "adapter" => "codex",
          "launch_binding_id" => "default",
          "model" => "codex-e2e-model",
          "effort" => "high"
        },
        "circuit_generations" => [],
        "probe_bindings" => []
      }
      context = Hive::Attempts::Context.send(
        :new,
        attempt_id: "attempt-route-failed",
        task_generation: 1,
        ownership_generation: "owner-route-failed",
        routing: routing
      )

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
          with_replaced_singleton_method(
            Hive::Stages::Execute, :spawn_implementation,
            lambda { |_task, _cfg, _path, **_kwargs|
              raise Hive::ProviderRouteFailed, "admitted provider route failed"
            }
          ) do
            assert_raises(Hive::ProviderRouteFailed) do
              Hive::Stages::Execute.run_pass(
                task, {}, File.join(dir, "worktree"), Object.new
              )
            end
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "provider_route_failed", marker.attrs.fetch("reason")
      assert_equal "codex-a", marker.attrs.fetch("provider_account_id")
      assert_equal "codex-a/codex-e2e-model", marker.attrs.fetch("route_id")
      assert_equal "attempt-route-failed", marker.attrs.fetch("attempt_id")
      assert_equal "owner-route-failed", marker.attrs.fetch("task_generation")
      assert_equal "owner-route-failed", marker.attrs.fetch("ownership_generation")
      assert_equal "1", marker.attrs.fetch("task_input_epoch")
    end
  end

  def test_run_pass_reports_restored_custody_tampering_before_provider_failure
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      original_plan = File.binread(File.join(task.folder, "plan.md"))
      write_pointer(
        task,
        "path" => File.join(dir, "worktree"),
        "branch" => task.slug,
        "execute_base_head" => "base"
      )
      git = FakeGit.new(
        head: "base", branch: task.slug, dirty: false, ancestor_result: true
      )

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
        with_replaced_singleton_method(
          Hive::Stages::Execute, :spawn_implementation,
          lambda { |_task, _cfg, _path, agent_custody:, **_kwargs|
            agent_custody.call do
              File.write(File.join(task.folder, "plan.md"), "forged\n")
              raise Hive::ProviderRouteFailed, "admitted provider route failed"
            end
          }
        ) do
          assert_raises(Hive::ProviderRouteFailed) do
            Hive::Stages::Execute.run_pass(task, {}, File.join(dir, "worktree"))
          end
        end
      end

      assert_equal original_plan, File.binread(File.join(task.folder, "plan.md"))
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "implementer_tampered", marker.attrs.fetch("reason")
    end
  end

  # `agent_failed?` is true for :timeout as well as :error, and the
  # non-limit branch records `status: impl_result[:status]` verbatim — so a
  # timeout (e.g. the exit_code_only "stop hook did not signal completion"
  # drain) must attribute as `implementer_failed status=timeout`.
  def test_run_pass_records_timeout_status_for_non_limit_implementation_timeout
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = { status: :timeout, error_message: "claude stop hook did not signal completion" }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("codex"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "implementer_failed", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "implementer_failed", marker.attrs["reason"]
      assert_equal "codex", marker.attrs["provider"]
      assert_equal "timeout", marker.attrs["status"]
      assert_equal "claude stop hook did not signal completion", marker.attrs["message"]
      refute marker.attrs.key?("retry_after")
    end
  end

  # When the execute agent name can't be resolved (unregistered profile),
  # `execute_agent_name` rescues to nil rather than letting the exception
  # escape; the limits_reached marker is still written, just with provider
  # dropped (markers compact nil attrs away).
  def test_run_pass_marks_limits_reached_with_no_provider_when_execute_agent_unresolvable
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      write_pointer(task, "path" => File.join(dir, "worktree"), "branch" => task.slug, "execute_base_head" => "base")
      git = FakeGit.new(head: "base", branch: task.slug, dirty: false, ancestor_result: true)
      result = { status: :error, limit_text: "rate limit reached", error_message: "exit_code=1" }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("nonexistent-agent"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "limits_reached", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs["reason"]
      refute marker.attrs.key?("provider"),
             "an unresolvable execute agent must drop provider, not crash"
      assert Time.parse(marker.attrs.fetch("retry_after")) > Time.now.utc
    end
  end

  def test_execute_baseline_head_returns_nil_when_git_head_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      git = FakeGit.new(raise_head: true)

      assert_nil Hive::Stages::Execute.execute_baseline_head(task, git)
    end
  end

  def test_inspect_worktree_state_returns_nil_when_git_status_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      git = FakeGit.new(raise_head: true)

      assert_nil Hive::Stages::Execute.inspect_worktree_state(task, git)
    end
  end

  def test_run_init_pass_bases_worktree_on_dependency_branch
    with_tmp_dir do |dir|
      task = build_task(dir, depends_on: "base-task")
      write_plan(task)
      Hive::TaskMeta.write(task.folder, id: 2, slug: task.slug, display_name: nil, depends_on: "base-task")
      base_folder = File.join(dir, ".hive-state", "stages", "8-finalize", "base-task")
      FileUtils.mkdir_p(base_folder)
      Hive::TaskMeta.write(base_folder, id: 1, slug: "base-task", display_name: nil)

      fake_wt = FakeWorktree.new(path: File.join(dir, "worktrees", task.slug), create_calls: [])
      project_git = Struct.new(:default_branch).new("master")
      worktree_git = Struct.new(:head_sha).new("base-head")

      with_replaced_singleton_method(Hive::GitOps, :new, ->(path) { path == dir ? project_git : worktree_git }) do
        with_replaced_singleton_method(Hive::Worktree, :new, ->(_project_root, _slug, worktree_root:) { fake_wt }) do
          with_replaced_singleton_method(Hive::Stages::Execute, :run_pass, ->(_task, _cfg, _path, _identity) { { commit: nil, status: :ok } }) do
            Hive::Stages::Execute.run_init_pass(task, { "worktree_root" => File.join(dir, "worktrees") })
          end
        end
      end

      assert_equal [
        { branch_name: task.slug, default_branch: "master", base_override: "base-task" }
      ], fake_wt.create_calls
      pointer = YAML.safe_load(File.read(task.worktree_yml_path))
      assert_equal "base-head", pointer.fetch("execute_base_head")
      assert_equal "master", pointer.fetch("base_branch")
      assert_equal "base-head", pointer.fetch("base_oid")
    end
  end

  def test_append_implementation_output_inserts_before_terminal_marker
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.write(task.state_file, "# Task\n\n<!-- AGENT_WORKING -->\n")

      Hive::Stages::Execute.append_implementation_output(task, final_message: "implementation summary")

      content = File.read(task.state_file)
      assert_match(/## Execute Output\n\nimplementation summary\n\n<!-- AGENT_WORKING -->\n\z/, content)
    end
  end

  def test_research_execution_returns_false_for_malformed_frontmatter
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task, "---\n:\n---\nbody\n")

      assert_equal false, Hive::Stages::Execute.research_execution?(task)
    end
  end

  def test_research_execution_uses_shared_plan_frontmatter_parser
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task, "---\nexecution_mode: research\ndepends_on: base-task\n---\nbody\n")

      assert_equal true, Hive::Stages::Execute.research_execution?(task)
    end
  end

  # End-to-end through the real 4-execute spawn helper: a non-yolo scope on
  # a non-claude runner (the A8 gate) must replace the stale AGENT_WORKING
  # marker with an attributed :error before the ConfigError propagates,
  # rather than escaping uncaught and leaving 4-execute looking alive.
  def test_spawn_implementation_attributes_error_marker_on_non_claude_scope
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      Hive::Markers.set(task.state_file, :agent_working)
      cfg = {
        "permissions" => "yolo",
        "execute" => { "agent" => "codex", "permissions" => "read-only" }
      }

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Execute.spawn_implementation(task, cfg, File.join(dir, "worktree"))
      end
      assert_match(/runner :codex/, error.message)

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name, "stale AGENT_WORKING must become attributed :error"
      assert_equal "permission_config_error", marker.attrs["reason"]
    end
  end

  def test_spawn_implementation_never_reaches_launcher_when_identity_capture_fails
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      fake_store = Object.new
      fake_store.define_singleton_method(:capture_execute!) do
        raise Hive::TaskJournal::Error, "synthetic append failure"
      end
      spawned = false

      with_replaced_singleton_method(Hive::ImplementationIdentity::Store, :new, ->(**) { fake_store }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |*_, **_kwargs|
          spawned = true
        }) do
          with_attempt_context(
            attempt_id: "attempt", task_generation: 1, ownership_generation: "owner"
          ) do
            assert_raises(Hive::TaskJournal::Error) do
              Hive::Stages::Execute.spawn_implementation(
                task, execute_cfg("codex").merge(
                  "budget_usd" => { "execute_implementation" => 1 },
                  "timeout_sec" => { "execute_implementation" => 5 }
                ),
                File.join(dir, "worktree")
              )
            end
          end
        end
      end

      refute spawned
    end
  end

  def test_spawn_implementation_declares_the_execute_identity_observation_stage
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      identity = Struct.new(:provider, :native_arguments) do
        def routing_arguments(_profile) = nil
      end.new("opencode", [])
      spawned = nil
      result = {
        status: :ok,
        requested_opencode_route: "anthropic/claude-sonnet-4-5",
        actual_opencode_route: "anthropic/claude-sonnet-4-5-20250929",
        route_resolution_status: :resolved_differently,
        normalized_outcome_kind: :completed,
        usage: {
          input: nil, output: 0, cached: nil, cache_read: nil,
          cache_write: 0, reasoning: nil, cost: 0.0
        }
      }
      scope = {
        add_dirs: [ task.folder ], permission_mode: "read-only",
        allowed_tools: nil, disallowed_tools: nil, runtime_policy: nil,
        additional_read_roots: [ task.folder ], additional_write_roots: []
      }

      with_replaced_singleton_method(
        Hive::Stages::Base, :stage_permission_scope_or_mark!,
        ->(*, **) { scope }
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :spawn_agent,
          ->(*, **kwargs) { spawned = kwargs; result }
        ) do
          cfg = {
            "agents" => { "opencode" => {} },
            "execute" => { "agent" => "opencode" },
            "budget_usd" => { "execute_implementation" => 1 },
            "timeout_sec" => { "execute_implementation" => 5 }
          }
          returned = Hive::Stages::Execute.spawn_implementation(
            task, cfg, File.join(dir, "worktree"), identity: identity
          )

          assert_equal "opencode", returned.fetch(:implementation_provider)
          assert_same cfg, spawned.fetch(:cfg)
          assert_equal "execute", spawned.fetch(:implementation_stage)
          assert spawned.fetch(:defer_implementation_observation)
        end
      end
    end
  end

  def test_spawn_implementation_routes_opencode_without_an_attempt_context
    with_tmp_dir do |dir|
      task = build_task(dir)
      write_plan(task)
      spawned = nil
      scope = {
        add_dirs: [ task.folder ], permission_mode: "workspace-write",
        allowed_tools: nil, disallowed_tools: nil, runtime_policy: nil,
        additional_read_roots: [ task.folder ],
        additional_write_roots: [ task.folder ]
      }
      cfg = {
        "agents" => { "opencode" => {} },
        "execute" => { "agent" => "opencode" },
        "models" => {
          "execute_implementation" => {
            "model" => "anthropic/claude-sonnet-4-5", "effort" => "high"
          }
        }
      }

      with_replaced_singleton_method(
        Hive::Stages::Base, :stage_permission_scope_or_mark!,
        ->(*, **) { scope }
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :spawn_agent,
          ->(*, **kwargs) { spawned = kwargs; { status: :ok } }
        ) do
          Hive::Stages::Execute.spawn_implementation(
            task, cfg, File.join(dir, "worktree")
          )
        end
      end

      routing = spawned.fetch(:routing_arguments)
      assert_equal :opencode, routing.profile_name
      assert_equal "execute_implementation", routing.stage
      assert_equal "anthropic/claude-sonnet-4-5", routing.model
      assert_equal "high", routing.effort
      assert_equal [
        "--model", "anthropic/claude-sonnet-4-5", "--variant", "high"
      ], routing.native_arguments
      assert_nil spawned.fetch(:identity_arguments)
      assert spawned.fetch(:defer_implementation_observation)
    end
  end

  def build_task(project_root, depends_on: nil)
    folder = File.join(project_root, ".hive-state", "stages", "4-execute", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    TaskStub.new(
      folder: folder,
      state_file: File.join(folder, "task.md"),
      worktree_yml_path: File.join(folder, "worktree.yml"),
      project_root: project_root,
      slug: "demo-260522-aaaa",
      reviews_dir: File.join(folder, "reviews"),
      depends_on: depends_on,
      id: 2
    )
  end

  def write_plan(task, content = "# plan\n")
    File.write(File.join(task.folder, "plan.md"), content)
  end

  def write_pointer(task, attrs)
    File.write(task.worktree_yml_path, attrs.to_yaml)
  end

  def execute_cfg(agent)
    { "execute" => { "agent" => agent } }
  end

  def with_fake_git_and_spawn(git, status: :ok, result: nil)
    with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |_task, _cfg, _path, **_kwargs|
        result || { status: status }
      }) do
        yield
      end
    end
  end
end
