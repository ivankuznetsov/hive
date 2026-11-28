require "test_helper"
require "hive/agent"
require "hive/task"
require "hive/review_budget"
require "hive/reviewers"
require "hive/reviewers/runtime"

class AgentReviewBudgetCustodyTest < Minitest::Test
  include HiveTestHelper

  def test_each_common_review_agent_launch_restores_budget_edits_deletions_additions_and_absent_audit
    %w[reviewer triage fix].each do |role|
      %i[edit delete add audit].each do |operation|
        with_budget do |task, receipt, audit|
          File.unlink(audit) if operation == :audit
          script = case operation
          when :edit then "File.write(#{receipt.inspect}, 'edited')"
          when :delete then "File.unlink(#{receipt.inspect})"
          when :add then "File.write(#{File.join(task.folder, 'reviews', 'review-grant-forged.json').inspect}, '{}')"
          when :audit then "File.write(#{audit.inspect}, 'forged audit')"
          end
          before = budget_bytes(task)
          error = assert_raises(Hive::ReviewBudget::Refused) do
            ruby_agent(task, "#{script}; exit 7", role:).run!
          end
          assert_equal "agent_modified_budget", error.reason, "#{role}/#{operation}"
          assert_equal before, budget_bytes(task), "#{role}/#{operation}"
        end
      end
    end
  end

  def test_native_execution_early_return_and_errors_both_verify_custody
    [ false, true ].each do |raises|
      with_budget do |task, receipt, _audit|
        agent = Hive::Agent.new(
          task:, prompt: "fix", max_budget_usd: nil, timeout_sec: 5,
          profile: Hive::AgentProfiles.lookup(:opencode)
        )
        agent.define_singleton_method(:run_supported) do
          File.write(receipt, "native edit")
          raise Hive::AgentError, "native failure" if raises
          { exit_code: 0 }
        end
        error = assert_raises(Hive::ReviewBudget::Refused) { agent.spawn_and_wait }
        assert_equal "agent_modified_budget", error.reason
        assert_equal "controller receipt", File.read(receipt)
      end
    end
  end

  def test_common_agent_propagates_an_unsafe_restoration_failure
    with_budget do |task, receipt, _audit|
      script = "File.unlink(#{receipt.inspect}); Dir.mkdir(#{receipt.inspect})"
      error = assert_raises(Hive::ReviewBudget::Refused) { ruby_agent(task, script).run! }
      assert_equal "unsafe_state", error.reason
      assert File.directory?(receipt)
    end
  end

  def test_each_special_reviewer_capture_restores_tampering_even_after_nonzero_exit
    %i[edit delete add audit].each do |operation|
      with_budget do |task, receipt, audit|
        File.unlink(audit) if operation == :audit
        script = case operation
        when :edit then "File.write(#{receipt.inspect}, 'edited')"
        when :delete then "File.unlink(#{receipt.inspect})"
        when :add then "File.write(#{File.join(task.folder, 'reviews', 'review-grant-forged.json').inspect}, '{}')"
        when :audit then "File.write(#{audit.inspect}, 'forged audit')"
        end
        before = budget_bytes(task)
        error = assert_raises(Hive::ReviewBudget::Refused) do
          Hive::Reviewers::Runtime.capture(
            environment: {}, argv: [ RbConfig.ruby, "-e", "#{script}; exit 7" ],
            chdir: task.folder, task_folder: task.folder,
            timeout_sec: 5, timeout_message: "timed out"
          )
        end
        assert_equal "agent_modified_budget", error.reason
        assert_equal before, budget_bytes(task)
      end
    end
  end

  def test_special_codex_reviewer_provides_task_context_before_any_retry
    with_budget do |task, receipt, _audit|
      binary = File.join(task.project_root, "fake-codex-custody")
      counter = File.join(task.project_root, "spawn-count")
      File.write(binary, <<~RUBY)
        #!#{RbConfig.ruby}
        if ARGV.include?("--version")
          puts "codex-cli 0.162.1"
          exit 0
        end
        File.write(#{counter.inspect}, "spawned\\n", mode: "a")
        File.write(#{receipt.inspect}, "reviewer tampering")
        puts "## High\\n- [ ] Finding\\n## Medium\\nNo findings.\\n## Nit\\nNo findings."
        exit 1
      RUBY
      File.chmod(0o755, binary)
      context = Hive::Reviewers::Context.new(
        worktree_path: task.project_root, task_folder: task.folder,
        default_branch: "main", pass: 1
      )
      spec = {
        "name" => "codex-native-review", "kind" => "codex_review", "agent" => "codex",
        "output_basename" => "codex-native-review", "prompt_template" => "reviewer_codex_native_review.md.erb",
        "timeout_sec" => 5, "max_attempts" => 3
      }
      with_env("HIVE_CODEX_BIN" => binary) do
        Hive::AgentProfile.reset_version_cache!
        reviewer = Hive::AgentSupport.for(:codex)::Reviewer.new(spec, context)
        error = assert_raises(Hive::ReviewBudget::Refused) { reviewer.run! }
        assert_equal "agent_modified_budget", error.reason
      ensure
        Hive::AgentProfile.reset_version_cache!
      end
      assert_equal "controller receipt", File.read(receipt)
      assert_equal [ "spawned" ], File.readlines(counter, chomp: true)
    end
  end

  def test_internal_pr_checkout_fixed_anchors_and_archive_history_enforced_at_agent_and_reviewer_spawns
    require "hive/internal_pr_checkout"
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-42")
      FileUtils.mkdir_p(folder)
      prepare_test_task_run(folder)
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 42
        pr_url: https://github.com/acme/widget/pull/42
        head_oid: #{"a" * 40}
        ---
        # PR 42
      MD
      store = Hive::InternalPrCheckout::Store.new(folder)
      store.initialize_generation_one!(
        task_id: "0042", task_slug: "adhoc-review-pr-42", project: "widget",
        pr_host: "github.com", pr_repository: "acme/widget", pr_number: 42,
        pr_url: "https://github.com/acme/widget/pull/42", base_ref_name: "main",
        head_ref_name: "feat", head_repository: "acme/widget", is_cross_repository: false,
        pr_state: "OPEN", branch: "hive/review/pr-42", head_oid: "a" * 40,
        committed_at: Time.utc(2026, 8, 29, 12, 0, 0)
      )
      arch = File.join(folder, "reviews", "archive", "gen-01")
      FileUtils.mkdir_p(arch)
      File.write(File.join(arch, "claude-01.md"), "archived\n")
      store.seal_retirement!(label: "gen-01")
      store.sync_current_history_root_digest!
      task = Hive::Task.new(folder)

      # 1. Agent editing pr.md anchor -> restored + Refused (agent_modified_budget)
      orig_pr = File.read(File.join(folder, "pr.md"))
      err = assert_raises(Hive::ReviewBudget::Refused) do
        ruby_agent(task, "File.write(#{File.join(folder, 'pr.md').inspect}, 'forged'); exit 0", role: "fix").run!
      end
      assert_equal "agent_modified_budget", err.reason
      assert_equal orig_pr, File.read(File.join(folder, "pr.md"))

      # 2. Reviewer capture adding an unseen nested file inside reviews/archive -> Refused (unsafe_state)
      rogue = File.join(arch, "injected.md")
      err2 = assert_raises(Hive::ReviewBudget::Refused) do
        Hive::Reviewers::Runtime.capture(
          environment: {}, argv: [ RbConfig.ruby, "-e", "File.write(#{rogue.inspect}, 'bad'); exit 1" ],
          chdir: folder, task_folder: folder, timeout_sec: 5, timeout_message: "timed out"
        )
      end
      assert_equal "unsafe_state", err2.reason
      # Subsequent integrity verification still refuses until repaired.
      assert_raises(Hive::InternalPrCheckout::CustodyError) { store.verify_history_integrity! }
    end
  end

  private

  def ruby_agent(task, script, role: "fix")
    profile = Hive::AgentProfile.new(
      name: :budget_custody, bin_default: RbConfig.ruby, headless_flag: "-e",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}", status_detection_mode: :exit_code_only
    )
    Hive::Agent.new(task:, prompt: script, profile:, log_label: role,
                    max_budget_usd: nil, timeout_sec: 5)
  end

  def with_budget
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "budget-custody-261102-aaaa")
      FileUtils.mkdir_p(folder)
      prepare_test_task_run(folder)
      task = Hive::Task.new(folder)
      FileUtils.mkdir_p([ File.join(folder, "reviews"), File.join(folder, "review-budget") ], mode: 0o700)
      receipt = File.join(folder, "reviews", "review-grant-#{'a' * 64}.json")
      audit = File.join(folder, "review-budget", "audit.jsonl")
      File.write(receipt, "controller receipt", mode: "w", perm: 0o600)
      File.write(audit, "controller audit", mode: "w", perm: 0o600)
      yield task, receipt, audit
    end
  end

  def budget_bytes(task)
    %w[reviews review-budget].flat_map do |directory|
      Dir.glob(File.join(task.folder, directory, "*")).map { |path| [ path, File.binread(path) ] }
    end.to_h
  end
end
