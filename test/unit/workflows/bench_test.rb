require "test_helper"
require "json"
require "open3"
require "sqlite3"
require "time"
require "hive/workflow_selection"
require "hive/workflows/bench"
require "hive/workflows/registry"

class WorkflowsBenchTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def descriptor
    Hive::Workflows::Registry.fetch(:bench)
  end

  def stages_by_name
    descriptor.stages.to_h { |stage| [ stage.name, stage ] }
  end

  def test_registry_exposes_bench_as_a_builtin_workflow
    assert_same Hive::Workflows::Bench::DESCRIPTOR, descriptor
    assert_includes Hive::Workflows::Registry.ids, :bench
    assert_includes Hive::WorkflowSelection.valid_names, "bench"
  end

  def test_descriptor_matches_the_native_benchmark_pipeline
    assert_equal :bench, descriptor.id
    assert_equal %w[inbox extract generate judge publish done], descriptor.stage_names
    assert_equal %w[1-inbox 2-extract 3-generate 4-judge 5-publish 6-done], descriptor.stage_dirs
    assert_equal [ :inert, :agent, :agent, :agent, :agent, :inert ],
                 descriptor.stages.map(&:kind)
    assert_equal [ "task.md", "extract.md", "generate.md", "judge.md", "publish.md", "task.md" ],
                 descriptor.stages.map(&:state_file)
  end

  def test_agent_stages_use_packaged_benchmark_instructions
    %w[extract generate judge publish].each do |name|
      stage = stages_by_name.fetch(name)

      assert_equal File.join(Hive::Workflows::Bench::INSTRUCTIONS_DIR, "#{name}.md"), stage.instruction
      assert_path_exists stage.instruction
      instruction = File.read(stage.instruction)
      assert_includes instruction, "<!-- bench-stage-script -->"
      assert_includes instruction, ".hive-state/bench-runtime"
      refute_includes instruction, "\$REPO_ROOT/harness/"
      assert_equal :state_file_marker, stage.status_mode
    end
  end

  def test_agent_stages_use_codex_control_plane_with_campaign_sized_timeouts
    expected_timeouts = {
      "extract" => 3600,
      "generate" => 604_800,
      "judge" => 604_800,
      "publish" => 3600
    }

    expected_timeouts.each do |name, timeout_sec|
      stage = stages_by_name.fetch(name)

      assert_equal "codex", stage.agent
      assert_nil stage.effort
      assert_equal timeout_sec, stage.timeout_sec
    end
  end

  def test_packaged_runtime_contains_campaign_driver_and_runner_image
    runtime = Hive::Workflows::Bench::RUNTIME_DIR

    assert_path_exists File.join(runtime, "harness", "hive_run.rb")
    assert_path_exists File.join(runtime, "harness", "lib", "judge_slate.rb")
    assert_path_exists File.join(runtime, "harness", "lib", "opencode_bench_runtime.rb")
    assert_path_exists File.join(runtime, "harness", "lib", "pi_bench_launcher.sh")
    assert_path_exists File.join(runtime, "harness", "lib", "provider_egress_proxy.rb")
    assert_path_exists File.join(runtime, "harness", "lib", "token_report.rb")
    assert_path_exists File.join(runtime, "harness", "profiles", "pi_openrouter_models.json")
    assert_path_exists File.join(runtime, "campaign.yml.example")
    assert_path_exists File.join(runtime, "Dockerfile.runner")
  end

  def test_packaged_runtime_routes_ox_alpha_max_through_pi_without_plan_review
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "json"
      require "profiles/candidates"
      require "lib/hive_config"
      candidate = HiveBench::Candidates.by_id("all-ox-alpha@max")
      abort "missing max candidate" unless candidate
      puts JSON.generate(
        "candidate" => candidate.to_h,
        "config" => HiveBench::HiveConfig.to_h(candidate)
      )
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, out + err
    payload = JSON.parse(out)
    candidate = payload.fetch("candidate")
    config = payload.fetch("config")
    assert_equal "ox-alpha-max", candidate.fetch("model_version")
    assert_equal %w[pi pi pi], candidate.values_at("plan", "execute", "review")
    %w[plan execute open_pr review_ci review_triage review_fix].each do |stage|
      assert_equal "openrouter/stealth/ox-alpha:max", config.dig("models", stage, "model")
    end
    assert_equal false, config.dig("plan_review", "enabled")
  end

  def test_packaged_runtime_recovers_redacted_opencode_usage_from_hive_database
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    Dir.mktmpdir("hive-bench-opencode-usage") do |target|
      db_path = File.join(target, ".hb", "hive-home", "usage.db")
      FileUtils.mkdir_p(File.dirname(db_path))
      SQLite3::Database.new(db_path) do |db|
        db.execute <<~SQL
          CREATE TABLE token_usage (
            agent TEXT NOT NULL, model TEXT, actual_backend TEXT, actual_model TEXT,
            stage TEXT, input INTEGER, output INTEGER, cached INTEGER,
            cache_read INTEGER, cache_write INTEGER,
            input_available INTEGER, output_available INTEGER, cached_available INTEGER,
            cache_read_available INTEGER, cache_write_available INTEGER
          )
        SQL
        db.execute(
          "INSERT INTO token_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [ "opencode", "openrouter/stealth/ox-alpha", "openrouter", "stealth/ox-alpha",
            "3-plan", 2_392, 130, 13_440, 13_440, 0, 1, 1, 1, 1, 1 ]
        )
      end
      script = <<~'RUBY'
        require "json"
        require "lib/token_report"
        puts JSON.generate(HiveBench::TokenReport.scan_cell(ARGV.fetch(0)))
      RUBY

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{harness}", "-e", script, target
      )

      assert status.success?, out + err
      usage = JSON.parse(out).fetch("openrouter/stealth/ox-alpha")
      assert_equal 2_392, usage.fetch("input")
      assert_equal 130, usage.fetch("output")
      assert_equal 13_440, usage.fetch("cache_read")
      assert_equal 0, usage.fetch("cache_write")
    end
  end

  def test_packaged_runtime_gives_opencode_the_same_shell_capability_as_pi
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "json"
      require "profiles/candidates"
      require "lib/hive_config"
      candidate = HiveBench::Candidates.by_id("all-ox-alpha-opencode@high")
      puts JSON.generate(HiveBench::HiveConfig.to_h(candidate).fetch("permissions"))
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, out + err
    permissions = JSON.parse(out)
    assert_equal "scoped", permissions.fetch("preset")
    assert_equal [ "Read", "Write", "Edit", "Bash(*)" ], permissions.fetch("tools")
  end

  def test_packaged_runtime_emits_a_hive_valid_opencode_config
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "profiles/candidates"
      require "lib/hive_config"
      puts HiveBench::HiveConfig.to_yaml(
        HiveBench::Candidates.by_id("all-ox-alpha-opencode@high")
      )
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)
    assert status.success?, out + err

    Dir.mktmpdir("hive-bench-opencode-config") do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), out)

      previous = ENV["HIVE_BENCH_ALLOW_DISABLED_PLAN_REVIEW"]
      ENV["HIVE_BENCH_ALLOW_DISABLED_PLAN_REVIEW"] = "1"
      config = Hive::Config.load(project)

      assert_equal [ "Read", "Write", "Edit", "Bash(*)" ], config.dig("permissions", "tools")
      refute config.dig("agents", "opencode").key?("isolation")
    ensure
      ENV["HIVE_BENCH_ALLOW_DISABLED_PLAN_REVIEW"] = previous
    end
  end

  def test_packaged_runtime_resolves_the_immutable_inherited_dogfood_deployment
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    Dir.mktmpdir("hive-bench-dogfood-runtime") do |tmp|
      state_root = File.join(tmp, "state", "hive")
      staging = File.join(state_root, "deployments", "staging")
      gem_home = File.join(tmp, "gem-home")
      wrapper_dir = File.join(tmp, "bin")
      FileUtils.mkdir_p([ File.join(staging, "bin"), File.join(staging, "lib"), gem_home, wrapper_dir ])
      File.write(File.join(staging, "bin", "hive"), "#!/bin/sh\nprintf '0.7.2\\n'\n")
      FileUtils.chmod(0o755, File.join(staging, "bin", "hive"))
      File.write(File.join(staging, "lib", "hive.rb"), "# complete runtime\n")
      File.write(File.join(wrapper_dir, "hive"), "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, File.join(wrapper_dir, "hive"))
      system("git", "-C", staging, "init", "-q", "-b", "main", exception: true)
      system("git", "-C", staging, "config", "user.email", "bench@example.com", exception: true)
      system("git", "-C", staging, "config", "user.name", "Bench Test", exception: true)
      system("git", "-C", staging, "add", ".", exception: true)
      system("git", "-C", staging, "commit", "-qm", "dogfood runtime", exception: true)
      build_sha, = Open3.capture2("git", "-C", staging, "rev-parse", "HEAD")
      build_sha = build_sha.strip
      deployment_id = "hive-dogfood-#{build_sha[0, 9]}"
      deployment = File.join(state_root, "deployments", deployment_id)
      FileUtils.mv(staging, deployment)

      script = <<~'RUBY'
        require "json"
        require "lib/hive_driver"
        puts JSON.generate(HiveBench::HiveDriver.allocate.send(:active_hive_runtime))
      RUBY
      env = {
        "PATH" => "#{wrapper_dir}:#{ENV.fetch("PATH")}",
        "HB_HIVE_BIN" => nil,
        "HB_HIVE_GEM_HOME" => gem_home,
        "HIVE_RUNTIME_CHANNEL" => "dogfood",
        "HIVE_RUNTIME_DEPLOYMENT_ID" => deployment_id,
        "HIVE_RUNTIME_BUILD_SHA" => build_sha,
        "HIVE_DOGFOOD_STATE_ROOT" => state_root
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{harness}", "-e", script)

      assert status.success?, out + err
      runtime = JSON.parse(out)
      assert_equal deployment, runtime.fetch("root")
      assert_equal gem_home, runtime.fetch("gem_home")
      assert_equal "0.7.2", runtime.fetch("version")
    end
  end

  def test_packaged_runtime_gives_candidates_only_the_historical_base_git_object
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    Dir.mktmpdir("hive-bench-source-history") do |source|
      git = lambda do |*args|
        out, err, status = Open3.capture3("git", "-C", source, *args)
        assert status.success?, err
        out.strip
      end
      git.call("init", "-q", "-b", "main")
      git.call("config", "user.email", "bench@example.com")
      git.call("config", "user.name", "Bench Test")
      File.write(File.join(source, "value.txt"), "base\n")
      git.call("add", "value.txt")
      git.call("commit", "-qm", "historical base")
      base = git.call("rev-parse", "HEAD")
      File.write(File.join(source, "value.txt"), "gold answer\n")
      git.call("commit", "-qam", "public reference solution")
      reference = git.call("rev-parse", "HEAD")
      target = File.join(source, "candidate")
      script = <<~'RUBY'
        require "lib/hive_driver"
        HiveBench::HiveDriver.allocate.send(:setup_repo, *ARGV)
      RUBY

      _out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{harness}", "-e", script, source, base, target
      )

      assert status.success?, err
      shallow, = Open3.capture2("git", "-C", target, "rev-parse", "--is-shallow-repository")
      assert_equal "true", shallow.strip
      visible, = Open3.capture2("git", "-C", target, "log", "--all", "--format=%H")
      assert_equal [ base ], visible.lines.map(&:strip)
      _missing, _err, reference_status = Open3.capture3(
        "git", "-C", target, "cat-file", "-e", "#{reference}^{commit}"
      )
      refute reference_status.success?, "reference solution object leaked into candidate clone"
      assert_equal [], Dir.glob(File.join(target, ".git", "refs", "remotes", "**", "*"))
    end
  end

  def test_packaged_runtime_records_and_enforces_provider_only_generation_egress
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "json"
      require "profiles/candidates"
      require "lib/hive_driver"
      driver = HiveBench::HiveDriver.allocate
      candidate = HiveBench::Candidates.by_id("all-ox-alpha@max")
      identity = driver.send(
        :generation_identity,
        { "task_id" => "task" }, candidate, "base",
        hive_runtime: { version: "test" }
      )
      puts JSON.generate(
        "network" => driver.send(:network_args),
        "environment" => driver.send(:env_args, candidate),
        "identity" => identity
      )
    RUBY
    env = {
      "HB_REQUIRE_EGRESS_ALLOWLIST" => "1",
      "HB_GEN_NETWORK" => "bench-provider-only",
      "HB_GEN_HTTPS_PROXY" => "http://bench-egress:3128"
    }

    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, err
    payload = JSON.parse(out)
    assert_equal [ "--network", "bench-provider-only" ], payload.fetch("network")
    proxy_env = payload.fetch("environment")
    %w[HTTPS_PROXY HTTP_PROXY ALL_PROXY].each do |name|
      assert_includes proxy_env, "#{name}=http://bench-egress:3128"
    end
    assert_includes proxy_env, "NODE_USE_ENV_PROXY=1"
    assert_equal 2, payload.dig("identity", "schema_version")
    assert_equal "base-only-shallow", payload.dig("identity", "isolation", "source_history")
    assert_equal "provider-allowlist", payload.dig("identity", "isolation", "generation_egress")

    _out, missing_err, missing_status = Open3.capture3(
      { "HB_REQUIRE_EGRESS_ALLOWLIST" => "1", "HB_GEN_NETWORK" => nil,
        "HB_GEN_HTTPS_PROXY" => nil },
      RbConfig.ruby, "-I#{harness}", "-e", script
    )
    refute missing_status.success?
    assert_includes missing_err, "benchmark requires provider-only generation egress"
  end

  def test_codex_judge_can_route_the_pinned_model_through_openrouter
    runtime = Hive::Workflows::Bench::RUNTIME_DIR
    harness = File.join(runtime, "harness")

    Dir.mktmpdir("hive-bench-codex-provider") do |root|
      argv_log = File.join(root, "argv.json")
      path_log = File.join(root, "path.txt")
      codex_home_log = File.join(root, "codex-home.txt")
      cwd_log = File.join(root, "cwd.txt")
      fake_codex = File.join(root, "codex")
      fake_codex_ruby = File.join(root, "codex.rb")
      File.write(fake_codex_ruby, <<~RUBY)
        require "json"
        File.write(ENV.fetch("ARGV_LOG"), JSON.generate(ARGV))
        File.write(ENV.fetch("CODEX_HOME_LOG"), ENV.fetch("CODEX_HOME"))
        File.write(ENV.fetch("CWD_LOG"), Dir.pwd)
        STDIN.read
        puts JSON.generate(score: 7.5, reason: "routed")
      RUBY
      File.write(fake_codex, <<~'SH')
        #!/bin/sh
        printf '%s' "$PATH" >"$PATH_LOG"
        exec ruby "$FAKE_CODEX_RUBY" "$@"
      SH
      FileUtils.chmod(0o755, fake_codex)

      script = <<~RUBY
        $LOAD_PATH.unshift(#{harness.inspect})
        require "lib/codex_judge"
        abort("wrong default timeout") unless HiveBench::CodexJudge::DEFAULT_TIMEOUT == 3600
        judge = HiveBench::CodexJudge.judge_fn(
          bin: #{fake_codex.inspect},
          model: "gpt-5.6-sol",
          effort: "ultra",
          provider: "openrouter",
          provider_model: "openai/gpt-5.6-sol"
        )
        verdict = judge.call(prompt: "judge this", seed: 1)
        abort("wrong verdict") unless verdict[:score] == 7.5
        require "lib/judge_provenance"
        metadata = HiveBench::JudgeProvenance.metadata(
          "gpt-5.6-sol",
          efforts: { "gpt-5.6-sol" => "ultra" },
          routes: {
            "gpt-5.6-sol" => {
              provider: "openrouter",
              provider_model: "openai/gpt-5.6-sol"
            }
          }
        )
        abort("missing provider provenance") unless metadata == {
          "reasoning_effort" => "ultra",
          "reasoning_effort_explicit" => true,
          "judge_provider" => "openrouter",
          "judge_provider_model" => "openai/gpt-5.6-sol"
        }
      RUBY
      env = {
        "ARGV_LOG" => argv_log,
        "PATH_LOG" => path_log,
        "CODEX_HOME_LOG" => codex_home_log,
        "CWD_LOG" => cwd_log,
        "FAKE_CODEX_RUBY" => fake_codex_ruby,
        "CODEX_HOME" => "/operator-profile-canary",
        "OPENROUTER_API_KEY" => "secret-canary"
      }

      _out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)

      assert status.success?, err
      argv = JSON.parse(File.read(argv_log))
      assert_equal root, File.read(path_log).split(File::PATH_SEPARATOR).first
      judge_codex_home = File.read(codex_home_log)
      judge_cwd = File.read(cwd_log)
      refute_equal "/operator-profile-canary", judge_codex_home
      refute_equal root, judge_cwd
      refute_path_exists judge_codex_home
      refute_path_exists judge_cwd
      assert_equal "openai/gpt-5.6-sol", argv.fetch(argv.index("-m") + 1)
      assert_includes argv, "--ephemeral"
      assert_includes argv, "--ignore-user-config"
      assert_includes argv, "--ignore-rules"
      assert_includes argv, 'model_provider="openrouter"'
      assert_includes argv, 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"'
      assert_includes argv, 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"'
      assert_includes argv, 'model_providers.openrouter.wire_api="responses"'
      assert_includes argv, "model_providers.openrouter.requires_openai_auth=false"
      assert_includes argv, "model_reasoning_effort=ultra"
      refute argv.any? { |arg| arg.include?("secret-canary") }
    end
  end

  def test_codex_judge_keeps_chatgpt_auth_home_but_uses_an_empty_ephemeral_workspace
    runtime = Hive::Workflows::Bench::RUNTIME_DIR
    harness = File.join(runtime, "harness")

    Dir.mktmpdir("hive-bench-codex-chatgpt") do |root|
      operator_codex_home = File.join(root, "operator-codex-home")
      FileUtils.mkdir_p(operator_codex_home)
      argv_log = File.join(root, "argv.json")
      codex_home_log = File.join(root, "codex-home.txt")
      cwd_log = File.join(root, "cwd.txt")
      fake_codex = File.join(root, "codex")
      fake_codex_ruby = File.join(root, "codex.rb")
      File.write(fake_codex_ruby, <<~RUBY)
        require "json"
        File.write(ENV.fetch("ARGV_LOG"), JSON.generate(ARGV))
        File.write(ENV.fetch("CODEX_HOME_LOG"), ENV.fetch("CODEX_HOME"))
        File.write(ENV.fetch("CWD_LOG"), Dir.pwd)
        STDIN.read
        puts JSON.generate(score: 8.0, reason: "subscription route")
      RUBY
      File.write(fake_codex, <<~'SH')
        #!/bin/sh
        exec ruby "$FAKE_CODEX_RUBY" "$@"
      SH
      FileUtils.chmod(0o755, fake_codex)

      script = <<~RUBY
        $LOAD_PATH.unshift(#{harness.inspect})
        require "lib/codex_judge"
        verdict = HiveBench::CodexJudge.judge_fn(
          bin: #{fake_codex.inspect},
          model: "gpt-5.6-sol",
          effort: "ultra",
          provider: "chatgpt"
        ).call(prompt: "judge this", seed: 1)
        abort("wrong verdict") unless verdict[:score] == 8.0
      RUBY
      env = {
        "ARGV_LOG" => argv_log,
        "CODEX_HOME_LOG" => codex_home_log,
        "CWD_LOG" => cwd_log,
        "FAKE_CODEX_RUBY" => fake_codex_ruby,
        "CODEX_HOME" => operator_codex_home
      }

      _out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)

      assert status.success?, err
      argv = JSON.parse(File.read(argv_log))
      judge_cwd = File.read(cwd_log)
      assert_equal operator_codex_home, File.read(codex_home_log)
      assert_path_exists operator_codex_home
      refute_equal root, judge_cwd
      refute_path_exists judge_cwd
      assert_includes argv, "--ephemeral"
      assert_includes argv, "--ignore-user-config"
      assert_includes argv, "--ignore-rules"
      assert_equal "gpt-5.6-sol", argv.fetch(argv.index("-m") + 1)
      assert_includes argv, "model_reasoning_effort=ultra"
    end
  end

  def test_judge_stage_maps_codex_openrouter_campaign_fields_to_harness_arguments
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    prefix = instruction.split("\n' >.judge-args.out", 2).first
    args_script = prefix.rpartition("ruby -ryaml -e '\n").last
    refute_empty args_script

    Dir.mktmpdir("hive-bench-judge-route") do |root|
      File.write(File.join(root, "campaign.yml"), <<~YAML)
        judges:
          claude:
            model: claude-fable-5
          codex:
            model: gpt-5.6-sol
            reasoning_effort: ultra
            provider: openrouter
            provider_model: openai/gpt-5.6-sol
          openrouter:
      YAML

      out, err, status = Open3.capture3(RbConfig.ruby, "-ryaml", "-e", args_script, chdir: root)

      assert status.success?, err
      assert_equal [
        "--claude-judge", "--judge-model", "claude-fable-5",
        "--codex-judge", "--codex-judge-model", "gpt-5.6-sol",
        "--codex-judge-effort", "ultra",
        "--codex-judge-provider", "openrouter",
        "--codex-judge-provider-model", "openai/gpt-5.6-sol",
        "--no-openrouter-judge"
      ], out.lines.map(&:chomp)
    end
  end

  def test_judge_runtime_guard_rejects_a_pre_retry_snapshot_with_refresh_guidance
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    waiting = instruction.match(
      /(?<body>write_waiting\(\) \{.*?\n\})\n\nwrite_limits_reached\(\)/m
    )&.[](:body)
    guard = instruction.match(
      /(?<body>require_bench_judge_runtime\(\) \{.*?\n\})\n\nif ! require_bench_judge_runtime/m
    )&.[](:body)
    refute_nil waiting, "judge instruction must expose write_waiting"
    refute_nil guard, "judge instruction must expose its runtime capability guard"

    Dir.mktmpdir("hive-bench-old-runtime") do |root|
      harness = File.join(root, "harness")
      FileUtils.mkdir_p(harness)
      File.write(File.join(harness, "hive_run.rb"), "# old runtime\n")
      File.write(File.join(harness, "rejudge.rb"), "module HiveBench; module Rejudge; end; end\n")
      state_file = File.join(root, "judge.md")
      File.write(state_file, "# Judge\n<!-- AGENT_WORKING -->\n")
      shell = <<~BASH
        set -euo pipefail
        STATE_FILE="$1"
        BENCH_ROOT="$2"
        #{waiting}
        #{guard}
        require_bench_judge_runtime
      BASH

      _out, err, status = Open3.capture3(
        { "RUBYLIB" => File.expand_path("../../../lib", __dir__) },
        "bash", "-c", shell, "--", state_file, root
      )

      assert_equal 1, status.exitstatus, err
      body = File.read(state_file)
      assert_includes body, "predates automatic judge retries"
      assert_includes body, "hive init . --workflow bench"
      assert_equal :waiting, Hive::Markers.current(state_file).name
    end
  end

  def test_packaged_runtime_uses_hive_model_routing_for_flagship_candidates
    runtime = Hive::Workflows::Bench::RUNTIME_DIR
    config = File.read(File.join(runtime, "harness", "lib", "hive_config.rb"))
    stages = File.read(File.join(runtime, "harness", "lib", "hive_stages.sh"))
    candidates = File.read(File.join(runtime, "harness", "profiles", "candidates.rb"))

    assert_includes config, 'config["models"] = models'
    assert_includes config, '"review_reviewers"'
    refute_includes stages, "HB_CODEX_MODEL_"
    refute_includes stages, "HB_GROK_MODEL"
    assert_includes candidates, "opus-5-plan@xhigh->sol-exec@high+sol-opus-review"
    assert_includes candidates, "fable-5-plan@xhigh->sol-exec@high+sol-opus-review"
  end

  def test_failed_rollback_warns_without_masking_the_original_install_error
    ops = Object.new
    ops.define_singleton_method(:hive_state_path) { "/unused/hive-state" }
    ops.define_singleton_method(:run_git!) { |*| raise "index reset failed" }

    _out, err = capture_io do
      Hive::Workflows::Bench.rollback_failed_install!(
        ops,
        destination: "/unused/bench-runtime",
        backup: "/unused/bench-runtime.previous",
        migration_pathspecs: [],
        pathspecs: [ "bench-runtime" ],
        runtime_backed_up: false,
        runtime_installed: false
      )
    end

    assert_includes err, "failed to fully roll back bench runtime installation"
    assert_includes err, "RuntimeError: index reset failed"
  end

  def test_failed_runtime_removal_retains_backup_instead_of_nesting_it
    Dir.mktmpdir("hive-bench-rollback") do |hive_state|
      destination = File.join(hive_state, "bench-runtime")
      backup = File.join(hive_state, "bench-runtime.previous")
      FileUtils.mkdir_p(destination)
      FileUtils.mkdir_p(backup)
      File.write(File.join(destination, "new.txt"), "new runtime\n")
      File.write(File.join(backup, "old.txt"), "old runtime\n")
      events = []
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }
      ops.define_singleton_method(:run_git!) { |*| events << :reset }
      original_rm_r = FileUtils.method(:rm_r)
      failing_rm_r = lambda do |path, *args, **kwargs|
        events << :remove
        raise Errno::EACCES, path if path == destination

        original_rm_r.call(path, *args, **kwargs)
      end

      _out, err = capture_io do
        with_replaced_singleton_method(FileUtils, :rm_r, failing_rm_r) do
          Hive::Workflows::Bench.rollback_failed_install!(
            ops,
            destination: destination,
            backup: backup,
            migration_pathspecs: [],
            pathspecs: [ "bench-runtime" ],
            runtime_backed_up: true,
            runtime_installed: true
          )
        end
      end

      assert_equal :reset, events.first
      assert_equal "new runtime\n", File.read(File.join(destination, "new.txt"))
      assert_equal "old runtime\n", File.read(File.join(backup, "old.txt"))
      refute_path_exists File.join(destination, File.basename(backup))
      assert_includes err, "previous bench runtime retained at #{backup}"
      assert_includes err, "Errno::EACCES"
    end
  end

  def test_nonlegacy_descriptor_is_left_in_place_and_releases_directory_pin
    Dir.mktmpdir("hive-bench-custom") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(File.join(workflows, "bench"))
      descriptor = File.join(workflows, "bench.yml")
      File.write(descriptor, <<~YAML)
        id: bench
        stages:
          - name: inbox
            kind: terminal
            state_file: task.md
      YAML
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }

      migration = Hive::Workflows::Bench.archive_legacy_project_workflow!(ops)

      assert_empty migration.fetch(:pathspecs)
      assert_nil migration.fetch(:handle)
      assert_path_exists descriptor
    end
  end

  def test_failed_rollback_reports_a_missing_previous_runtime_backup
    Dir.mktmpdir("hive-bench-missing-backup") do |hive_state|
      destination = File.join(hive_state, "bench-runtime")
      backup = File.join(hive_state, "bench-runtime.previous")
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }
      ops.define_singleton_method(:run_git!) { |*| "" }

      _out, err = capture_io do
        Hive::Workflows::Bench.rollback_failed_install!(
          ops,
          destination: destination,
          backup: backup,
          migration_pathspecs: [],
          pathspecs: [ "bench-runtime" ],
          runtime_backed_up: true,
          runtime_installed: false
        )
      end

      assert_includes err, "previous bench runtime backup is missing at #{backup}"
    end
  end

  def test_directory_pin_rejects_a_different_opened_inode_and_closes_on_error
    Dir.mktmpdir("hive-bench-pin") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(workflows)
      Dir.mktmpdir("hive-bench-other") do |other|
        replacement = ->(_handle) { other }

        error = with_replaced_singleton_method(
          Hive::Workflows::Bench, :pinned_directory_path, replacement
        ) do
          assert_raises(Hive::ConfigError) do
            Hive::Workflows::Bench.pin_workflows_directory!(hive_state, workflows)
          end
        end

        assert_includes error.message, "workflows directory changed"
      end
    end
  end

  def test_close_directory_handle_tolerates_an_already_closed_handle
    handle = Object.new
    handle.define_singleton_method(:close) { raise IOError, "closed directory" }

    assert_nil Hive::Workflows::Bench.close_directory_handle(handle)
  end

  def test_pinned_directory_path_fails_closed_without_a_supported_fd_path
    handle = Object.new
    handle.define_singleton_method(:fileno) { 99_999 }
    original_directory = File.method(:directory?)
    unavailable = lambda do |path|
      if path == "/proc/self/fd/99999" || path == "/dev/fd/99999"
        false
      else
        original_directory.call(path)
      end
    end

    error = with_replaced_singleton_method(File, :directory?, unavailable) do
      assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.pinned_directory_path(handle)
      end
    end

    assert_includes error.message, "cannot safely pin"
  end

  def test_parent_validation_rejects_a_reappeared_descriptor_and_missing_parent
    Dir.mktmpdir("hive-bench-parent") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(workflows)
      handle = Dir.open(workflows)
      stat = File.stat(workflows)
      migration = {
        handle: handle,
        root: Hive::Workflows::Bench.pinned_directory_path(handle),
        dev: stat.dev,
        ino: stat.ino
      }
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }

      File.write(File.join(workflows, "bench.yml"), "custom\n")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_parent!(ops, migration)
      end
      assert_includes error.message, "descriptor path reappeared before commit"

      FileUtils.mv(workflows, "#{workflows}.moved")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_parent!(ops, migration)
      end
      assert_includes error.message, "cannot validate legacy bench workflows directory"
    ensure
      Hive::Workflows::Bench.close_directory_handle(handle)
    end
  end

  def test_commit_detection_preserves_files_when_head_cannot_be_read
    ops = Object.new
    ops.define_singleton_method(:hive_state_path) { "/unused/hive-state" }
    ops.define_singleton_method(:run_git!) { |*| raise Hive::GitError, "head unavailable" }

    _out, err = capture_io do
      assert Hive::Workflows::Bench.commit_landed?(ops, "before")
    end

    assert_includes err, "could not determine whether bench migration committed"
    assert_includes err, "head unavailable"
  end

  def test_descriptor_snapshot_errors_are_normalized_as_config_errors
    missing = File.join(Dir.tmpdir, "missing-bench-descriptor-#{Process.pid}")
    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Bench.read_descriptor_snapshot!(missing)
    end
    assert_includes error.message, "cannot read legacy bench descriptor safely"

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Bench.parse_descriptor_snapshot!({ content: "[" }, missing)
    end
    assert_includes error.message, "is not valid YAML"
  end

  def test_instruction_archive_cleanup_runs_after_an_unexpected_publish_error
    Dir.mktmpdir("hive-bench-publish") do |root|
      source = File.join(root, "staged")
      destination = File.join(root, "archive")
      FileUtils.mkdir_p(source)
      original_rename = File.method(:rename)
      failing_rename = lambda do |from, to|
        result = original_rename.call(from, to)
        raise "publish interrupted after rename" if from == source && to == destination

        result
      end

      error = with_replaced_singleton_method(File, :rename, failing_rename) do
        assert_raises(RuntimeError) do
          Hive::Workflows::Bench.publish_instruction_archive!(source, destination)
        end
      end

      assert_includes error.message, "publish interrupted after rename"
      refute_path_exists destination
    end
  end

  def test_migration_path_validation_rejects_wrong_type_escape_and_missing_path
    Dir.mktmpdir("hive-bench-paths") do |hive_state|
      directory = File.join(hive_state, "directory")
      FileUtils.mkdir_p(directory)
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_path!(hive_state, directory, expected: :file)
      end
      assert_includes error.message, "expected file"

      Dir.mktmpdir("hive-bench-external") do |external|
        outside = File.join(external, "bench.yml")
        File.write(outside, "external\n")
        error = assert_raises(Hive::ConfigError) do
          Hive::Workflows::Bench.validate_migration_path!(hive_state, outside, expected: :file)
        end
        assert_includes error.message, "outside hive state"
      end

      missing = File.join(hive_state, "missing.yml")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_path!(hive_state, missing, expected: :file)
      end
      assert_includes error.message, "cannot validate legacy bench migration path"
    end
  end

  def test_generate_selects_the_sol_runner_for_stage_specific_5_6_models
    instruction = File.read(stages_by_name.fetch("generate").instruction)

    assert_includes instruction, "profile.codex_models"
    assert_includes instruction, 'start_with?("gpt-5.6-")'
    assert_includes instruction, "HB_RUNNER_IMAGE=hive-bench-runner:sol"
  end

  def test_generate_surfaces_provider_only_pending_cells_as_daemon_retryable_limits
    instruction = File.read(stages_by_name.fetch("generate").instruction)

    assert_includes instruction, "write_limits_reached()"
    assert_includes instruction, "exit(quota_only ? 75 : 2)"
    assert_includes instruction, 'if [ "$outcome_status" -eq 75 ]'
    assert_includes instruction, "Hive::Markers.set("
    assert_includes instruction, '"reason" => "limits_reached"'
    assert_includes instruction, '"retry_after" => ARGV.fetch(1)'
  end

  def test_generate_starts_every_unbought_cell_before_reaping_results
    instruction = File.read(stages_by_name.fetch("generate").instruction)
    launch = instruction.index('(cd "$REPO_ROOT" && bash -c "$command" </dev/null) 2>"$err_path" &')
    record_pid = instruction.index('generate_pids+=("$!")')
    launch_loop_end = instruction.index("done <.generate-commands", record_pid)
    wait_loop = instruction.index('for index in "${!generate_pids[@]}"', launch_loop_end)
    reap = instruction.index('wait "${generate_pids[$index]}"', wait_loop)

    refute_nil launch
    refute_nil record_pid
    refute_nil launch_loop_end
    refute_nil wait_loop
    refute_nil reap
    assert_operator launch, :<, launch_loop_end
    assert_operator record_pid, :<, launch_loop_end
    assert_operator launch_loop_end, :<, wait_loop
    assert_operator wait_loop, :<, reap
    assert_includes instruction, 'err_path=".generate-cmd-${generate_index}.err"'
    assert_includes instruction, "trap 'rm -f .generate-validate.out"
    assert_includes instruction, ".generate-cmd-*.err"
  end

  def test_generate_hands_a_preserved_nonterminal_patch_to_judge_without_regeneration
    instruction = File.read(stages_by_name.fetch("generate").instruction)
    validator = instruction.match(
      /set \+e\nruby -ryaml -rjson -e '\n(?<code>.*?)\n' "\$REPO_ROOT" >\.generate-outcome\.out/m
    )
    refute_nil validator, "generate instruction must expose its outcome validator"
    validator_code = validator[:code].gsub(%q('"'"'), "'")

    Dir.mktmpdir("hive-bench-paid-patch") do |root|
      task_dir = File.join(root, "task")
      run_dir = File.join(root, "runs", "paid-patch", "candidate-one--task-one")
      patch_dir = File.join(run_dir, "task-one", "candidate_one", "target")
      FileUtils.mkdir_p([ task_dir, patch_dir ])
      File.write(
        File.join(task_dir, "campaign.yml"),
        {
          "campaign_id" => "paid-patch",
          "tasks" => [ "task-one" ],
          "candidates" => [ "candidate-one" ],
          "exclusions" => []
        }.to_yaml
      )
      result = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "run_status" => "execute_failed",
          "judges" => {}
        } ],
        "pending" => [],
        "failed" => []
      }
      results_path = File.join(run_dir, "results.json")
      File.write(results_path, JSON.generate(result))
      patch_path = File.join(patch_dir, "candidate.patch")
      File.write(patch_path, "diff --git a/file b/file\n")

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator_code, root,
        chdir: task_dir
      )

      assert status.success?, out + err
      assert_empty out
      assert_empty err

      File.write(patch_path, "")
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator_code, root,
        chdir: task_dir
      )

      assert_equal 2, status.exitstatus, out + err
      assert_includes out, "UNFINISHED candidate-one/task-one: judges_pending"
      assert_empty err

      File.write(patch_path, "diff --git a/file b/file\n")
      File.write(results_path, JSON.generate(result.merge("failed" => [ { "reason" => "agent failed" } ])))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator_code, root,
        chdir: task_dir
      )

      assert_equal 2, status.exitstatus, out + err
      assert_includes out, "agent failed"
      assert_empty err
    end
  end

  def test_generate_strict_execution_refuses_a_preserved_execute_failed_patch
    instruction = File.read(stages_by_name.fetch("generate").instruction)
    validator = instruction.match(
      /set \+e\nruby -ryaml -rjson -e '\n(?<code>.*?)\n' "\$REPO_ROOT" >\.generate-outcome\.out/m
    )
    refute_nil validator, "generate instruction must expose its outcome validator"
    validator_code = validator[:code].gsub(%q('"'"'), "'")

    Dir.mktmpdir("hive-bench-strict-execution") do |root|
      task_dir = File.join(root, "task")
      run_dir = File.join(root, "runs", "strict-run", "candidate-one--task-one")
      patch_dir = File.join(run_dir, "task-one", "candidate_one", "target")
      FileUtils.mkdir_p([ task_dir, patch_dir ])
      File.write(
        File.join(task_dir, "campaign.yml"),
        {
          "campaign_id" => "strict-run",
          "require_successful_execution" => true,
          "tasks" => [ "task-one" ],
          "candidates" => [ "candidate-one" ],
          "exclusions" => []
        }.to_yaml
      )
      File.write(
        File.join(run_dir, "results.json"),
        JSON.generate(
          "cells" => [ {
            "task_id" => "task-one",
            "agent_id" => "candidate-one",
            "run_status" => "execute_failed",
            "judges" => {}
          } ],
          "pending" => [],
          "failed" => []
        )
      )
      File.write(
        File.join(patch_dir, "candidate.patch"),
        "diff --git a/file b/file\n"
      )

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator_code, root,
        chdir: task_dir
      )

      assert_equal 2, status.exitstatus, out + err
      assert_includes out,
                      "UNFINISHED candidate-one/task-one: execute_failed — " \
                      "campaign requires successful execution"
      assert_empty err
    end
  end

  def test_generate_quota_marker_has_canonical_recovery_identity
    instruction = File.read(stages_by_name.fetch("generate").instruction)
    function = instruction.match(
      /(?<body>write_limits_reached\(\) \{.*?\n\})\n\nwrite_complete\(\)/m
    )&.[](:body)
    refute_nil function, "generate instruction must expose write_limits_reached"

    Dir.mktmpdir("hive-bench-quota-marker") do |dir|
      state_file = File.join(dir, "generate.md")
      File.write(state_file, "# Generate\n<!-- AGENT_WORKING -->\n")
      ruby_lib = [ File.expand_path("../../../lib", __dir__), ENV["RUBYLIB"] ].compact
        .join(File::PATH_SEPARATOR)
      shell = <<~BASH
        set -euo pipefail
        STATE_FILE="$1"
        #{function}
        write_limits_reached "provider limit"
      BASH

      _out, err, status = Open3.capture3(
        { "RUBYLIB" => ruby_lib, "HIVE_LIMITS_RETRY_COOLDOWN_SEC" => "60" },
        "bash", "-c", shell, "--", state_file
      )

      assert status.success?, err
      marker = Hive::Markers.current(state_file)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      assert_match(/\A[0-9a-f]{16}\z/, marker.attrs.fetch("marker_id"))
      refute_nil Hive::Markers.recovery_match_attr(marker.attrs)
    end
  end

  def test_judge_pre_deliberation_gate_classifies_provider_limited_missing_slate_for_retry
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    validator = instruction.match(
      /ruby -I"\$BENCH_ROOT\/harness" -ryaml -rjson -rlib\/judge_slate -e '\n(?<code>.*?)\n' "\$REPO_ROOT\/\$RESULTS" \.judge-rejudge\.err/m
    )
    refute_nil validator, "judge instruction must expose its pre-deliberation slate validator"

    gate_position = instruction.index(validator[0])
    deliberation_position = instruction.index("harness/deliberate.rb")
    refute_nil deliberation_position, "judge instruction must invoke deliberate.rb"
    assert_operator gate_position, :<, deliberation_position,
                    "the complete judge slate must be required before deliberation spends"

    Dir.mktmpdir("hive-bench-judge-slate") do |root|
      campaign = {
        "campaign_id" => "slate-test",
        "source" => "unused",
        "seeds" => 3,
        "tasks" => [ "task-one" ],
        "candidates" => [ "candidate-one" ],
        "exclusions" => [],
        "judges" => {
          "claude" => { "model" => "claude-fable-5" },
          "codex" => { "model" => "gpt-5.6-sol", "reasoning_effort" => "ultra" }
        }
      }
      results = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "run_status" => "generated",
          "judges" => {
            "gpt-5.6-sol" => { "sample_count" => 3, "reasoning_effort" => "ultra" }
          }
        } ]
      }
      campaign_path = File.join(root, "campaign.yml")
      results_path = File.join(root, "results.json")
      stderr_path = File.join(root, "rejudge.err")
      File.write(campaign_path, campaign.to_yaml)
      File.write(results_path, JSON.generate(results))
      failure_event = lambda do |judge, limits_reached|
        "HIVE_BENCH_JUDGE_FAILURE #{JSON.generate(
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "judge" => judge,
          "limits_reached" => limits_reached,
          "detail" => "provider failure"
        )}\n"
      end
      File.write(stderr_path, failure_event.call("fable-5", true))
      runtime_harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )

      assert_equal 75, status.exitstatus, "provider quota must request daemon retry: #{out}#{err}"
      assert_empty err
      assert_includes out, "MISSING_JUDGES candidate-one task-one"

      File.write(stderr_path, failure_event.call("fable-5", false))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )

      assert_equal 2, status.exitstatus, "non-quota judge failures must remain manual: #{out}#{err}"
      assert_empty err

      sol_record = results.dig("cells", 0, "judges").delete("gpt-5.6-sol")
      File.write(results_path, JSON.generate(results))
      File.write(
        stderr_path,
        failure_event.call("fable-5", true) + failure_event.call("gpt-5.6-sol", false)
      )
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )

      assert_equal 2, status.exitstatus,
                   "an unrelated quota must not excuse a non-quota incomplete judge: #{out}#{err}"
      assert_empty err

      results.dig("cells", 0, "judges")["gpt-5.6-sol"] = sol_record

      results.dig("cells", 0, "judges")["fable-5"] = {
        "sample_count" => 2,
        "reasoning_effort" => "unspecified"
      }
      File.write(results_path, JSON.generate(results))
      File.write(stderr_path, failure_event.call("fable-5", true))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )
      assert_equal 75, status.exitstatus,
                   "matching quota evidence must retry an undersampled judge: #{out}#{err}"
      assert_includes out, "UNDERSAMPLED_JUDGE candidate-one task-one fable-5"

      File.write(stderr_path, "HIVE_BENCH_JUDGE_FAILURE 5\n")
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus,
                   "an undersampled judge without exact quota evidence must remain manual: #{out}#{err}"

      results.dig("cells", 0, "judges", "gpt-5.6-sol")["reasoning_effort"] = "high"
      File.write(results_path, JSON.generate(results))
      File.write(stderr_path, failure_event.call("fable-5", true))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus,
                   "an effort mismatch must remain manual even beside quota evidence: #{out}#{err}"
      assert_includes out, "JUDGE_EFFORT_MISMATCH candidate-one task-one gpt-5.6-sol"
      results.dig("cells", 0, "judges", "gpt-5.6-sol")["reasoning_effort"] = "ultra"

      expected_cell = results.fetch("cells").first
      results["cells"] = []
      File.write(results_path, JSON.generate(results))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "a missing cell must remain manual: #{out}#{err}"
      assert_includes out, "MISSING_CELL candidate-one task-one"

      results["cells"] = [ expected_cell, expected_cell.merge("task_id" => "unexpected-task") ]
      File.write(results_path, JSON.generate(results))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "an unexpected cell must remain manual: #{out}#{err}"
      assert_includes out, "UNEXPECTED_CELL candidate-one unexpected-task"

      results["cells"] = [ expected_cell ]

      results.dig("cells", 0, "judges")["fable-5"] = {
        "sample_count" => 3,
        "reasoning_effort" => "unspecified"
      }
      File.write(results_path, JSON.generate(results))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )

      assert status.success?, "a complete judge slate must pass: #{out}#{err}"
      assert_empty out
      assert_empty err

      campaign["require_successful_execution"] = true
      results.dig("cells", 0)["run_status"] = "execute_failed"
      File.write(campaign_path, campaign.to_yaml)
      File.write(results_path, JSON.generate(results))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, stderr_path,
        chdir: root
      )

      assert_equal 2, status.exitstatus,
                   "strict campaigns must not judge failed execution: #{out}#{err}"
      assert_includes out, "INVALID_RUN_STATUS candidate-one task-one execute_failed"
      assert_empty err
    end
  end

  def test_judge_quota_marker_has_canonical_recovery_identity
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    function = instruction.match(
      /(?<body>write_limits_reached\(\) \{.*?\n\})\n\nwrite_complete\(\)/m
    )&.[](:body)
    refute_nil function, "judge instruction must expose write_limits_reached"

    Dir.mktmpdir("hive-bench-judge-quota-marker") do |dir|
      state_file = File.join(dir, "judge.md")
      File.write(
        state_file,
        "# Judge\n<!-- AGENT_WORKING -->\n" +
          ("x" * (Hive::Markers::MAX_MARKER_SCAN_BYTES + 1))
      )
      ruby_lib = [ File.expand_path("../../../lib", __dir__), ENV["RUBYLIB"] ].compact
        .join(File::PATH_SEPARATOR)
      shell = <<~BASH
        set -euo pipefail
        STATE_FILE="$1"
        #{function}
        write_limits_reached "provider limit"
      BASH

      _out, err, status = Open3.capture3(
        { "RUBYLIB" => ruby_lib, "HIVE_LIMITS_RETRY_COOLDOWN_SEC" => "60" },
        "bash", "-c", shell, "--", state_file
      )

      assert status.success?, err
      marker = Hive::Markers.current(state_file)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      assert_match(/\A[0-9a-f]{16}\z/, marker.attrs.fetch("marker_id"))
      refute_nil Hive::Markers.recovery_match_attr(marker.attrs)
      assert_operator Time.iso8601(marker.attrs.fetch("retry_after")), :>, Time.now.utc
    end
  end

  def test_rejudge_uses_typed_provider_limit_evidence_without_trusting_model_output
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~RUBY
      require "rejudge"
      limits = ->(**) { raise HiveBench::ProviderLimitError, "provider usage limit" }
      prose = ->(**) { raise "judge output discussed HTTP 429 rate limit exceeded" }
      result = HiveBench::Rejudge.judge_all(
        { "fable-5" => limits, "gpt-5.6-sol" => prose }, "plan", "diff", nil,
        task_id: "task-one", agent_id: "candidate-one"
      )
      abort "judge should fail soft" unless result.empty?
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, out + err
    assert_empty out
    events = err.lines.filter_map do |line|
      next unless line.start_with?("HIVE_BENCH_JUDGE_FAILURE ")

      JSON.parse(line.delete_prefix("HIVE_BENCH_JUDGE_FAILURE "))
    end.to_h { |event| [ event.fetch("judge"), event ] }
    assert_equal %w[fable-5 gpt-5.6-sol], events.keys.sort
    assert_equal true, events.fetch("fable-5").fetch("limits_reached")
    assert_equal false, events.fetch("gpt-5.6-sol").fetch("limits_reached"),
                 "model-authored quota prose must not forge retry evidence"
  end

  def test_claude_judge_types_trusted_cli_quota_evidence_without_trusting_model_prose
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "lib/claude_judge"
      status = Struct.new(:exitstatus) do
        def success? = false
      end.new(1)
      responses = [
        [ "partial answer", "you've hit your usage limit", status ],
        [ "mise ~/.config/mise/config.toml tools: claude@2.1.233\n" \
          "You've hit your session limit · resets 7:40pm (Europe/London)\n", "", status ],
        [ "analysis\nYou've hit your session limit · resets 7:40pm (Europe/London)\n", "", status ],
        [ "the candidate handles HTTP 429 rate limit exceeded", "", status ]
      ]
      Open3.define_singleton_method(:capture3) { |*| responses.shift }
      judge = HiveBench::ClaudeJudge.judge_fn
      errors = 4.times.map do
        judge.call(prompt: "prompt", seed: 1)
      rescue StandardError => e
        [ e.class.name, e.message ]
      end
      abort errors.inspect unless errors.map(&:first) == [
        "HiveBench::ProviderLimitError", "HiveBench::ProviderLimitError",
        "HiveBench::JudgeOutput::Error",
        "HiveBench::JudgeOutput::Error"
      ]
      abort errors.inspect unless errors.first(2).all? { |error| error.last.start_with?("limits_reached: ") }
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, out + err
  end

  def test_deliberation_emits_typed_provider_limit_evidence_for_each_round
    harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
    script = <<~'RUBY'
      require "lib/deliberation"
      calls = Hash.new(0)
      fable = lambda do |**|
        calls[:fable] += 1
        raise HiveBench::ProviderLimitError, "provider usage limit" if calls[:fable] == 2

        { score: 7.0, reason: "initial" }
      end
      sol = ->(**) { { score: 4.0, reason: "strict", discussion: "checked" } }
      deliberation = HiveBench::Deliberation.new(
        judge_fns: { "fable-5" => fable, "gpt-5.6-sol" => sol },
        judge_template: "{{PLAN}}\n{{CANDIDATE}}\n{{REFERENCE_SECTION}}",
        deliberate_template: "{{PLAN}}\n{{CANDIDATE}}\n{{REFERENCE_SECTION}}\n{{OWN_SCORE}}\n{{OWN_REASON}}\n{{OTHER_VERDICTS}}"
      )
      verdicts = deliberation.call(
        plan: "plan", candidate_diff: "diff", reference: nil,
        task_id: "task-one", agent_id: "candidate-one"
      )
      abort verdicts.inspect unless verdicts.fetch("fable-5").final.nil?

      round_one_limit = ->(**) { raise HiveBench::ProviderLimitError, "provider usage limit" }
      round_one = HiveBench::Deliberation.new(
        judge_fns: { "fable-5" => round_one_limit, "gpt-5.6-sol" => sol },
        judge_template: "{{PLAN}}\n{{CANDIDATE}}\n{{REFERENCE_SECTION}}",
        deliberate_template: "{{PLAN}}\n{{CANDIDATE}}\n{{REFERENCE_SECTION}}\n{{OWN_SCORE}}\n{{OWN_REASON}}\n{{OTHER_VERDICTS}}"
      )
      verdicts = round_one.call(
        plan: "plan", candidate_diff: "diff", reference: nil,
        task_id: "task-two", agent_id: "candidate-one"
      )
      abort verdicts.inspect unless verdicts.empty?
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{harness}", "-e", script)

    assert status.success?, out + err
    events = err.lines.filter_map do |line|
      next unless line.start_with?("HIVE_BENCH_JUDGE_FAILURE ")

      JSON.parse(line.delete_prefix("HIVE_BENCH_JUDGE_FAILURE "))
    end.to_h { |event| [ event.fetch("task_id"), event ] }
    assert_equal %w[task-one task-two], events.keys.sort
    assert_equal "candidate-one", events.fetch("task-one").fetch("agent_id")
    assert_equal "fable-5", events.fetch("task-one").fetch("judge")
    assert_equal true, events.fetch("task-one").fetch("limits_reached")
    assert_match(/round 2/, events.fetch("task-one").fetch("detail"))
    assert_equal "candidate-one", events.fetch("task-two").fetch("agent_id")
    assert_equal "fable-5", events.fetch("task-two").fetch("judge")
    assert_equal true, events.fetch("task-two").fetch("limits_reached")
    assert_match(/round 1/, events.fetch("task-two").fetch("detail"))
  end

  def test_judge_validation_rejects_a_missing_round_two_verdict
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    skip_filter = instruction.match(
      /ruby -ryaml -rjson -e '\n(?<code>.*?)\n' "\$REPO_ROOT\/\$DELIB" "\$DELIB_SKIP"/m
    )
    refute_nil skip_filter, "judge instruction must classify retryable deliberations"
    validator_start = instruction.rindex(
      "ruby -I\"$BENCH_ROOT/harness\" -ryaml -rjson -rlib/judge_slate -e '\n"
    )
    refute_nil validator_start, "judge instruction must expose its final artifact validator"
    validator = instruction[validator_start..].match(
      /ruby -I"\$BENCH_ROOT\/harness" -ryaml -rjson -rlib\/judge_slate -e '\n(?<code>.*?)\n' "\$REPO_ROOT\/\$RESULTS" "\$REPO_ROOT\/\$DELIB" \.judge-deliberate\.err/m
    )
    refute_nil validator, "judge instruction must expose its final artifact validator"

    Dir.mktmpdir("hive-bench-judge-validator") do |root|
      campaign = {
        "campaign_id" => "validator-test",
        "source" => "unused",
        "seeds" => 1,
        "tasks" => [ "task-one" ],
        "candidates" => [ "candidate-one" ],
        "exclusions" => [],
        "judges" => {
          "claude" => { "model" => "claude-fable-5" },
          "codex" => { "model" => "gpt-5.6-sol", "reasoning_effort" => "ultra" }
        }
      }
      results = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "run_status" => "generated",
          "judges" => {
            "fable-5" => { "sample_count" => 1, "reasoning_effort" => "unspecified" },
            "gpt-5.6-sol" => { "sample_count" => 1, "reasoning_effort" => "ultra" }
          }
        } ]
      }
      verdict = lambda do |effort|
        {
          "initial" => 7.0,
          "initial_reason" => "initial reason",
          "final" => 7.0,
          "final_reason" => "final reason",
          "discussion" => "checked the other referee's claims",
          "reasoning_effort" => effort
        }
      end
      deliberation = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "judges" => {
            "fable-5" => verdict.call("unspecified"),
            "gpt-5.6-sol" => verdict.call("ultra")
          }
        } ]
      }
      campaign_path = File.join(root, "campaign.yml")
      results_path = File.join(root, "results.json")
      deliberation_path = File.join(root, "deliberation.json")
      stderr_path = File.join(root, "deliberate.err")
      runtime_harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
      File.write(campaign_path, campaign.to_yaml)
      File.write(results_path, JSON.generate(results))
      File.write(deliberation_path, JSON.generate(deliberation))
      File.write(stderr_path, "")

      skip_path = File.join(root, "skip.json")
      _out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", skip_filter[:code], deliberation_path, skip_path,
        chdir: root
      )
      assert status.success?, err
      assert_equal 1, JSON.parse(File.read(skip_path)).fetch("cells").size
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert status.success?, "complete deliberation should validate: #{out}#{err}"

      deliberation.dig("cells", 0, "judges", "gpt-5.6-sol")["final"] = nil
      File.write(deliberation_path, JSON.generate(deliberation))
      _out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", skip_filter[:code], deliberation_path, skip_path,
        chdir: root
      )
      assert status.success?, err
      assert_empty JSON.parse(File.read(skip_path)).fetch("cells"),
                   "the incomplete cell must remain eligible for a deliberation retry"

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )

      refute status.success?, "a null final verdict must keep the judge stage incomplete"
      assert_empty err
      assert_includes out, "INCOMPLETE_DELIBERATION candidate-one task-one gpt-5.6-sol"
      assert_includes out, "final"

      failure_event = lambda do |judge, limits_reached|
        "HIVE_BENCH_JUDGE_FAILURE #{JSON.generate(
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "judge" => judge,
          "limits_reached" => limits_reached,
          "detail" => "round 2 provider failure"
        )}\n"
      end
      File.write(stderr_path, failure_event.call("gpt-5.6-sol", true))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 75, status.exitstatus, "matching quota evidence must schedule retry: #{out}#{err}"

      File.write(stderr_path, failure_event.call("gpt-5.6-sol", false))
      _out, _err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "non-quota round failure must remain manual"

      File.write(
        stderr_path,
        failure_event.call("gpt-5.6-sol", true) + failure_event.call("gpt-5.6-sol", false)
      )
      _out, _err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "mixed same-judge failures must remain manual"

      File.write(stderr_path, "HIVE_BENCH_JUDGE_FAILURE {malformed\n")
      _out, _err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "malformed failure evidence must remain manual"

      deliberation.dig("cells", 0, "judges", "gpt-5.6-sol")["reasoning_effort"] = "high"
      File.write(deliberation_path, JSON.generate(deliberation))
      File.write(stderr_path, failure_event.call("gpt-5.6-sol", true))
      _out, _err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus, "effort mismatch must remain manual"
      deliberation.dig("cells", 0, "judges", "gpt-5.6-sol")["reasoning_effort"] = "ultra"
      File.write(deliberation_path, JSON.generate(deliberation))

      File.write(
        stderr_path,
        failure_event.call("gpt-5.6-sol", true) + failure_event.call("fable-5", false)
      )
      _out, _err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 2, status.exitstatus,
                   "a non-quota failure from the previously complete judge must make the retry manual"

      deliberation["cells"] = []
      File.write(deliberation_path, JSON.generate(deliberation))
      File.write(stderr_path, failure_event.call("fable-5", true))
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-I#{runtime_harness}", "-ryaml", "-rjson", "-rlib/judge_slate",
        "-e", validator[:code], results_path, deliberation_path, stderr_path,
        chdir: root
      )
      assert_equal 75, status.exitstatus,
                   "a missing transcript caused by one typed quota failure must retry: #{out}#{err}"
    end
  end

  def test_descriptor_carries_transition_verbs_after_inbox
    assert_equal [ nil, "extract", "generate", "judge", "publish", nil ],
                 descriptor.stages.map { |stage| stage.advance_verb&.name }
  end
end
