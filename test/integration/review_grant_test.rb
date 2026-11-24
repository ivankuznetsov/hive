require "test_helper"
require "hive/cli"
require "hive/commands/review_grant"
require "hive/commands/status"
require "hive/commands/run"
require_relative "../support/review_grant_fixture"

class ReviewGrantIntegrationTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def test_operator_status_to_fresh_runner_fixes_preserved_findings_and_verifies_exact_head
    with_review_grant_task do |task, cfg|
      neighbor = File.join(File.dirname(task.folder), "neighbor-261030-abcd")
      FileUtils.mkdir_p(File.join(neighbor, "reviews"))
      ensure_test_task_identity(neighbor)
      File.write(File.join(neighbor, "task.md"), "# Neighbor\n<!-- REVIEW_STALE reason=wall_clock pass=4 -->\n")
      File.write(File.join(neighbor, "reviews", "codex-04.md"), "- [x] Neighbor finding\n")
      neighbor_before = Dir[File.join(neighbor, "**", "*")].select { |p| File.file?(p) }.to_h { |p| [ p, File.binread(p) ] }
      project = { "name" => task.project_name, "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      before_status = Hive::Commands::Status.new.operational_payload([ project ])
      row = before_status.fetch("tasks").find { |entry| entry.dig("identity", "slug") == task.slug }
      token = row.fetch("review_grant").fetch("evidence_token")
      capture_io do
        Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: 1, reason: "Finish the accepted fix and verify it", evidence_token: token).call
      end
      previous_head = Hive::Stages::Review.git_head(task.worktree_path)
      fixes = []
      reviews = []
      git_command = method(:run!)
      clean_review = lambda do |_cfg, ctx, _task, **|
        reviews << [ ctx.pass, Hive::Stages::Review.git_head(ctx.worktree_path) ]
        File.write(File.join(ctx.task_folder, "reviews", "codex-#{format('%02d', ctx.pass)}.md"), "## High\nNo findings.\n")
        :ok
      end
      triage = lambda do |cfg:, ctx:|
        path = File.join(ctx.task_folder, "reviews", "escalations-#{format('%02d', ctx.pass)}.md")
        File.write(path, "# Escalations\n")
        Hive::Stages::Review::Triage::Result.new(status: :ok, escalations_path: path,
          error_message: nil, tampered_files: [], limit_text: nil)
      end
      fix = lambda do |_task, _cfg, ctx, accepted:, agent_custody:, **|
        fixes << [ ctx.pass, accepted ]
        agent_custody.call do
          File.write(File.join(ctx.worktree_path, "accepted-fix.txt"), "fixed\n")
          git_command.call("git", "-C", ctx.worktree_path, "add", "accepted-fix.txt")
          git_command.call("git", "-C", ctx.worktree_path, "commit", "--quiet", "-m", "Apply accepted finding")
          { status: :ok }
        end
      end
      with_replaced_singleton_method(Hive::Stages::Review, :run_reviewers, clean_review) do
        with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, triage) do
          with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, fix) do
            capture_io { Hive::Commands::Run.new(task.folder).call }
          end
        end
      end
      assert_equal [ 4 ], fixes.map(&:first)
      assert_includes fixes.first.last, "Preserve this exact accepted finding"
      current_head = Hive::Stages::Review.git_head(task.worktree_path)
      refute_equal previous_head, current_head
      assert_equal [ [ 5, current_head ] ], reviews
      assert_equal :review_complete, Hive::Markers.current(task.state_file).name
      budget = Hive::ReviewBudget.new(task: Hive::Task.new(task.folder), project: task.project_name)
      current = budget.observe
      assert_equal "completed", current.state
      assert_equal [ 1, 1, 0 ], [ current.granted, current.spent, current.remaining ]
      assert_equal current_head, current.completions.first.fetch("head")
      assert_equal neighbor_before, neighbor_before.keys.to_h { |p| [ p, File.binread(p) ] }
      after = Hive::Commands::Status.new.operational_payload([ project ]).fetch("tasks").find { |entry| entry.dig("identity", "slug") == task.slug }
      assert_equal "completed", after.fetch("review_grant").fetch("state")
      refute after.fetch("review_grant").key?("evidence_token")
      assert File.file?(budget.audit_path)
    end
  end

  # The uk-new-companies wedge, end to end: the hosted gate parked a granted
  # review on a base conflict, the operator merged the base as
  # reviews/ci-blocked.md instructs, and a routine retry must restart CI and
  # review on the merged head exactly once, without the stale grant.
  def test_base_merge_after_a_granted_base_conflict_restarts_one_fresh_review
    with_base_merge_grant_task do |task, approved|
      ci_dir = Dir.mktmpdir("base-merge-ci")
      ci_log = File.join(ci_dir, "ci-heads.log")
      ci_script = File.join(ci_dir, "record-ci-head.sh")
      File.write(ci_script, "git rev-parse HEAD >> #{Shellwords.escape(ci_log)}\n")
      config_path = File.join(task.hive_state_path, "config.yml")
      config = YAML.safe_load(File.read(config_path))
      config["review"]["ci"]["command"] = [ "sh", ci_script ]
      File.write(config_path, config.to_yaml)
      merged = merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      marker = Hive::Markers.current(task.state_file)
      row = { project: task.project_name, slug: task.slug, folder: task.folder,
        state_file: task.state_file, stage: "6-review", workflow: "coding",
        marker: marker.name.to_s, marker_attrs: marker.attrs,
        state_file_mtime: Time.now.utc - 3600, live_task_lock: false }
      generation = Struct.new(:task_generation, :progress_token).new("a" * 64, "b" * 64)
      coordinator = Hive::Daemon::RecoveryCoordinator.new(task_resolver: ->(**) { task },
        safety: ->(_) { [ true, "safe" ] }, generation_resolver: ->(*, **) { generation })
      admitted = coordinator.request(row: row, requestor: "cli")
      request = coordinator.instance_variable_get(:@request_queue).fetch(admitted.request_id)
      assert_equal "cleared", coordinator.resume(request: request, row: row).phase
      assert_equal "cleared", coordinator.resume(request: request, row: row).phase

      reviews = []
      fixes = []
      clean_review = lambda do |_cfg, ctx, _task, **|
        reviews << [ ctx.pass, Hive::Stages::Review.git_head(ctx.worktree_path) ]
        File.write(File.join(ctx.task_folder, "reviews", "codex-#{format('%02d', ctx.pass)}.md"), "## High\nNo findings.\n")
        :ok
      end
      triage = lambda do |cfg:, ctx:|
        path = File.join(ctx.task_folder, "reviews", "escalations-#{format('%02d', ctx.pass)}.md")
        File.write(path, "# Escalations\n")
        Hive::Stages::Review::Triage::Result.new(status: :ok, escalations_path: path,
          error_message: nil, tampered_files: [], limit_text: nil)
      end
      fix = lambda do |_task, _cfg, ctx, **|
        fixes << ctx.pass
        { status: :ok }
      end
      2.times do
        with_replaced_singleton_method(Hive::Stages::Review, :run_reviewers, clean_review) do
          with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, triage) do
            with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, fix) do
              capture_io { Hive::Commands::Run.new(task.folder).call }
            end
          end
        end
      end

      assert_equal [ [ 1, merged ] ], reviews, "one fresh review, of the merged head, from pass 1"
      ci_heads = File.readlines(ci_log, chomp: true)
      refute_empty ci_heads, "CI runs again after the retry"
      assert_equal [ merged ], ci_heads.uniq, "CI runs only on the merged head"
      assert_empty fixes, "the expired grant admits no fix pass"
      assert_equal :review_complete, Hive::Markers.current(task.state_file).name
      assert_equal merged, Hive::Stages::Review.git_head(task.worktree_path)
      budget = Hive::ReviewBudget.new(task: Hive::Task.new(task.folder), project: task.project_name)
      refute budget.present?
      audit = File.readlines(budget.audit_path).map { |line| JSON.parse(line) }
      assert_equal [ %w[grant], %w[expiry base_merge_adopted] ],
                   audit.map { |entry| [ entry.fetch("event"), entry["expiry_reason"] ].compact }
      archives = Dir[File.join(task.folder, "reviews", "archive", "*")]
      assert_equal 1, archives.size
      assert File.file?(File.join(archives.first, "codex-04.md")), "the stale accepted finding is archived, not reused"
      assert_empty Dir[File.join(task.folder, "reviews", "review-completion-*.json")]
    ensure
      FileUtils.rm_rf(ci_dir) if ci_dir
    end
  end

  def test_managed_process_with_valid_fresh_token_cannot_grant_or_mutate_task
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      before = File.binread(task.state_file)
      script = <<~RUBY
        require "hive"
        require "hive/cli"
        begin
          Hive::CLI.start(ARGV)
        rescue Hive::Error => error
          exit error.exit_code
        end
      RUBY
      output, _error, status = Open3.capture3(Hive::AgentSupport::OperatorAuthority.launch_environment,
        RbConfig.ruby, "-Ilib", "-e", script, "--", "review-grant", task.folder,
        "--project", task.project_name, "--passes", "3", "--reason", "Requesting more fixes",
        "--evidence-token", token, "--json")
      refute status.success?
      assert_equal "agent_denied", JSON.parse(output).fetch("error_kind")
      assert_equal before, File.binread(task.state_file)
      refute budget.present?
      refute File.exist?(budget.audit_path)
    end
  end

  def test_interrupted_operator_decision_reconciles_and_suspended_restart_preserves_only_unchanged_evidence
    with_review_grant_task do |task, _cfg|
      project = { "name" => task.project_name, "path" => task.project_root, "hive_state_path" => task.hive_state_path }
      status_row = lambda do
        Hive::Commands::Status.new.operational_payload([ project ]).fetch("tasks")
          .find { |entry| entry.dig("identity", "slug") == task.slug }
      end
      token = status_row.call.fetch("review_grant").fetch("evidence_token")
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      budget.define_singleton_method(:reconcile_audit!) { |_receipt| raise IOError, "interrupted after durable receipt" }
      with_replaced_singleton_method(Hive::ReviewBudget, :new, ->(**) { budget }) do
        assert_raises(Hive::InternalError) do
          capture_io do
            Hive::CLI.start([ "review-grant", task.folder, "--project", task.project_name,
              "--passes", "2", "--reason", "Finish accepted fixes", "--evidence-token", token, "--json" ])
          end
        end
      end
      assert_equal "pending", status_row.call.fetch("review_grant").fetch("state")
      refute File.exist?(budget.audit_path)
      output, = capture_io do
        Hive::CLI.start([ "review-grant", task.folder, "--project", task.project_name,
          "--passes", "2", "--reason", "Finish accepted fixes", "--evidence-token", token, "--json" ])
      end
      assert_equal "replayed", JSON.parse(output).fetch("state")
      assert_equal 1, File.readlines(budget.audit_path).size
      Hive::Markers.set(task.state_file, :review_error, reason: "provider_error", phase: "fix", pass: 4)
      suspended = status_row.call
      assert_nil suspended.dig("recovery", "request_id")
      assert_equal "unavailable", suspended.dig("recovery", "status")
      assert_equal "suspended", suspended.fetch("review_grant").fetch("state")
      assert_equal 2, suspended.fetch("review_grant").fetch("remaining")
      before = File.binread(task.state_file)
      Hive::Lock.with_task_lock(task.folder, create: false) do
        resumed = Hive::Daemon::RecoveryCoordinator.new.reconcile_review_grant!(task: task, project: task.project_name)
        assert_equal "suspended", resumed.state
        assert_equal 2, resumed.remaining
      end
      assert_equal before, File.binread(task.state_file)
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.puts "Changed accepted findings" }
      audit_before = File.binread(budget.audit_path)
      refused = status_row.call
      assert_nil refused["review_grant"]
      assert refused.dig("evidence", "review_grant_diagnostic")
      assert_equal before, File.binread(task.state_file)
      assert_equal audit_before, File.binread(budget.audit_path)
    end
  end
end
