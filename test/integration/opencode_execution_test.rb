require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/run"
require "hive/attempts/capability"
require "hive/attempts/store"
require "hive/stages/plan"
require "hive/task"

class OpenCodeExecutionIntegrationTest < Minitest::Test
  include HiveTestHelper

  ROUTE = "anthropic/claude-sonnet-4-5"

  def setup
    @driver_dir = Dir.mktmpdir("opencode-integration")
    @calls = File.join(@driver_dir, "calls.jsonl")
    @observations = File.join(@driver_dir, "observations.jsonl")
    @configuration = File.join(@driver_dir, "opencode.json")
    File.write(
      @configuration,
      JSON.generate(
        "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
      )
    )
    driver = File.join(@driver_dir, "opencode-driver.rb")
    File.write(driver, fake_opencode_script)
    @bin = File.join(@driver_dir, "opencode")
    File.write(@bin, <<~SH)
      #!/bin/sh
      unset BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLER_SETUP BUNDLER_VERSION
      unset GEM_HOME GEM_PATH RUBYLIB RUBYOPT
      exec /usr/bin/ruby --disable-gems #{driver.dump} "$@"
    SH
    File.chmod(0o755, @bin)
    @saved_environment = %w[
      HIVE_OPENCODE_BIN ANTHROPIC_API_KEY OPENAI_API_KEY
    ].to_h { |key| [ key, ENV[key] ] }
    ENV["HIVE_OPENCODE_BIN"] = @bin
    ENV["ANTHROPIC_API_KEY"] = "integration-secret-canary"
    ENV["OPENAI_API_KEY"] = "ambient-credential-must-not-cross"
    @worktree_paths = []
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    @saved_environment.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    Hive::AgentProfile.reset_version_cache!
    @worktree_paths.each { |path| FileUtils.rm_rf(path) }
    FileUtils.rm_rf(@driver_dir)
  end

  def test_fake_cli_completes_execute_with_confined_policy_identity_and_cleanup
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project).call }
        config_path = File.join(project, ".hive-state", "config.yml")
        config = YAML.safe_load(File.read(config_path))
        worktree_root = Dir.mktmpdir("opencode-execute-worktrees")
        @worktree_paths << worktree_root
        config["worktree_root"] = worktree_root
        configure_opencode!(config, stage: "execute")
        File.write(config_path, config.to_yaml)

        slug = "opencode-execute-260812-abcd"
        folder = File.join(
          project, ".hive-state", "stages", "4-execute", slug
        )
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "plan.md"), <<~PLAN)
          # Atomic OpenCode integration

          Create and commit implementation.txt.

          <!-- COMPLETE -->
        PLAN

        task = Hive::Task.new(folder)
        attempts = Hive::Attempts::Store.new(
          root: File.join(project, ".hive-state", "attempts")
        )
        attempt = create_attempt(task, attempts)
        with_env("HIVE_ATTEMPT_STORE_ROOT" => attempts.root) do
          with_attempt_context(
            attempt_id: attempt.attempt_id,
            task_generation: 1,
            ownership_generation: attempt.ownership_generation
          ) do
            capture_io { Hive::Commands::Run.new(folder).call }
          end
        end

        pointer = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
        worktree = pointer.fetch("path")
        @worktree_paths << worktree
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
        assert_equal "implemented by OpenCode\n",
                     File.read(File.join(worktree, "implementation.txt"))
        commit_subject, commit_error, commit_status = Open3.capture3(
          "git", "-C", worktree, "log", "-1", "--pretty=%s"
        )
        assert commit_status.success?, commit_error
        assert_equal "feat: fake OpenCode execution", commit_subject.strip

        observation = observations.fetch(0)
        assert_confined_workspace_write_policy(
          observation.fetch("permission"),
          working_directory: worktree,
          additional_write_root: folder
        )
        assert observation.fetch("selected_credential_present")
        refute observation.fetch("ambient_credential_present")
        refute File.exist?(observation.fetch("invocation_root"))

        projection = JSON.parse(
          File.read(File.join(folder, "task-projection.json"))
        )
        identity = projection.dig("implementation_identity", "execute")
        assert_equal "opencode", identity.fetch("provider")
        assert_equal "anthropic", identity.fetch("requested_backend")
        assert_equal "claude-sonnet-4-5", identity.fetch("requested_model")
        assert_equal "anthropic", identity.fetch("actual_backend")
        assert_equal "claude-sonnet-4-5", identity.fetch("actual_model")
        assert_equal "completed", identity.fetch("outcome_kind")

        assert_equal 1, model_calls.count { |entry| entry["command"] == "run" }
        assert_equal 1,
                     model_calls.count { |entry| entry["command"] == "export" }
      end
    end
  end

  def test_fake_cli_completes_a_skill_dependent_plan_through_native_ce_readiness
    with_tmp_git_repo do |project|
      folder = File.join(
        project, ".hive-state", "stages", "3-plan",
        "opencode-plan-260812-abcd"
      )
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n")
      plugin_root = File.join(project, "vendor", "compound-engineering")
      plugin_entry = File.join(
        plugin_root, ".opencode", "plugins", "compound-engineering.js"
      )
      FileUtils.mkdir_p(File.dirname(plugin_entry))
      File.write(plugin_entry, "export default {}\n")
      skill_path = File.join(plugin_root, "skills", "ce-plan", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill_path))
      File.write(skill_path, "# Native plan skill\n")

      config = JSON.parse(JSON.generate(Hive::Config::DEFAULTS))
      config["project_root"] = project
      configure_opencode!(config, stage: "plan", plugin: plugin_entry)
      task = Hive::Task.new(folder)

      result = Hive::Stages::Plan.run!(task, config)

      assert_equal :complete, result.fetch(:status)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      observation = observations.fetch(0)
      assert observation.fetch("skill_invocation_present")
      assert_equal "allow", observation.dig("permission", "skill")
      assert_confined_workspace_write_policy(
        observation.fetch("permission"),
        working_directory: folder,
        additional_write_root: folder
      )
      refute File.exist?(observation.fetch("invocation_root"))
      assert_equal 1, model_calls.count { |entry| entry["command"] == "run" }
      assert_equal 1,
                   model_calls.count { |entry| entry["command"] == "export" }
    end
  end

  private

  def configure_opencode!(config, stage:, plugin: nil)
    config["agents"] ||= {}
    config["agents"]["opencode"] = {
      "config_path" => @configuration,
      "credential_env" => [ "ANTHROPIC_API_KEY" ],
      "plugins" => plugin ? [ "file://#{plugin}" ] : [],
      "isolation" => "hermetic"
    }
    config[stage] ||= {}
    config[stage]["agent"] = "opencode"
    config[stage]["permissions"] = {
      "preset" => "scoped", "tools" => %w[Read Write Edit]
    }
    config["models"] ||= {}
    routing_stage = stage == "execute" ? "execute_implementation" : stage
    config["models"][routing_stage] = {
      "model" => ROUTE, "effort" => "high"
    }
  end

  def create_attempt(task, attempts)
    attempts.create_launching(
      attempt_id: "opencode-execute-attempt",
      request_id: "opencode-execute-request",
      predecessor_attempt_id: nil,
      task_id: task.id&.to_s,
      project: File.basename(task.project_root),
      task_slug: task.slug,
      intended_stage: "4-execute",
      task_generation: "owner-1",
      ownership_generation: "owner-1",
      task_input_epoch: 1,
      progress_token: "opencode-execute-progress",
      provider: "opencode",
      starting_revision: nil,
      retry_charge: 0,
      inherited_outputs: [],
      launch_timeout_sec: 30,
      worker_argv: [ "hive", "run", task.folder ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      now: Time.now.utc
    )
  end

  def calls
    File.readlines(@calls, chomp: true).map { |line| JSON.parse(line) }
  end

  def observations
    File.readlines(@observations, chomp: true).map { |line| JSON.parse(line) }
  end

  def model_calls
    calls.reject { |entry| entry.fetch("inspection") }
  end

  def assert_confined_workspace_write_policy(permission, working_directory:,
                                             additional_write_root:)
    assert_equal "deny", permission.fetch("*")
    assert_equal "deny", permission.fetch("bash")
    assert_equal "deny", permission.dig("edit", "*")
    assert_equal "allow", permission.dig("edit", "**")
    absolute_working_allow = permission.fetch("edit").any? do |pattern, action|
      action == "allow" && pattern.start_with?(working_directory)
    end
    refute absolute_working_allow, permission.fetch("edit").inspect
    unless additional_write_root == working_directory
      assert_equal "allow", permission.dig("edit", additional_write_root)
      assert_equal "allow",
                   permission.dig("edit", "#{additional_write_root}/**")
    end
    assert_equal "deny", permission.dig("external_directory", "*")
  end

  def fake_opencode_script
    fixtures = File.expand_path(
      "../../components/agent-cli-runtime/test/fixtures/opencode/v1.18.16",
      __dir__
    )
    run_help = File.read(File.join(fixtures, "run-help.txt"))
    export_help = File.read(File.join(fixtures, "export-help.txt"))
    run_output = File.read(File.join(fixtures, "run-one-step.jsonl"))
    export_output = File.read(
      File.join(fixtures, "session-export-matching.json")
    )
    <<~RUBY
      #!/usr/bin/ruby --disable-gems
      require "json"

      command = ARGV.first
      directory_index = ARGV.index("--dir")
      working_directory = directory_index && ARGV[directory_index + 1]
      File.open(#{@calls.dump}, "a", 0o600) do |file|
        file.puts(JSON.generate({
          "command" => command,
          "argc" => ARGV.length,
          "inspection" => ARGV.include?("--help") || command == "auth" ||
                          command == "models" || command == "--version",
          "working_directory" => working_directory
        }))
      end

      case ARGV
      when ["--version"]
        puts "opencode 1.18.16"
      when ["run", "--help"]
        print #{run_help.dump}
      when ["export", "--help"]
        print #{export_help.dump}
      when ["auth", "list"]
        puts
      when ["models", "anthropic", "--verbose"]
        puts #{ROUTE.dump}
        puts '{"variants":{"high":{}}}'
      else
        if command == "run"
          config_path = ENV.fetch("OPENCODE_CONFIG")
          config = JSON.parse(File.read(config_path))
          permission = config.fetch("permission")
          observation = {
            "working_directory" => working_directory,
            "invocation_root" => File.dirname(ENV.fetch("XDG_CONFIG_HOME")),
            "permission" => permission,
            "skill_invocation_present" => ARGV.last.include?("/ce-plan"),
            "selected_credential_present" => !ENV["ANTHROPIC_API_KEY"].to_s.empty?,
            "ambient_credential_present" => !ENV["OPENAI_API_KEY"].to_s.empty?
          }
          File.open(#{@observations.dump}, "a", 0o600) do |file|
            file.puts(JSON.generate(observation))
          end

          if working_directory.include?("/.hive-state/stages/3-plan/")
            File.write(
              File.join(working_directory, "plan.md"),
              "# Plan\\n\\nCompleted by OpenCode.\\n\\n<!-- COMPLETE -->\\n"
            )
          else
            File.write(
              File.join(working_directory, "implementation.txt"),
              "implemented by OpenCode\\n"
            )
            Dir.chdir(working_directory) do
              system("git", "add", "implementation.txt", out: File::NULL,
                     err: File::NULL) || abort("git add failed")
              system("git", "commit", "-m", "feat: fake OpenCode execution",
                     "--quiet", out: File::NULL, err: File::NULL) ||
                abort("git commit failed")
            end
          end
          print #{run_output.dump}
        elsif command == "export"
          print #{export_output.dump}
        else
          warn "unexpected fake OpenCode call"
          exit 64
        end
      end
    RUBY
  end
end
