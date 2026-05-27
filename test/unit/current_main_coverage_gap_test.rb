require "test_helper"
require "json"
require "hive/task"
require "hive/stages/artifacts"
require "hive/stages/finalize"
require "hive/stages/review"
require "hive/stages/review/browser_test"
require "hive/stages/review/ci_fix"
require "hive/stages/review/triage"
require "hive/reviewers/agent"
require "hive/tui/bubble_model"
require "hive/tui/messages"
require "hive/tui/red_status_detail_layout"
require "hive/tui/update"
require "hive/tui/views/idea_preview"
require "hive/tui/views/red_status_detail"

class CurrentMainCoverageGapTest < Minitest::Test
  include HiveTestHelper

  FakeProfile = Struct.new(:name) do
    def format_skill_invocation(skill)
      "/#{skill}"
    end
  end

  FakeTask = Struct.new(
    :folder, :worktree_path, :project_root, :state_file, :slug,
    :stage_index, :stage_name, keyword_init: true
  ) do
    def log_dir
      File.join(folder, "logs")
    end
  end

  FakeHandle = Struct.new(:calls) do
    def send_and_wait!(**kwargs)
      calls << kwargs
      File.write(kwargs.fetch(:expected_output), "ok\n")
      { status: :ok }
    end
  end

  ReviewCommandStatus = Struct.new(:success_value) do
    def success?
      success_value
    end
  end

  def row(stage: "6-review", slug: "red-task", folder: "/tmp/red-task", diagnostic: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: stage, slug: slug, folder: folder,
      state_file: File.join(folder.to_s, "task.md"), marker: "review_error",
      attrs: { "phase" => "fix", "pass" => "1" }, mtime: nil, age_seconds: 0,
      claude_pid: nil, claude_pid_alive: nil, action_key: "recover_review",
      action_label: "Needs recovery", suggested_command: nil, next_action: nil,
      diagnostic: diagnostic
    )
  end

  def task_folder(root, stage: "6-review", slug: "gap-task")
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(File.join(folder, "reviews"))
    folder
  end

  def review_ctx(root, folder, pass: 1)
    Hive::Stages::Review::Context.new(
      worktree_path: root,
      task_folder: folder,
      default_branch: "main",
      pass: pass
    )
  end

  def fake_task(root, folder, worktree: root)
    FakeTask.new(
      folder: folder,
      worktree_path: worktree,
      project_root: root,
      state_file: File.join(folder, "task.md"),
      slug: File.basename(folder),
      stage_index: 6,
      stage_name: "review"
    )
  end

  def accepted_findings(text = "## High\n- [x] apply a fix\n", count: 1)
    Hive::Stages::Review::AcceptedFindings.new(text: text, count: count)
  end

  def with_fake_profile(profile = FakeProfile.new(:codex))
    with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*_args, **_kwargs) { profile }) do
      yield profile
    end
  end

  def with_spawn_agent_capture(calls, result = { status: :ok })
    with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |task, **kwargs|
      calls << [ task, kwargs ]
      FileUtils.mkdir_p(File.dirname(kwargs[:expected_output])) if kwargs[:expected_output]
      File.write(kwargs[:expected_output], JSON.generate(status: "passed", summary: "ok", details: "", duration_sec: 1)) if kwargs[:expected_output]&.end_with?(".json")
      File.write(kwargs[:expected_output], "# Escalations\n") if kwargs[:expected_output]&.end_with?(".md")
      result
    }) do
      yield
    end
  end

  def snapshot_with(rows)
    project = Hive::Tui::Snapshot::ProjectView.new(
      name: "alpha", path: "/alpha", hive_state_path: "/alpha/.hive-state",
      error: nil, rows: rows.freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: nil, projects: [ project ])
  end

  def test_claude_launcher_wait_for_done_signal_handles_success_after_poll
    with_tmp_dir do |dir|
      task = Struct.new(:folder).new(dir)
      done = File.join(dir, ".done")
      calls = 0
      sleeps = []
      base = Time.utc(2026, 5, 25, 12, 0, 0)
      times = [ base, base, base ]
      original_exist = File.method(:exist?)

      with_replaced_singleton_method(Time, :now, -> { times.shift || base }) do
        with_replaced_singleton_method(File, :exist?, lambda { |path|
          if path == done
            calls += 1
            calls > 1
          else
            original_exist.call(path)
          end
        }) do
          with_replaced_singleton_method(Hive::ClaudeLauncher, :read_result_json_status, ->(_task) { :ok }) do
            with_replaced_singleton_method(Hive::ClaudeLauncher, :sleep, ->(seconds) { sleeps << seconds }) do
              result = Hive::ClaudeLauncher.wait_for_done_signal(task, nil, 5, "review")

              assert_equal({ status: :ok, log_label: "review" }, result)
              assert_equal [ 0.5 ], sleeps
            end
          end
        end
      end
    end
  end

  def test_stage_non_claude_dispatchers_use_generic_spawn_agent
    with_tmp_dir do |root|
      folder = task_folder(root)
      task = fake_task(root, folder)
      File.write(task.state_file, "")
      calls = []
      profile = FakeProfile.new(:codex)

      with_spawn_agent_capture(calls) do
        Hive::Stages::Artifacts.spawn_artifacts_agent(task, { "budget_usd" => {}, "timeout_sec" => {} }, "collect", profile)
        Hive::Stages::Finalize.spawn_finalize_agent(task, { "budget_usd" => {}, "timeout_sec" => {} }, "final", profile, root)
      end

      assert_equal 2, calls.length
      assert_equal %w[artifacts finalize], calls.map { |_task, kwargs| kwargs[:log_label] }
      assert_equal "error", Hive::Stages::Artifacts.action_for(:error)
      assert_equal "custom", Hive::Stages::Artifacts.action_for(:custom)
    end
  end

  def test_review_substages_use_generic_spawn_agent_for_non_claude_profiles
    with_tmp_dir do |root|
      folder = task_folder(root)
      File.write(File.join(folder, "reviews", "codex-ce-code-review-01.md"), "## Finding\n- [ ] fix this\n")
      ctx = review_ctx(root, folder)
      cfg = {
        "review" => {
          "browser_test" => { "enabled" => true, "agent" => "codex", "max_attempts" => 1, "prompt_template" => "browser_test_prompt.md.erb" },
          "triage" => { "agent" => "codex", "bias" => "courageous" },
          "ci" => { "agent" => "codex", "prompt_template" => "ci_fix_prompt.md.erb" }
        },
        "budget_usd" => {},
        "timeout_sec" => {}
      }
      calls = []

      with_fake_profile(FakeProfile.new(:codex)) do
        with_spawn_agent_capture(calls) do
          browser = Hive::Stages::Review::BrowserTest.run_attempt(cfg: cfg, ctx: ctx, attempt: 1)
          triage = Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx)
          ci = Hive::Stages::Review::CiFix.spawn_fix_agent(
            cfg: cfg,
            ctx: ctx,
            command: "bin/test",
            attempt: 1,
            max_attempts: 2,
            captured_output: "red"
          )

          assert_equal :passed, browser[:status]
          assert_equal :ok, triage.status
          assert_equal({ status: :ok }, ci)
        end
      end

      assert_equal [
        "review-browser-pass01-attempt01",
        "review-triage-pass01",
        "review-ci-fix-attempt01"
      ], calls.map { |_task, kwargs| kwargs[:log_label] }
    end
  end

  def test_review_fix_and_reviewer_shared_session_edge_paths
    with_tmp_dir do |root|
      folder = task_folder(root)
      ctx = review_ctx(root, folder)
      File.write(File.join(folder, "task.md"), "Task\n")
      calls = []

      with_fake_profile(FakeProfile.new(:codex)) do
        with_spawn_agent_capture(calls) do
          Hive::Stages::Review.spawn_fix_agent(
            fake_task(root, folder),
            { "review" => { "fix" => { "agent" => "codex", "prompt_template" => "fix_prompt.md.erb" } }, "budget_usd" => {}, "timeout_sec" => {} },
            ctx,
            accepted: [ "finding" ]
          )
        end
      end
      assert_equal "review-fix-pass01", calls.last.last[:log_label]

      spec = {
        "name" => "codex-ce-code-review",
        "output_basename" => "codex-ce-code-review",
        "agent" => "claude",
        "skill" => "ce-code-review",
        "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
        "max_attempts" => 1,
        "timeout_sec" => 30
      }
      handle = FakeHandle.new([])

      with_fake_profile(FakeProfile.new(:claude)) do
        result = Hive::Reviewers::Agent.new(spec, ctx, cfg: {}).run_in_session!(handle: handle)

        assert_equal :ok, result.status
        assert_equal 1, handle.calls.length
        assert_equal "review-codex-ce-code-review-pass01", handle.calls.first[:log_label]
      end
    end
  end

  def test_base_marker_and_spawn_defensive_branches
    with_tmp_dir do |root|
      folder = task_folder(root, stage: "2-brainstorm")
      task = fake_task(root, folder)
      task.stage_index = 2
      task.stage_name = "brainstorm"

      with_replaced_singleton_method(Hive::Events, :emit, ->(**_kwargs) { raise Errno::EACCES, "blocked" }) do
        assert_nil Hive::Stages::Base.emit_rescue_close(task, nil, "boom")
      end

      marker = Struct.new(:name, :attrs).new(:review_error, {})
      assert_equal "review_error", Hive::Stages::Base.marker_event_message(marker)

      error = assert_raises(Hive::AgentError) do
        Hive::Stages::Base.spawn_claude!(
          task,
          {},
          prompt: "prompt",
          max_budget_usd: 1,
          timeout_sec: 1,
          session_name: "session",
          profile: FakeProfile.new(:codex)
        )
      end
      assert_includes error.message, "only supports the claude profile"
    end
  end

  def test_review_run_maps_tmux_unavailable_agent_error
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      task = Hive::Task.new(folder)
      File.write(task.state_file, "")
      File.write(task.worktree_yml_path, { "path" => worktree }.to_yaml)

      with_replaced_singleton_method(Hive::Stages::Review, :canonical_worktree_root, ->(_task, _cfg) { root }) do
        with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { { "path" => worktree } }) do
          with_replaced_singleton_method(Hive::Worktree, :validate_pointer_path, ->(_path, _root) { true }) do
            with_replaced_singleton_method(Hive::Stages::Review, :reviewer_compare_ref, ->(_cfg, _ops) { "main" }) do
              with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**_kwargs) { raise Hive::AgentError, "tmux binary not runnable: tmux" }) do
                result = Hive::Stages::Review.run!(task, { "review" => {}, "claude" => { "mode" => "tmux" } })

                assert_equal({ commit: "review_error_tmux_unavailable", status: :review_error }, result)
                marker = Hive::Markers.current(task.state_file)
                assert_equal :review_error, marker.name
                assert_equal "tmux_unavailable", marker.attrs["reason"]
              end
            end
          end
        end
      end
    end
  end

  def test_review_helper_error_paths_return_structured_results
    with_tmp_dir do |root|
      folder = task_folder(root)
      ctx = review_ctx(root, folder)
      task = fake_task(root, folder)

      Hive::Stages::Review.instance_variable_set(:@open_phase_event, {
        task: task,
        slug: task.slug,
        label: "phase=ci pass=01",
        stage: "6-review"
      })
      with_replaced_singleton_method(Hive::Events, :emit, ->(**_kwargs) { raise Errno::EACCES, "blocked" }) do
        assert_nil Hive::Stages::Review.close_phase_event!
      end

      assert_equal :wall_clock_exceeded,
                   Hive::Stages::Review.run_reviewer_spec({}, ctx, { "name" => "late" }, nil,
                                                           started_at: Time.now - 10,
                                                           max_wall_clock_sec: 1)

      adapter = Struct.new(:output_path) do
        def run!(deadline: nil)
          raise Hive::AgentError, "quota exhausted"
        end
      end.new(File.join(folder, "reviews", "quota-01.md"))
      spec = { "name" => "quota" }
      with_replaced_singleton_method(Hive::Reviewers, :dispatch, ->(_spec, _ctx, cfg:) { adapter }) do
        result = Hive::Stages::Review.run_reviewer_spec({}, ctx, spec, nil)

        assert_equal :error, result.status
        assert_includes result.error_message, "quota exhausted"
      end
    end
  end

  def test_review_run_marks_auto_commit_failure_after_fix_agent_edit
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      task = Hive::Task.new(folder)
      File.write(task.state_file, "---\nslug: #{File.basename(folder)}\n---\n")
      File.write(task.worktree_yml_path, { "path" => worktree }.to_yaml)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      Hive::Markers.set(task.state_file, :review_waiting, pass: 1, escalations: 1)

      status_checks = [ :clean, :dirty ]
      with_replaced_singleton_method(Hive::Stages::Review, :canonical_worktree_root, ->(_task, _cfg) { root }) do
        with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { { "path" => worktree } }) do
          with_replaced_singleton_method(Hive::Worktree, :validate_pointer_path, ->(_path, _root) { true }) do
            with_replaced_singleton_method(Hive::Stages::Review, :reviewer_compare_ref, ->(_cfg, _ops) { "main" }) do
              with_replaced_singleton_method(Hive::Stages::Review, :git_head, ->(_path) { "head-before-fix" }) do
                with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { status_checks.shift }) do
                  with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(_task, _cfg, _ctx, accepted:) { { status: :ok } }) do
                    with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_fix_worktree, ->(_task, _cfg, _ctx, _accepted) {
                      { success: false, message: "git add -A failed: permission denied" }
                    }) do
                      result = Hive::Stages::Review.run!(task, { "review" => {} })

                      assert_equal :review_error, result[:status]
                      assert_equal "fix_auto_commit_failed_pass_01", result[:commit]
                    end
                  end
                end
              end
            end
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal :review_error, marker.name
      assert_equal "fix", marker.attrs["phase"]
      assert_equal "fix_auto_commit_failed", marker.attrs["reason"]
      assert_equal "git add -A failed: permission denied", marker.attrs["message"]
    end
  end

  def test_review_run_marks_status_check_failure_after_fix
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      task = Hive::Task.new(folder)
      File.write(task.state_file, "---\nslug: #{File.basename(folder)}\n---\n")
      File.write(task.worktree_yml_path, { "path" => worktree }.to_yaml)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      Hive::Markers.set(task.state_file, :review_waiting, pass: 1, escalations: 1)

      status_checks = [ :clean, [ :status_failed, "fatal: bad git" ] ]
      with_replaced_singleton_method(Hive::Stages::Review, :canonical_worktree_root, ->(_task, _cfg) { root }) do
        with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { { "path" => worktree } }) do
          with_replaced_singleton_method(Hive::Worktree, :validate_pointer_path, ->(_path, _root) { true }) do
            with_replaced_singleton_method(Hive::Stages::Review, :reviewer_compare_ref, ->(_cfg, _ops) { "main" }) do
              with_replaced_singleton_method(Hive::Stages::Review, :git_head, ->(_path) { "head-before-fix" }) do
                with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { status_checks.shift }) do
                  with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(_task, _cfg, _ctx, accepted:) { { status: :ok } }) do
                    result = Hive::Stages::Review.run!(task, { "review" => {} })

                    assert_equal :review_error, result[:status]
                    assert_equal "fix_status_check_failed_pass_01", result[:commit]
                  end
                end
              end
            end
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal :review_error, marker.name
      assert_equal "fix", marker.attrs["phase"]
      assert_equal "fix_status_check_failed", marker.attrs["reason"]
      assert_equal "fatal: bad git", marker.attrs["message"]
    end
  end

  def test_review_auto_commit_reports_git_add_and_commit_failures
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      fail_status = ReviewCommandStatus.new(false)
      ok_status = ReviewCommandStatus.new(true)

      with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "", fail_status ] }) do
        result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

        refute result[:success]
        assert_includes result[:message], "git add -A failed"
        assert_includes result[:message], "git reset HEAD -- failed"
      end

      responses = [
        [ "", "", ok_status ],
        [ "test/fix_test.rb\0", "", ok_status ],
        [ "", "", ok_status ]
      ]
      with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { responses.shift }) do
        with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, lambda { |_worktree, _policy, _message|
          { success: false, message: "git commit failed: stderr detail\nstdout detail" }
        }) do
          result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

          refute result[:success]
          assert_equal "git commit failed: stderr detail\nstdout detail", result[:message]
          assert_nil result[:reason]
        end
      end
    end
  end

  def test_review_auto_commit_resets_staged_changes_when_commit_fails
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      fail_status = ReviewCommandStatus.new(false)
      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []
      responses = [
        [ "", "", ok_status ],
        [ "test/fix_test.rb\0", "", ok_status ],
        [ "", "", ok_status ]
      ]
      with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
        captured_argv << argv
        responses.shift
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, lambda { |_worktree, _policy, _message|
          { success: false, message: "git commit failed: commit boom" }
        }) do
          result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

          refute result[:success]
          assert_includes result[:message], "git commit failed"
        end
      end

      assert_equal 3, captured_argv.length
      assert_equal [ "git", "-C", worktree, "reset" ], captured_argv[2].first(4)
    end
  end

  def test_review_auto_commit_appends_reset_error_when_unstage_fails
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      fail_status = ReviewCommandStatus.new(false)
      ok_status = ReviewCommandStatus.new(true)
      responses = [
        [ "", "", ok_status ],
        [ "test/fix_test.rb\0", "", ok_status ],
        [ "", "reset boom", fail_status ]
      ]
      with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { responses.shift }) do
        with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, lambda { |_worktree, _policy, _message|
          { success: false, message: "git commit failed: commit boom" }
        }) do
          result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

          refute result[:success]
          assert_includes result[:message], "git commit failed"
          assert_includes result[:message], "git reset HEAD -- failed"
        end
      end
    end
  end

  def test_fix_auto_commit_message_uses_collected_finding_count
    with_tmp_dir do |root|
      folder = task_folder(root)
      ctx = review_ctx(root, folder)
      task = fake_task(root, folder)
      cfg = { "review" => {} }
      accepted = accepted_findings("source one\nsource two\n", count: 2)

      message = Hive::Stages::Review.send(:fix_auto_commit_message, task, cfg, ctx, accepted)

      assert_includes message, "Hive-Fix-Findings: 2"
    end
  end

  def test_review_auto_commit_rejects_staged_paths_outside_scope
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []
      responses = [
        [ "", "", ok_status ],
        [ "bin/pwn\0test/fix_test.rb\0", "", ok_status ],
        [ "", "", ok_status ]
      ]

      with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
        captured_argv << argv
        responses.shift
      }) do
        result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

        refute result[:success]
        assert_includes result[:message], "auto-commit scope check failed"
        assert_includes result[:message], "bin/pwn"
        assert_equal "fix_auto_commit_scope_failed", result[:reason]
        assert_equal "reviews/auto-commit-scope-01.md", result[:files]
        assert_includes File.read(File.join(folder, result[:files])), "bin/pwn"
        assert captured_argv.none? { |argv| argv.include?("commit") }
        assert_equal [ "git", "-C", worktree, "reset" ], captured_argv.last.first(4)
      end
    end
  end

  def test_review_auto_commit_reports_staged_path_scan_failures
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      fail_status = ReviewCommandStatus.new(false)
      ok_status = ReviewCommandStatus.new(true)
      responses = [
        [ "", "", ok_status ],
        [ "", "diff boom", fail_status ],
        [ "", "", ok_status ]
      ]

      with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { responses.shift }) do
        result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

        refute result[:success]
        assert_equal "git diff --cached --name-only failed: diff boom", result[:message]
      end
    end
  end

  def test_review_auto_commit_can_disable_scope_check
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = {
        "review" => {
          "fix" => {
            "auto_commit" => { "scope_check" => { "enabled" => false } }
          }
        }
      }

      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []
      responses = [
        [ "", "", ok_status ],
        [ "", "", ok_status ]
      ]

      with_replaced_singleton_method(Hive::Stages::Review, :git_head, ->(_path) { "head-after" }) do
        with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, ->(_worktree, _policy, _message) { { success: true } }) do
          with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
            captured_argv << argv
            responses.shift
          }) do
            result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

            assert result[:success]
            assert_equal "head-after", result[:head]
            refute captured_argv.any? { |argv| argv.include?("diff") }
          end
        end
      end
    end
  end

  def test_review_auto_commit_inherits_gpgsign_by_default
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => {} }

      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []
      responses = [
        [ "", "", ok_status ],
        [ "test/fix_test.rb\0", "", ok_status ],
        [ "head-after-auto-commit\n", "", ok_status ]
      ]
      commit_calls = []

      with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, lambda { |commit_worktree, policy, message|
        commit_calls << [ commit_worktree, policy, message ]
        { success: true }
      }) do
        with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
          captured_argv << argv
          responses.shift
        }) do
          result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

          assert result[:success]
          assert_equal "head-after-auto-commit", result[:head]
        end
      end

      assert_equal worktree, commit_calls.fetch(0).fetch(0)
      assert_equal "inherit", commit_calls.fetch(0).fetch(1)
      commit_argv = Hive::Stages::Review.send(:auto_commit_git_commit_argv, worktree, "inherit", "message")
      assert_equal [ "git", "-C", worktree, "commit" ], commit_argv.first(4)
      refute_includes commit_argv, "commit.gpgsign=false"
    end
  end

  def test_review_auto_commit_bypass_sign_policy_forces_unsigned_commit
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => { "fix" => { "auto_commit" => { "sign_policy" => "bypass" } } } }

      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []
      responses = [
        [ "", "", ok_status ],
        [ "test/fix_test.rb\0", "", ok_status ],
        [ "head-after-auto-commit\n", "", ok_status ]
      ]
      commit_calls = []

      with_replaced_singleton_method(Hive::Stages::Review, :auto_commit_git_commit, lambda { |commit_worktree, policy, message|
        commit_calls << [ commit_worktree, policy, message ]
        { success: true }
      }) do
        with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
          captured_argv << argv
          responses.shift
        }) do
          result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

          assert result[:success]
        end
      end

      assert_equal worktree, commit_calls.fetch(0).fetch(0)
      assert_equal "bypass", commit_calls.fetch(0).fetch(1)
      commit_argv = Hive::Stages::Review.send(:auto_commit_git_commit_argv, worktree, "bypass", "message")
      assert_equal [ "git", "-C", worktree, "-c", "commit.gpgsign=false", "commit" ], commit_argv.first(6)
    end
  end

  def test_auto_commit_sign_policy_for_rejects_unknown_hand_built_policy
    cfg = { "review" => { "fix" => { "auto_commit" => { "sign_policy" => "always" } } } }

    err = assert_raises(Hive::ConfigError) do
      Hive::Stages::Review.send(:auto_commit_sign_policy_for, cfg)
    end

    assert_match(/sign_policy.*must be one of/, err.message)
  end

  def test_run_git_with_timeout_kills_process_group_on_timeout
    calls = []
    clock_values = [ 0.0, 2.0 ]

    with_replaced_singleton_method(Process, :spawn, lambda { |*argv, **kwargs|
      calls << [ :spawn, argv, kwargs ]
      12_345
    }) do
      with_replaced_singleton_method(Process, :clock_gettime, ->(_clock) { clock_values.shift || 2.0 }) do
        with_replaced_singleton_method(Process, :kill, lambda { |signal, target|
          calls << [ :kill, signal, target ]
          1
        }) do
          with_replaced_singleton_method(Process, :waitpid, lambda { |pid|
            calls << [ :waitpid, pid ]
            pid
          }) do
            success, err, timed_out = Hive::GitOps.new("/tmp/worktree").run_git_with_timeout(
              [ "git", "status" ],
              timeout_sec: 1
            )

            refute success
            assert_empty err
            assert timed_out
          end
        end
      end
    end

    spawn_call = calls.find { |call| call.first == :spawn }
    assert_equal true, spawn_call.fetch(2).fetch(:pgroup)
    assert_includes calls, [ :kill, "TERM", -12_345 ]
    assert_includes calls, [ :kill, "KILL", -12_345 ]
    assert_includes calls, [ :waitpid, 12_345 ]
  end

  def test_timed_git_cleanup_falls_back_to_parent_pid_when_group_is_gone
    ops = Hive::GitOps.new("/tmp/worktree")
    ops.define_singleton_method(:sleep) { |_seconds| nil }
    calls = []

    with_replaced_singleton_method(Process, :kill, lambda { |signal, target|
      calls << [ signal, target ]
      raise Errno::ESRCH if target.negative?

      1
    }) do
      with_replaced_singleton_method(Process, :waitpid, ->(pid) { calls << [ "waitpid", pid ]; pid }) do
        ops.send(:terminate_timed_out_git_process, 12_345)
      end
    end

    assert_includes calls, [ "TERM", -12_345 ]
    assert_includes calls, [ "TERM", 12_345 ]
    assert_includes calls, [ "KILL", -12_345 ]
    assert_includes calls, [ "KILL", 12_345 ]
    assert_includes calls, [ "waitpid", 12_345 ]
  end

  def test_auto_commit_git_commit_uses_bounded_git_helper
    worktree = "/tmp/hive-worktree"
    captured = {}
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git_with_timeout) do |argv, timeout_sec:|
      captured[:argv] = argv
      captured[:timeout_sec] = timeout_sec
      [ true, "", false ]
    end

    with_replaced_singleton_method(Hive::GitOps, :new, lambda { |path|
      captured[:worktree_path] = path
      fake_ops
    }) do
      result = Hive::Stages::Review.send(:auto_commit_git_commit, worktree, "inherit", "commit message")

      assert result[:success]
    end

    assert_equal worktree, captured.fetch(:worktree_path)
    assert_equal [ "git", "-C", worktree, "commit", "-m", "commit message" ], captured.fetch(:argv)
    assert_equal Hive::Stages::Review::AUTO_COMMIT_OP_TIMEOUT_SEC, captured.fetch(:timeout_sec)
  end

  def test_auto_commit_git_commit_reports_timeout
    captured = {}
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git_with_timeout) do |_argv, timeout_sec:|
      captured[:timeout_sec] = timeout_sec
      [ false, "", true ]
    end

    with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { fake_ops }) do
      result = Hive::Stages::Review.send(:auto_commit_git_commit, "/tmp/worktree", "inherit", "message")

      refute result[:success]
      assert result[:timed_out]
      assert_includes result[:message], "timed out after"
      assert_includes result[:message], "signing or commit hooks"
    end

    assert_equal Hive::Stages::Review::AUTO_COMMIT_OP_TIMEOUT_SEC, captured.fetch(:timeout_sec)
  end

  def test_auto_commit_git_commit_reports_non_timeout_failure
    captured = {}
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git_with_timeout) do |_argv, timeout_sec:|
      captured[:timeout_sec] = timeout_sec
      [ false, "fatal: commit failed", false ]
    end

    with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { fake_ops }) do
      result = Hive::Stages::Review.send(:auto_commit_git_commit, "/tmp/worktree", "inherit", "message")

      refute result[:success]
      refute result[:timed_out]
      assert_equal "git commit failed: fatal: commit failed", result[:message]
    end

    assert_equal Hive::Stages::Review::AUTO_COMMIT_OP_TIMEOUT_SEC, captured.fetch(:timeout_sec)
  end

  def test_auto_commit_commit_failure_reason_marks_only_signing_shaped_inherited_failures
    generic_reason = Hive::Stages::Review.send(
      :auto_commit_commit_failure_reason,
      "inherit",
      { success: false, message: "git commit failed: pre-commit hook declined" }
    )
    assert_nil generic_reason

    signing_reason = Hive::Stages::Review.send(
      :auto_commit_commit_failure_reason,
      "inherit",
      { success: false, message: "git commit failed: gpg failed to sign the data" }
    )
    assert_equal "fix_auto_commit_signing_failed", signing_reason

    timeout_reason = Hive::Stages::Review.send(
      :auto_commit_commit_failure_reason,
      "bypass",
      { success: false, message: "git commit timed out", timed_out: true }
    )
    assert_equal "fix_auto_commit_signing_failed", timeout_reason

    assert_nil Hive::Stages::Review.send(
      :auto_commit_commit_failure_reason,
      "bypass",
      { success: false, message: "git commit failed" }
    )
  end

  def test_review_auto_commit_fail_sign_policy_rejects_signed_repos_before_staging
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => { "fix" => { "auto_commit" => { "sign_policy" => "fail" } } } }

      ok_status = ReviewCommandStatus.new(true)
      captured_argv = []

      with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
        captured_argv << argv
        [ "true\n", "", ok_status ]
      }) do
        result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

        refute result[:success]
        assert_equal "fix_auto_commit_sign_policy_failed", result[:reason]
        assert_includes result[:message], "auto-commit signing policy failed"
        assert_includes result[:message], "commit.gpgsign is enabled"
        assert_includes result[:message], "changes remain unstaged"
      end

      assert_equal 1, captured_argv.length
      assert_equal [ "git", "-C", worktree, "config", "--bool", "--get", "commit.gpgsign" ], captured_argv[0]
    end
  end

  def test_review_auto_commit_fail_sign_policy_reports_config_errors
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      task = fake_task(root, folder, worktree: worktree)
      ctx = review_ctx(worktree, folder)
      cfg = { "review" => { "fix" => { "auto_commit" => { "sign_policy" => "fail" } } } }

      fail_status = ReviewCommandStatus.new(false)

      with_replaced_singleton_method(Open3, :capture3, ->(*_argv) { [ "", "fatal: bad config", fail_status ] }) do
        result = Hive::Stages::Review.send(:auto_commit_fix_worktree, task, cfg, ctx, accepted_findings)

        refute result[:success]
        assert_equal "fix_auto_commit_sign_policy_failed", result[:reason]
        assert_includes result[:message], "git config --bool --get commit.gpgsign failed: fatal: bad config"
        assert_includes result[:message], "Commit or revert those changes manually"
      end
    end
  end

  def test_auto_commit_scope_violations_cover_invalid_denied_and_outside_paths
    cfg = {
      "review" => {
        "fix" => {
          "auto_commit" => {
            "scope_check" => {
              "allowed_paths" => [ "test/**" ],
              "denied_paths" => [ "bin/**" ]
            }
          }
        }
      }
    }

    backslash_path = "test" + "\\" + "payload"
    violations = Hive::Stages::Review.send(
      :auto_commit_scope_violations,
      cfg,
      [ "/abs", backslash_path, "bin/pwn", "README.md", "test/nested/fix_test.rb" ]
    )

    assert_equal [ "/abs", backslash_path, "bin/pwn", "README.md" ], violations.map(&:path)
    assert_includes violations[0].reason, "invalid staged path"
    assert_includes violations[1].reason, "invalid staged path"
    assert_includes violations[2].reason, "denied path pattern"
    assert_includes violations[3].reason, "outside review.fix.auto_commit.scope_check.allowed_paths"

    message = Hive::Stages::Review.send(:auto_commit_scope_failure_message, violations * 2)
    assert_includes message, "and 3 more"
  end

  def test_auto_commit_scope_defaults_block_nested_env_and_lockfiles
    cfg = { "review" => {} }

    violations = Hive::Stages::Review.send(
      :auto_commit_scope_violations,
      cfg,
      [ "app/.env.local", "services/api/package-lock.json", "app/models/user.rb" ]
    )

    assert_equal [ "app/.env.local", "services/api/package-lock.json" ], violations.map(&:path)
    assert_includes violations[0].reason, "denied path pattern"
    assert_includes violations[1].reason, "denied path pattern"
  end

  def test_staged_auto_commit_paths_include_both_sides_of_denied_rename
    with_tmp_dir do |root|
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(File.join(worktree, "config"))
      run!("git", "-C", worktree, "init", "-b", "main", "--quiet")
      run!("git", "-C", worktree, "config", "user.email", "test@example.com")
      run!("git", "-C", worktree, "config", "user.name", "Test")
      File.write(File.join(worktree, "config", "secret.yml"), "secret: nope\n")
      run!("git", "-C", worktree, "add", ".")
      run!("git", "-C", worktree, "commit", "-m", "init", "--quiet")
      FileUtils.mkdir_p(File.join(worktree, "docs"))
      FileUtils.mv(File.join(worktree, "config", "secret.yml"), File.join(worktree, "docs", "secret.yml"))
      run!("git", "-C", worktree, "add", "-A")

      result = Hive::Stages::Review.send(:staged_auto_commit_paths, worktree)

      assert result[:success]
      assert_includes result[:paths], "config/secret.yml"
      assert_includes result[:paths], "docs/secret.yml"
      violations = Hive::Stages::Review.send(:auto_commit_scope_violations, { "review" => {} }, result[:paths])
      assert_includes violations.map(&:path), "config/secret.yml"
    end
  end

  def test_fix_auto_commit_message_sanitizes_trailer_newlines
    with_tmp_dir do |root|
      folder = task_folder(root)
      ctx = review_ctx(root, folder)
      task = fake_task(root, folder)
      cfg = { "review" => {} }

      with_replaced_singleton_method(Hive::Stages::Review, :triage_bias_for, ->(_cfg) { "courageous\nHive-Forged: yes" }) do
        with_replaced_singleton_method(Hive::Stages::Review, :reviewer_sources_for, ->(_ctx) { "alpha\nHive-Forged: beta" }) do
          message = Hive::Stages::Review.send(:fix_auto_commit_message, task, cfg, ctx, accepted_findings)

          assert_equal 1, message.scan(/^Hive-Triage-Bias:/).length
          assert_equal 1, message.scan(/^Hive-Reviewer-Sources:/).length
          assert_equal 0, message.scan(/^Hive-Forged:/).length
          bias_line = message.lines.find { |l| l.start_with?("Hive-Triage-Bias:") }
          sources_line = message.lines.find { |l| l.start_with?("Hive-Reviewer-Sources:") }
          refute_includes bias_line.chomp, "\n"
          refute_includes sources_line.chomp, "\n"
          assert_includes bias_line, "courageous Hive-Forged: yes"
          assert_includes sources_line, "alpha Hive-Forged: beta"
        end
      end
    end
  end

  def test_review_run_marks_status_check_failure_before_fix
    with_tmp_dir do |root|
      folder = task_folder(root)
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p(worktree)
      task = Hive::Task.new(folder)
      File.write(task.state_file, "---\nslug: #{File.basename(folder)}\n---\n")
      File.write(task.worktree_yml_path, { "path" => worktree }.to_yaml)
      File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
      Hive::Markers.set(task.state_file, :review_waiting, pass: 1, escalations: 1)

      fail_status = ReviewCommandStatus.new(false)
      with_replaced_singleton_method(Hive::Stages::Review, :canonical_worktree_root, ->(_task, _cfg) { root }) do
        with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { { "path" => worktree } }) do
          with_replaced_singleton_method(Hive::Worktree, :validate_pointer_path, ->(_path, _root) { true }) do
            with_replaced_singleton_method(Hive::Stages::Review, :reviewer_compare_ref, ->(_cfg, _ops) { "main" }) do
              with_replaced_singleton_method(Open3, :capture3, ->(*argv) {
                if argv.include?("status") && argv.include?("--porcelain")
                  [ "", "fatal: not a git repository", fail_status ]
                else
                  [ "", "", ReviewCommandStatus.new(true) ]
                end
              }) do
                result = Hive::Stages::Review.run!(task, { "review" => {} })

                assert_equal :review_error, result[:status]
                assert_equal "fix_status_check_failed_pass_01", result[:commit]
              end
            end
          end
        end
      end

      marker = Hive::Markers.current(task.state_file)
      assert_equal :review_error, marker.name
      assert_equal "fix_status_check_failed", marker.attrs["reason"]
      assert_includes marker.attrs["message"], "fatal: not a git repository"
    end
  end

  def test_tui_update_scroll_and_token_stats_edge_branches
    model = Hive::Tui::Model.initial(cols: 100, rows: 24)
    red_state = Hive::Tui::Model::RedStatusDetailState.new(
      row: row,
      log_lines: (1..20).map { |i| "line-#{i}" },
      log_scroll_offset: 0
    )

    skipped, = Hive::Tui::Update.apply(model, Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 1))
    assert_same model, skipped

    state_nil = model.with(red_status_detail_state: nil)
    assert_equal 0, Hive::Tui::Update.red_status_detail_log_capacity(state_nil)

    crowded = model.with(
      mode: :red_status_detail,
      rows: 6,
      red_status_detail_state: red_state
    )
    assert_equal 0, Hive::Tui::Update.red_status_detail_log_capacity(crowded)
    unchanged, = Hive::Tui::Update.apply(crowded, Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :up, amount: 1))
    assert_same crowded, unchanged

    unknown, = Hive::Tui::Update.apply(
      model.with(mode: :red_status_detail, red_status_detail_state: red_state.with(log_scroll_offset: 2)),
      Hive::Tui::Messages::RedStatusDetailScroll.new(direction: :sideways, amount: 1)
    )
    assert_equal 2, unknown.red_status_detail_state.log_scroll_offset

    assert_same model, Hive::Tui::Update.apply(model, Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :sideways)).first

    token_all = model.with(mode: :token_stats, token_stats_state: Hive::Tui::Model::TokenStatsState.new(scope_level: :all))
    assert_equal :all, Hive::Tui::Update.apply(token_all, Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :sideways)).first.token_stats_state.scope_level
    assert_equal :all, Hive::Tui::Update.apply(token_all, Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :out)).first.token_stats_state.scope_level
    assert_equal :all, Hive::Tui::Update.apply(token_all, Hive::Tui::Messages::TokenStatsSelectionMoved.new(direction: :next)).first.token_stats_state.scope_level

    token_task = model.with(mode: :token_stats, token_stats_state: Hive::Tui::Model::TokenStatsState.new(scope_level: :task, project_slug: "alpha", task_slug: "one"))
    assert_equal :task, Hive::Tui::Update.apply(token_task, Hive::Tui::Messages::TokenStatsScopeChanged.new(direction: :in)).first.token_stats_state.scope_level
  end

  def test_bubble_model_token_stats_and_log_edge_branches
    dispatch = ->(_message) { }
    selected_row = row(slug: "task-one")
    bubble = Hive::Tui::BubbleModel.new(
      hive_model: Hive::Tui::Model.initial.with(
        snapshot: snapshot_with([ selected_row ]),
        cursor: [ 0, 0 ],
        pane_focus: :left,
        scope: 1
      ),
      dispatch: dispatch
    )

    project_state = bubble.send(:token_stats_state_for_current_scope)
    assert_equal :project, project_state.scope_level
    assert_equal({ project_slug: "alpha" }, bubble.send(:token_stats_scope, project_state))

    all_bubble = Hive::Tui::BubbleModel.new(hive_model: Hive::Tui::Model.initial.with(snapshot: nil), dispatch: dispatch)
    all_state = all_bubble.send(:token_stats_state_for_current_scope)
    assert_equal :all, all_state.scope_level
    assert_equal({}, all_bubble.send(:token_stats_scope, all_state))
    assert_nil all_bubble.send(:frontmatter_scalar, "---\nname: demo\n---\n", "created_at")

    with_tmp_dir do |root|
      folder = task_folder(root, stage: "4-execute", slug: "log-task")
      log_dir = File.join(root, ".hive-state", "logs", "log-task")
      FileUtils.mkdir_p(log_dir)
      log_path = File.join(log_dir, "execute-test.log")
      File.write(log_path, "hello\n")
      log_row = row(stage: "4-execute", slug: "log-task", folder: folder)

      with_replaced_singleton_method(File, :mtime, ->(_path) { raise Errno::ENOENT, "gone" }) do
        assert_equal log_path, bubble.send(:latest_log_matching, log_row) { true }
      end

      with_replaced_singleton_method(Dir, :glob, ->(_pattern) { raise Errno::EACCES, "blocked" }) do
        assert_nil bubble.send(:latest_log_matching, log_row) { true }
      end

      invalid_row = row(folder: File.join(root, "not-a-task"))
      assert_nil bubble.send(:task_log_dir_for, invalid_row)

      with_replaced_singleton_method(bubble, :read_capped, ->(_path) { raise Errno::EACCES, "blocked" }) do
        assert_nil bubble.send(:stage_extra_for, row(stage: "2-brainstorm", folder: folder))
      end

      fake_file = Object.new
      fake_file.define_singleton_method(:seek) { |_offset, _whence| raise Errno::EINVAL, "short" }
      fake_file.define_singleton_method(:rewind) { raise Errno::ESPIPE, "pipe" }
      original_open = File.method(:open)
      with_replaced_singleton_method(File, :open, lambda { |path, *args, &block|
        path == log_path ? block.call(fake_file) : original_open.call(path, *args, &block)
      }) do
        assert_nil bubble.send(:tail_capped, log_path)
      end

      with_replaced_singleton_method(File, :open, lambda { |path, *_args, &_block|
        raise Errno::ENXIO, "blocked" if path == log_path
      }) do
        assert_nil bubble.send(:tail_capped, log_path)
      end
    end
  end

  def test_tui_view_edge_branches
    artifact_row = row(diagnostic: { "artifact_paths" => %w[a b c d e f] })
    assert_equal 8, Hive::Tui::RedStatusDetailLayout.artifact_row_count(artifact_row)

    assert_equal "status…\e[0m", Hive::Tui::Views::IdeaPreview.with_ellipsis("status  \e[0m")
    assert_equal "already…\e[0m", Hive::Tui::Views::IdeaPreview.with_ellipsis("already…\e[0m")

    state = Hive::Tui::Model::InfoPanelState.new(
      slug: "done",
      stage: "8-finalize",
      created_at: nil,
      original_text: "text",
      folder_path: "/tmp/task",
      latest_log_path: nil,
      stage_extra: "details"
    )
    assert_equal "details", Hive::Tui::Views::IdeaPreview.extra_title(state)

    header = Hive::Tui::Views::RedStatusDetail.header_line("RED · ", "alpha/6-review", "slug", "/tmp/path", 3)
    assert_operator header.length, :<=, 3
  end
end
