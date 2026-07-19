require "test_helper"
require "rbconfig"
require "hive/refactor_patrol/review_agent_runner"
require "hive/refactor_patrol/state_store"

class RefactorPatrolReviewAgentRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_call_refuses_an_exhausted_architecture_budget
    with_tmp_dir do |dir|
      budget = Object.new
      budget.define_singleton_method(:acquire) do |stage:, minimum_tokens:|
        minimum_tokens >= 0 && stage != "refactor-patrol-review"
      end
      budget.define_singleton_method(:exhaustion_message) { "architecture cycle exhausted" }
      budget.define_singleton_method(:resource_exhaustion) do
        { reason: "daily_agent_spawn_limit", limit: 8, observed: 8 }
      end
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir),
        token_budget: budget
      )
      profile = Struct.new(:name, :initial_context_tokens) do
        def require_cli_capability!(name)
          raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

          [ "--safe-mode", "--disable-slash-commands" ]
        end
      end.new(:claude, 20_000)

      result = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        runner.call(prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)
      end

      assert_equal :error, result.fetch(:status)
      assert_equal "architecture cycle exhausted", result.fetch(:error_message)
      assert_equal(
        { reason: "daily_agent_spawn_limit", limit: 8, observed: 8 },
        result.fetch(:resource_exhaustion)
      )
    end
  end

  def test_call_records_usage_and_profile_fallback
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(project_root: dir, cfg: cfg, state: state)
      fake_profile = Object.new
      fake_agent = Class.new do
        def initialize(**); end

        def run!
          { usage: { model: "m", input: 1, output: 2, cached: 3 } }
        end
      end
      records = []

      original_lookup = Hive::AgentProfiles.method(:lookup)
      original_record = Hive::UsageDb.method(:record!)
      original_agent = Hive.const_get(:Agent)
      begin
        Hive::AgentProfiles.define_singleton_method(:lookup) { |*| fake_profile }
        Hive::UsageDb.define_singleton_method(:record!) { |**kwargs| records << kwargs }
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, fake_agent)
        runner.call(prompt: "p", output_path: File.join(dir, "out.json"), run_dir: state.run_dir("review"))
      ensure
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, original_agent)
        Hive::AgentProfiles.define_singleton_method(:lookup, original_lookup)
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end

      assert_equal 1, records.size
      assert_equal "claude", records.first.fetch(:agent)
      assert_equal "refactor-patrol-review", records.first.fetch(:stage)
    end
  end

  def test_record_usage_warning_is_non_fatal
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir)
      )
      original_record = Hive::UsageDb.method(:record!)
      begin
        Hive::UsageDb.define_singleton_method(:record!) { |**_kwargs| raise "db down" }

        _out, err = capture_io do
          runner.send(:record_usage, { usage: { input: 1 } }, Struct.new(:name).new("claude"), Time.now.utc)
        end

        assert_includes err, "usage record failed"
      ensure
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end
    end
  end

  def test_call_caps_agent_timeout_to_remaining_run_budget
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(project_root: dir, cfg: cfg, state: state)
      fake_profile = Struct.new(:name, :initial_context_tokens) do
        def require_cli_capability!(name)
          raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

          [ "--safe-mode", "--disable-slash-commands" ]
        end
      end.new(:claude, 20_000)
      captured = nil
      fake_agent = Class.new do
        define_method(:initialize) { |**kwargs| captured = kwargs }
        define_method(:run!) { {} }
      end

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { fake_profile }) do
        original_agent = Hive.const_get(:Agent)
        begin
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, fake_agent)
          runner.call(
            prompt: "p", output_path: File.join(dir, "out.json"),
            run_dir: state.run_dir("review"), timeout_sec: 12.5
          )
        ensure
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, original_agent)
        end
      end

      assert_equal 12.5, captured.fetch(:timeout_sec)
      assert_equal 100_000, captured.fetch(:max_tokens)
    end
  end

  def test_read_only_call_uses_claude_tool_confinement
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: state, read_only: true
      )
      profile = Struct.new(:name, :initial_context_tokens) do
        def require_cli_capability!(name)
          raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

          [ "--safe-mode", "--disable-slash-commands" ]
        end
      end.new(:claude, 20_000)
      captured = nil
      output_path = File.join(dir, "out.json")
      fake_agent = Class.new do
        define_method(:initialize) { |**kwargs| captured = kwargs }
        define_method(:run!) { { status: :ok, final_message: '{"theses":[]}' } }
      end

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        original_agent = Hive.const_get(:Agent)
        begin
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, fake_agent)
          runner.call(prompt: "p", output_path: output_path, run_dir: state.run_dir("review"))
        ensure
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, original_agent)
        end
      end

      assert_equal "default", captured.fetch(:permission_mode)
      assert_equal Hive::PermissionScope::READ_ONLY_ALLOWED, captured.fetch(:allowed_tools)
      assert_equal Hive::PermissionScope::READ_ONLY_DISALLOWED, captured.fetch(:disallowed_tools)
      assert_equal [ "--safe-mode", "--disable-slash-commands" ], captured.fetch(:cli_flags)
      assert_equal :exit_code_only, captured.fetch(:status_mode)
      assert_nil captured.fetch(:expected_output)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output_path)))
    end
  end

  def test_read_only_launch_uses_safe_mode_before_project_customizations_can_run
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      fake = File.join(dir, "fake-claude")
      argv_path = File.join(dir, "argv.txt")
      sentinel = File.join(dir, "project-hook-ran")
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      File.write(
        File.join(dir, ".claude", "settings.json"),
        JSON.generate("hooks" => { "SessionStart" => [ { "command" => "touch #{sentinel}" } ] })
      )
      File.write(fake, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        if ARGV == ["--version"]
          puts "2.1.179 (Claude Code)"
          exit 0
        end
        if ARGV == [
          "--safe-mode", "--disable-slash-commands",
          "--tools", "Read,Grep,Glob,Write", "--help"
        ]
          puts "--safe-mode Disable all project and user customizations"
          puts "--disable-slash-commands Disable all skills"
          puts "--tools <tools...> Restrict available tools"
          exit 0
        end
        File.write(ENV.fetch("HIVE_TEST_REVIEW_ARGV"), ARGV.join("\\n"))
        if File.file?(File.join(Dir.pwd, ".claude", "settings.json")) && !ARGV.include?("--safe-mode")
          File.write(ENV.fetch("HIVE_TEST_PROJECT_HOOK_SENTINEL"), "selected")
        end
        puts JSON.generate("type" => "result", "result" => '{"theses":[]}')
      RUBY
      File.chmod(0o755, fake)

      previous_bin = ENV["HIVE_CLAUDE_BIN"]
      ENV["HIVE_CLAUDE_BIN"] = fake
      ENV["HIVE_TEST_REVIEW_ARGV"] = argv_path
      ENV["HIVE_TEST_PROJECT_HOOK_SENTINEL"] = sentinel
      Hive::AgentProfile.reset_version_cache!
      begin
        result = Hive::RefactorPatrol::ReviewAgentRunner.new(
          project_root: dir, cfg: cfg, state: state, read_only: true
        ).call(prompt: "inspect architecture", output_path: File.join(dir, "out.json"),
               run_dir: state.run_dir("review"))
      ensure
        ENV["HIVE_CLAUDE_BIN"] = previous_bin
        ENV.delete("HIVE_TEST_REVIEW_ARGV")
        ENV.delete("HIVE_TEST_PROJECT_HOOK_SENTINEL")
        Hive::AgentProfile.reset_version_cache!
      end

      argv = File.readlines(argv_path, chomp: true)
      assert_equal :ok, result.fetch(:status)
      assert_equal 1, argv.count("--safe-mode")
      assert_equal 1, argv.count("--disable-slash-commands")
      assert_equal %w[--tools Read,Grep,Glob,Write],
                   argv.each_cons(2).find { |flag, _| flag == "--tools" }
      assert_equal %w[--permission-mode default], argv.each_cons(2).find { |flag, _| flag == "--permission-mode" }
      assert_equal %w[--allowedTools Read,LS,Grep,Glob], argv.each_cons(2).find { |flag, _| flag == "--allowedTools" }
      refute File.exist?(sentinel), "safe-mode launch must not select the project's hook settings"
    end
  end

  def test_read_only_launch_fails_closed_when_installed_claude_lacks_safe_mode
    with_tmp_dir do |dir|
      fake = File.join(dir, "old-claude")
      spawned = File.join(dir, "spawned")
      File.write(fake, <<~RUBY)
        #!#{RbConfig.ruby}
        if ARGV == ["--version"]
          puts "2.1.118 (Claude Code)"
          exit 0
        end
        if ARGV.last == "--help"
          puts "--print --permission-mode"
          exit 0
        end
        File.write(#{spawned.inspect}, "spawned")
      RUBY
      File.chmod(0o755, fake)
      previous_bin = ENV["HIVE_CLAUDE_BIN"]
      ENV["HIVE_CLAUDE_BIN"] = fake
      Hive::AgentProfile.reset_version_cache!
      begin
        runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
          project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
        )
        error = assert_raises(Hive::AgentError) do
          runner.call(prompt: "inspect", output_path: File.join(dir, "out.json"), run_dir: dir)
        end
        assert_includes error.message, "does not advertise required patrol_review_context capability"
        assert_includes error.message, "--safe-mode"
      ensure
        ENV["HIVE_CLAUDE_BIN"] = previous_bin
        Hive::AgentProfile.reset_version_cache!
      end

      refute File.exist?(spawned), "unsupported Claude must fail before the review agent starts"
      assert_budget_lock_available(dir)
    end
  end

  def test_read_only_call_fails_closed_for_provider_without_enforcement
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir,
        cfg: cfg.merge("refactor_patrol" => { "agent" => "codex" }),
        state: Hive::RefactorPatrol::StateStore.new(dir),
        read_only: true
      )
      profile = Struct.new(:name).new(:codex)

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        error = assert_raises(Hive::ConfigError) do
          runner.call(prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)
        end
        assert_includes error.message, "cannot enforce read-only"
      end
      assert_budget_lock_available(dir)
    end
  end

  def test_read_only_output_requires_a_theses_array
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )

      result = runner.send(
        :materialize_read_only_output,
        { status: :ok, final_message: '{"summary":"no findings"}' },
        File.join(dir, "review.json")
      )

      assert_equal :error, result.fetch(:status)
      assert_includes result.fetch(:error_message), "theses array"
    end
  end

  def test_read_only_output_accepts_one_json_fence_and_preserves_the_raw_message
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      raw = "```json\n{\"theses\":[]}\n```\n"
      output = File.join(dir, "review.json")

      result = runner.send(
        :materialize_read_only_output,
        { status: :ok, final_message: raw },
        output
      )

      assert_equal :ok, result.fetch(:status)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output)))
      assert_equal raw, File.read(File.join(dir, "final-message.txt"))
    end
  end

  def test_read_only_output_accepts_one_unlabeled_fence
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      raw = "```\n{\"theses\":[]}\n```"
      output = File.join(dir, "review.json")

      result = runner.send(
        :materialize_read_only_output,
        { status: :ok, final_message: raw },
        output
      )

      assert_equal :ok, result.fetch(:status)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output)))
      assert_equal raw, File.read(File.join(dir, "final-message.txt"))
    end
  end

  def test_read_only_output_accepts_trailing_rationale_after_one_leading_fence
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      raw = "```json\n{\"theses\":[]}\n```\n\nNo thesis clears the leverage floor."
      output = File.join(dir, "review.json")

      result = runner.send(
        :materialize_read_only_output,
        { status: :ok, final_message: raw },
        output
      )

      assert_equal :ok, result.fetch(:status)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output)))
      assert_equal raw, File.read(File.join(dir, "final-message.txt"))
    end
  end

  def test_read_only_output_rejects_leading_prose_and_multiple_fences
    invalid_messages = [
      "Before\n```json\n{\"theses\":[]}\n```",
      "```json\n{\"theses\":[]}\n```\n```json\n{\"theses\":[]}\n```",
      "```json\n{\"theses\":[]}\n```\n~~~json\n{\"theses\":[{\"id\":\"conflict\"}]}\n~~~"
    ]

    invalid_messages.each_with_index do |raw, index|
      with_tmp_dir do |dir|
        runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
          project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
        )
        output = File.join(dir, "review-#{index}.json")

        result = runner.send(
          :materialize_read_only_output,
          { status: :ok, final_message: raw },
          output
        )

        assert_equal :error, result.fetch(:status)
        refute File.exist?(output)
        assert_equal raw, File.read(File.join(dir, "final-message.txt"))
      end
    end
  end

  def test_read_only_output_preserves_invalid_raw_message_for_audit
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      raw = "Here is the result: {\"theses\":[]}"
      output = File.join(dir, "review.json")

      result = runner.send(
        :materialize_read_only_output,
        { status: :ok, final_message: raw },
        output
      )

      assert_equal :error, result.fetch(:status)
      refute File.exist?(output)
      assert_equal raw, File.read(File.join(dir, "final-message.txt"))
    end
  end

  def test_read_only_output_preserves_an_agent_error_final_message_for_audit
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      raw = "partial response before provider failure"
      output = File.join(dir, "review.json")

      result = runner.send(
        :materialize_read_only_output,
        { status: :error, final_message: raw, error_message: "provider failed" },
        output
      )

      assert_equal :error, result.fetch(:status)
      refute File.exist?(output)
      assert_equal raw, File.read(File.join(dir, "final-message.txt"))
    end
  end

  def test_read_only_turn_limit_can_materialize_a_complete_final_message
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir), read_only: true
      )
      result = {
        status: :error,
        final_message: '{"theses":[]}',
        resource_exhaustion: { reason: "turn_limit", observed: 3, limit: 3 }
      }
      assert runner.send(:resource_limited_with_final_message?, result)

      output = File.join(dir, "review.json")
      materialized = runner.send(:materialize_read_only_output, result.merge(status: :ok), output)

      assert_equal :ok, materialized.fetch(:status)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output)))

      result[:resource_exhaustion][:reason] = "token_limit"
      assert runner.send(:resource_limited_with_final_message?, result)
    end
  end

  def test_read_only_call_salvages_complete_output_at_turn_limit
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: state, read_only: true
      )
      profile = Struct.new(:name, :initial_context_tokens) do
        def require_cli_capability!(name)
          raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

          [ "--safe-mode", "--disable-slash-commands" ]
        end
      end.new(:claude, 20_000)
      fake_agent = Class.new do
        def initialize(**); end

        def run!
          {
            status: :error,
            final_message: '{"theses":[]}',
            resource_exhaustion: { reason: "turn_limit", observed: 3, limit: 3 }
          }
        end
      end
      output = File.join(dir, "review.json")

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        original_agent = Hive.const_get(:Agent)
        begin
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, fake_agent)
          result = runner.call(prompt: "p", output_path: output, run_dir: state.run_dir("review"))

          assert_equal :ok, result.fetch(:status)
        ensure
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, original_agent)
        end
      end

      assert_equal({ "theses" => [] }, JSON.parse(File.read(output)))
    end
  end

  private

  def assert_budget_lock_available(project_root)
    budget = Hive::Patrol::TokenBudget.new(project_root, cfg: cfg)
    assert budget.acquire(stage: "refactor-patrol-review"),
           "pre-launch validation must not strand the project patrol lock"
  ensure
    budget&.send(:release_launch_lock)
  end

  def cfg
    {
      "budget_usd" => { "patrol" => 100 },
      "timeout_sec" => { "patrol" => 3600 },
      "refactor_patrol" => { "agent" => "claude" }
    }
  end
end
