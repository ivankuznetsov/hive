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

    def write_pointer!(task_folder, branch_name, execute_base_head: nil)
      File.write(File.join(task_folder, "worktree.yml"), {
        "path" => path,
        "branch" => branch_name,
        "execute_base_head" => execute_base_head
      }.to_yaml)
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
          provider: "codex", starting_revision: baseline, retry_charge: 0,
          inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
        )
        cfg = { "conditions" => { "authority" => "markers",
                                  "stages" => { "4-execute" => "conditions" } } }
        original = Hive::Markers.method(:set)
        observed = []
        Hive::Markers.define_singleton_method(:set) do |path, name, attrs = {}|
          projection_path = File.join(File.dirname(path), "task-projection.json")
          journal_path = File.join(File.dirname(path), "events.jsonl")
          observed << [ File.exist?(journal_path), File.exist?(projection_path), name ]
          original.call(path, name, attrs)
        end

        with_env("HIVE_ATTEMPT_STORE_ROOT" => File.join(dir, "attempts")) do
          Hive::Attempts::Context.with(
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
        error_message: "limits reached for codex: quota exhausted, try again at Jun 24th"
      }

      run_result = with_fake_git_and_spawn(git, result: result) do
        Hive::Stages::Execute.run_pass(task, execute_cfg("codex"), File.join(dir, "worktree"))
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal({ commit: "limits_reached", status: :error }, run_result)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs["reason"]
      assert_equal "codex", marker.attrs["provider"]
      assert_equal "implementer hit a usage/credit limit", marker.attrs["message"]
      assert Time.parse(marker.attrs.fetch("retry_after")) > Time.now.utc
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
          with_replaced_singleton_method(Hive::Stages::Execute, :run_pass, ->(_task, _cfg, _path) { { commit: nil, status: :ok } }) do
            Hive::Stages::Execute.run_init_pass(task, { "worktree_root" => File.join(dir, "worktrees") })
          end
        end
      end

      assert_equal [
        { branch_name: task.slug, default_branch: "master", base_override: "base-task" }
      ], fake_wt.create_calls
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
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |_task, _cfg, _path|
        result || { status: status }
      }) do
        yield
      end
    end
  end
end
