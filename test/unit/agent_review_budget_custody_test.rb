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
