require "test_helper"
require "hive/agent"
require "hive/agent_profile"
require "hive/task"

class OpenCodeAgentLifecycleTest < Minitest::Test
  include HiveTestHelper

  ROUTE = "anthropic/claude-sonnet-4-5"

  def test_success_spawns_one_run_and_one_export_then_cleans_the_overlay
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir))
      root = File.join(fixture.fetch(:dir), "invocation-success")
      agent = build_agent(task, fixture, invocation_root: root)

      result = with_env(
        "ANTHROPIC_API_KEY" => "secret-canary",
        "OPENAI_API_KEY" => "ambient-must-not-cross"
      ) { agent.run! }

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      assert_equal "Done.", result.fetch(:final_message)
      assert_equal ROUTE, result.fetch(:requested_opencode_route)
      assert_equal ROUTE, result.fetch(:actual_opencode_route)
      assert_equal 5, result.dig(:usage, :input)
      assert_equal 2, result.dig(:usage, :cache_read)
      assert_equal 0, result.dig(:usage, :cache_write)
      assert_equal 0.0, result.dig(:usage, :cost)
      assert_instance_of Hive::AgentRuntime::NormalizedOutcome,
                         agent.observable_result
      assert_equal :completed, agent.observable_result.kind
      refute File.exist?(root)

      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 1, calls.count { |line| line.start_with?("run --auto ") }
      assert_equal 1, calls.count { |line| line.start_with?("export ses_") }
      environment = JSON.parse(File.read(fixture.fetch(:environment)))
      assert environment.fetch("XDG_CONFIG_HOME").start_with?(root)
      assert_equal "true", environment.fetch("OPENCODE_DISABLE_PROJECT_CONFIG")
      assert environment.fetch("selected_credential_present")
      refute environment.fetch("ambient_credential_present")
      refute_includes File.read(result.fetch(:log_file)), "secret-canary"
    end
  end

  def test_nonzero_malformed_timeout_and_inspection_failure_skip_or_bound_inspection
    {
      auth_failure: [ :authentication_failure, 0 ],
      malformed: [ :malformed_output, 0 ],
      inspection_failure: [ :malformed_output, 1 ],
      timeout: [ :timed_out, 0 ]
    }.each do |mode, (kind, export_count)|
      with_fixture(mode:) do |fixture|
        task = make_task(
          fixture.fetch(:dir), slug: "#{mode.to_s.tr('_', '-')}-260812-aaaa"
        )
        root = File.join(fixture.fetch(:dir), "invocation-#{mode}")
        result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
          build_agent(
            task, fixture, invocation_root: root,
            timeout_sec: mode == :timeout ? 0.2 : 5
          ).run!
        end

        expected_status = mode == :timeout ? :timeout : :error
        assert_equal expected_status, result.fetch(:status), mode
        assert_equal kind, result.fetch(:normalized_outcome_kind), mode
        refute File.exist?(root), mode
        calls = File.readlines(fixture.fetch(:calls), chomp: true)
        assert_equal 1,
                     calls.count { |line| line.start_with?("run --auto ") }, mode
        assert_equal export_count,
                     calls.count { |line| line.start_with?("export ses_") }, mode
      end
    end
  end

  def test_pre_spawn_failure_still_cleans_the_prepared_overlay
    with_fixture(mode: :remove_after_probe) do |fixture|
      task = make_task(fixture.fetch(:dir))
      root = File.join(fixture.fetch(:dir), "invocation-pre-spawn")
      agent = build_agent(task, fixture, invocation_root: root)

      assert_raises(Errno::ENOENT) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }
      end
      refute File.exist?(root)
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 0, calls.count { |line| line.start_with?("run --auto ") }
      assert_equal 0, calls.count { |line| line.start_with?("export ses_") }
    end
  end

  def test_explicit_overlay_default_supplies_the_route_when_role_has_no_model_override
    with_fixture(default_route: ROUTE) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "default-route-260812-aaaa")
      root = File.join(fixture.fetch(:dir), "invocation-default-route")
      agent = build_agent(
        task, fixture, invocation_root: root, explicit_launch: false
      )

      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }

      assert_equal :ok, result.fetch(:status)
      assert_equal ROUTE, result.fetch(:requested_opencode_route)
      assert_equal ROUTE, result.fetch(:actual_opencode_route)
      refute File.exist?(root)
    end
  end

  private

  def make_task(dir, slug: "opencode-agent-260812-aaaa")
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def build_agent(task, fixture, invocation_root:, timeout_sec: 5,
                  explicit_launch: true)
    profile = Hive::AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:opencode),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :exit_code_only,
      permission_presets: %w[read-only scoped],
      opencode_configuration_path: fixture.fetch(:configuration),
      opencode_credential_environment_keys: [ "ANTHROPIC_API_KEY" ]
    ).with_overrides("bin" => fixture.fetch(:bin))
    launch = if explicit_launch
      profile.identity_arguments(model: ROUTE, effort: "high")
    end
    Hive::Agent.new(
      task:, prompt: "make the atomic edit", max_budget_usd: nil,
      timeout_sec:, cwd: fixture.fetch(:work), profile:,
      permission_mode: "read-only", launch_arguments: launch,
      opencode_invocation_root: invocation_root,
      additional_read_roots: [ task.folder ],
      additional_write_roots: []
    )
  end

  def with_fixture(mode: :success, default_route: nil)
    with_tmp_dir do |dir|
      work = File.join(dir, "work")
      FileUtils.mkdir_p(work)
      calls = File.join(dir, "calls.log")
      environment = File.join(dir, "environment.json")
      configuration = File.join(dir, "selected-config.json")
      selected_config = {
        "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
      }
      selected_config["model"] = default_route if default_route
      File.write(configuration, JSON.generate(selected_config))
      bin = File.join(dir, "opencode")
      File.write(bin, fixture_script(
        mode:, calls:, environment:, source_root: dir
      ))
      File.chmod(0o755, bin)
      yield({ dir:, work:, calls:, environment:, configuration:, bin: })
    end
  end

  def fixture_script(mode:, calls:, environment:, source_root:)
    run_help = File.read(File.join(
      source_root_for_fixtures,
      "run-help.txt"
    ))
    export_help = File.read(File.join(source_root_for_fixtures, "export-help.txt"))
    run_output = File.read(File.join(
      source_root_for_fixtures,
      mode == :malformed ? "run-malformed-json.jsonl" :
        (mode == :auth_failure ? "run-auth-error.jsonl" : "run-one-step.jsonl")
    ))
    export_output = File.read(File.join(
      source_root_for_fixtures, "session-export-matching.json"
    ))
    <<~RUBY
      #!/usr/bin/ruby --disable-gems
      require "json"
      File.open(#{calls.dump}, "a") { |file| file.puts(ARGV.join(" ")) }
      case ARGV
      when ["--version"]
        puts "opencode 1.18.16"
      when ["run", "--help"]
        print #{run_help.dump}
      when ["export", "--help"]
        print #{export_help.dump}
      when ["auth", "list"]
        puts "anthropic"
      when ["models", "anthropic", "--verbose"]
        puts #{ROUTE.dump}
        puts '{"variants":{"high":{}}}'
        File.unlink(__FILE__) if #{mode == :remove_after_probe}
      else
        if ARGV.first == "run"
          File.write(#{environment.dump}, JSON.generate({
            "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"],
            "OPENCODE_DISABLE_PROJECT_CONFIG" => ENV["OPENCODE_DISABLE_PROJECT_CONFIG"],
            "selected_credential_present" => !ENV["ANTHROPIC_API_KEY"].to_s.empty?,
            "ambient_credential_present" => !ENV["OPENAI_API_KEY"].to_s.empty?
          }))
          sleep 10 if #{mode == :timeout}
          print #{run_output.dump}
          warn "authentication failed" if #{mode == :auth_failure}
          exit(#{mode == :auth_failure ? 1 : 0})
        elsif ARGV.first == "export"
          if #{mode == :inspection_failure}
            warn "export unavailable"
            exit 1
          end
          print #{export_output.dump}
        else
          warn "unexpected argv: #{ARGV.inspect}"
          exit 64
        end
      end
    RUBY
  end

  def source_root_for_fixtures
    File.expand_path(
      "../../components/agent-cli-runtime/test/fixtures/opencode/v1.18.16",
      __dir__
    )
  end
end
