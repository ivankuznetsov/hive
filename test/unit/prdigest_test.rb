require "test_helper"
require "json"
require "yaml"
require "hive/prdigest"

class HivePrdigestTest < Minitest::Test
  include HiveTestHelper

  Status = Data.define(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def test_registry_resolves_github_identities_deduplicates_and_filters
    entries = [
      {
        "name" => "One",
        "path" => "/tmp/one",
        "repository_identity" => "github.com/Owner/One"
      },
      {
        "name" => "Duplicate",
        "path" => "/tmp/duplicate",
        "repository_identity" => "github.com/owner/one"
      },
      {
        "name" => "Two",
        "path" => "/tmp/two",
        "repository_identity" => nil
      }
    ]
    registry = Hive::Prdigest::Registry.new(
      entries: entries,
      identity_resolver: ->(path) { path == "/tmp/two" ? "github.com/Owner/Two" : nil }
    )

    assert_equal [ "Owner/One", "Owner/Two" ], registry.repositories
    assert_equal [ "Owner/Two", "Owner/One" ],
                 registry.repositories(filters: [ "owner/two", "OWNER/ONE", "owner/two" ])
  end

  def test_registry_ignores_registered_projects_that_are_not_github_repositories
    with_tmp_git_repo do |no_origin|
      entries = [
        { "name" => "GitHub", "repository_identity" => "github.com/owner/one" },
        { "name" => "Local", "repository_identity" => "local:/tmp/repo" },
        { "name" => "GitLab", "repository_identity" => "gitlab.com/owner/two" },
        { "name" => "No origin", "path" => no_origin, "repository_identity" => nil }
      ]

      assert_equal [ "owner/one" ], Hive::Prdigest::Registry.new(entries: entries).repositories
    end
  end

  def test_registry_fails_closed_for_malformed_and_invalid_github_scope
    [
      [ [ "broken" ], /entry is malformed/ ],
      [
        [ { "name" => "Invalid", "repository_identity" => "github.com/owner/repo/extra" } ],
        /does not resolve/
      ]
    ].each do |entries, message|
      error = assert_raises(Hive::ConfigError) do
        Hive::Prdigest::Registry.new(entries: entries).repositories
      end
      assert_match message, error.message
    end

    registry = Hive::Prdigest::Registry.new(
      entries: [ { "name" => "One", "repository_identity" => "github.com/owner/one" } ]
    )
    assert_raises(Hive::ConfigError) { registry.repositories(filters: [ "bad" ]) }
    assert_raises(Hive::ConfigError) { registry.repositories(filters: [ "owner/two" ]) }
  end

  def test_registry_rejects_empty_and_dot_segment_repositories
    assert_raises(Hive::ConfigError) do
      Hive::Prdigest::Registry.new(entries: []).repositories
    end

    %w[./repo owner/.. owner/repo/extra].each do |repository|
      registry = Hive::Prdigest::Registry.new(
        entries: [ { "name" => "One", "repository_identity" => "github.com/owner/one" } ]
      )
      assert_raises(Hive::ConfigError, repository) do
        registry.repositories(filters: [ repository ])
      end
    end
  end

  def test_runner_passes_registered_repositories_through_private_token_free_config
    observed = {}
    runner = build_runner(
      process_runner: lambda do |child_env, *argv|
        config_path = argv.fetch(argv.index("--config") + 1)
        observed[:mode] = File.stat(config_path).mode & 0o777
        observed[:config] = YAML.safe_load_file(config_path)
        observed[:env] = child_env
        observed[:argv] = argv
        [ JSON.generate(success_payload), "", Status.new(0) ]
      end
    )

    result = runner.call

    assert result.success?
    assert_equal 0o600, observed.fetch(:mode)
    assert_equal [ "owner/one", "owner/two" ], observed.dig(:config, "github", "repos")
    assert_equal "HIVE_PRDIGEST_GITHUB_TOKEN", observed.dig(:config, "github", "token_env")
    assert_equal "HIVE_TELEGRAM_BOT_TOKEN", observed.dig(:config, "telegram", "token_env")
    refute_includes YAML.dump(observed.fetch(:config)), "github-secret"
    refute_includes YAML.dump(observed.fetch(:config)), "telegram-secret"
    assert_equal(
      {
        "HIVE_PRDIGEST_GITHUB_TOKEN" => "github-secret",
        "HIVE_TELEGRAM_BOT_TOKEN" => "telegram-secret"
      },
      observed.fetch(:env)
    )
    assert_equal(
      [ "--repo", "owner/one", "--repo", "owner/two" ],
      observed.fetch(:argv).drop(observed.fetch(:argv).index("--repo"))
    )
  end

  def test_dry_run_needs_no_telegram_configuration_or_token
    runner = build_runner(
      dry_run: true,
      cfg: { "digest" => {}, "bot" => { "chat_id_allowlist" => [] } },
      env: {
        "GITHUB_TOKEN" => "github-secret",
        "HIVE_TELEGRAM_BOT_TOKEN" => "must-not-reach-prdigest",
        "PATH" => "/bin"
      },
      process_runner: lambda do |child_env, *argv|
        config = YAML.safe_load_file(argv.fetch(argv.index("--config") + 1))
        assert_equal 1, config.dig("telegram", "chat_id")
        assert_includes argv, "--dry-run"
        assert child_env.key?("HIVE_TELEGRAM_BOT_TOKEN")
        assert_nil child_env.fetch("HIVE_TELEGRAM_BOT_TOKEN")
        [ JSON.generate(success_payload("dry_run")), "", Status.new(0) ]
      end
    )

    assert runner.call.success?
  end

  def test_child_failure_preserves_prdigest_payload_and_exit
    payload = success_payload("failure").merge(
      "error" => { "kind" => "telegram_ambiguous", "message" => "operator reconciliation required" }
    )
    runner = build_runner(
      process_runner: ->(*) { [ JSON.generate(payload), "", Status.new(4) ] }
    )

    error = assert_raises(Hive::Prdigest::InvocationError) { runner.call }
    assert_equal 4, error.exit_code
    assert_equal payload, error.payload
  end

  def test_missing_date_is_resolved_to_the_previous_london_day
    observed = nil
    runner = build_runner(
      date: nil,
      clock: -> { Time.utc(2026, 6, 14, 0, 30) },
      process_runner: lambda do |_child_env, *argv|
        observed = argv
        [ JSON.generate(success_payload), "", Status.new(0) ]
      end
    )

    runner.call

    assert_equal "2026-06-13", observed.fetch(observed.index("--date") + 1)
  end

  def test_default_clock_resolves_a_missing_date
    before = Hive::LondonDate.today - 1
    argv = Hive::Prdigest::Runner.new(date: nil).send(
      :invocation,
      "/usr/bin/prdigest",
      "/tmp/config.yml",
      []
    )
    after = Hive::LondonDate.today - 1

    assert_includes [ before.iso8601, after.iso8601 ], argv.fetch(argv.index("--date") + 1)
  end

  def test_missing_binary_and_invalid_child_output_fail_without_fallback_engine
    missing = build_runner(binary_resolver: ->(_env) { nil })
    assert_raises(Hive::ConfigError) { missing.call }

    invalid = build_runner(process_runner: ->(*) { [ "not json", "", Status.new(0) ] })
    assert_raises(Hive::InternalError) { invalid.call }
  end

  def test_default_process_runner_executes_prdigest_without_a_shell
    with_tmp_dir do |dir|
      executable = File.join(dir, "prdigest")
      File.write(
        executable,
        "#!/usr/bin/env ruby\nputs #{JSON.generate(success_payload).dump}\n"
      )
      File.chmod(0o755, executable)
      runner = Hive::Prdigest::Runner.new(
        date: "2026-06-13",
        cfg: {
          "digest" => { "max_catchup_days" => 7 },
          "bot" => { "chat_id_allowlist" => [ -1001 ] }
        },
        env: {
          "GITHUB_TOKEN" => "github-secret",
          "HIVE_TELEGRAM_BOT_TOKEN" => "telegram-secret",
          "PATH" => ENV.fetch("PATH")
        },
        registry: Hive::Prdigest::Registry.new(
          entries: [ { "name" => "One", "repository_identity" => "github.com/owner/one" } ]
        ),
        binary_resolver: ->(_env) { executable },
        token_resolver: ->(values) { values.fetch("GITHUB_TOKEN") },
        env_loader: Module.new { def self.load!(env:) = [] }
      )

      result = runner.call

      assert result.success?
      assert_equal executable, result.argv.first
    end
  end

  def test_default_process_runner_removes_parent_telegram_token_in_dry_run
    with_tmp_dir do |dir|
      executable = File.join(dir, "prdigest")
      File.write(
        executable,
        <<~SH
          #!/bin/sh
          if [ "${HIVE_TELEGRAM_BOT_TOKEN+x}" = x ]; then
            exit 9
          fi
          printf '%s\n' '#{JSON.generate(success_payload("dry_run"))}'
        SH
      )
      File.chmod(0o755, executable)
      runner = Hive::Prdigest::Runner.new(
        date: "2026-06-13",
        dry_run: true,
        cfg: {
          "digest" => { "max_catchup_days" => 7 },
          "bot" => { "chat_id_allowlist" => [] }
        },
        env: {
          "GITHUB_TOKEN" => "github-secret",
          "HIVE_TELEGRAM_BOT_TOKEN" => "must-not-reach-prdigest",
          "PATH" => ENV.fetch("PATH")
        },
        registry: Hive::Prdigest::Registry.new(
          entries: [ { "name" => "One", "repository_identity" => "github.com/owner/one" } ]
        ),
        binary_resolver: ->(_env) { executable },
        token_resolver: ->(values) { values.fetch("GITHUB_TOKEN") },
        env_loader: Module.new { def self.load!(env:) = [] }
      )

      result = runner.call

      assert result.success?
      assert_equal "dry_run", result.payload.fetch("status")
    end
  end

  def test_public_run_delegates_to_runner
    result = Hive::Prdigest.run(
      date: "2026-06-13",
      cfg: {
        "digest" => { "max_catchup_days" => 7 },
        "bot" => { "chat_id_allowlist" => [ -1001 ] }
      },
      env: {
        "GITHUB_TOKEN" => "github-secret",
        "HIVE_TELEGRAM_BOT_TOKEN" => "telegram-secret",
        "PATH" => "/bin"
      },
      registry: Hive::Prdigest::Registry.new(
        entries: [ { "name" => "One", "repository_identity" => "github.com/owner/one" } ]
      ),
      binary_resolver: ->(_env) { "/usr/bin/prdigest" },
      token_resolver: ->(values) { values.fetch("GITHUB_TOKEN") },
      process_runner: ->(*) { [ JSON.generate(success_payload), "", Status.new(0) ] },
      env_loader: Module.new { def self.load!(env:) = [] }
    )

    assert result.success?
  end

  def test_runner_rejects_status_exit_contradictions
    runner = build_runner(
      process_runner: ->(*) { [ JSON.generate(success_payload("failure")), "", Status.new(0) ] }
    )

    error = assert_raises(Hive::InternalError) { runner.call }
    assert_match(/contradicts/, error.message)
  end

  def test_private_default_resolvers_are_strict_and_bounded
    runner = build_runner

    with_tmp_dir do |dir|
      executable = File.join(dir, "prdigest")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      env = { "PATH" => dir }

      assert_equal executable, runner.send(:resolve_binary, env)
      assert_equal executable, runner.send(:resolve_binary, env.merge("PRDIGEST_BIN" => "prdigest"))
      assert_equal executable, runner.send(:resolve_binary, env.merge("PRDIGEST_BIN" => executable))
      assert_nil runner.send(:resolve_binary, env.merge("PRDIGEST_BIN" => File.join(dir, "missing")))
    end

    assert_equal "github", runner.send(:resolve_github_token, { "GITHUB_TOKEN" => "github", "GH_TOKEN" => "gh" })
    assert_equal "gh", runner.send(:resolve_github_token, { "GH_TOKEN" => "gh" })

    calls = []
    with_replaced_singleton_method(
      Hive::Gh,
      :capture3,
      lambda do |*argv, timeout_sec:, max_stdout_bytes:|
        calls << [ argv, timeout_sec, max_stdout_bytes ]
        [ "from-gh\n", "", Status.new(0) ]
      end
    ) do
      assert_equal "from-gh", runner.send(:resolve_github_token, {})
    end
    assert_equal [ [ %w[gh auth token --hostname github.com], 10, 4096 ] ], calls

    with_replaced_singleton_method(
      Hive::Gh,
      :capture3,
      ->(*, **) { [ "", "no auth", Status.new(1) ] }
    ) do
      assert_equal "", runner.send(:resolve_github_token, {})
    end
    with_replaced_singleton_method(
      Hive::Gh,
      :capture3,
      ->(*, **) { raise Hive::GhError, "missing gh" }
    ) do
      assert_equal "", runner.send(:resolve_github_token, {})
    end
  end

  def test_binary_resolver_falls_back_to_the_installed_prdigest_gem
    runner = build_runner
    with_tmp_dir do |dir|
      executable = File.join(dir, "prdigest")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)

      gem_bin_calls = []
      with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(*) { nil }) do
        with_replaced_singleton_method(
          Gem,
          :bin_path,
          lambda do |gem_name, executable_name, requirement|
            gem_bin_calls << [ gem_name, executable_name, requirement ]
            executable
          end
        ) do
          assert_equal executable, runner.send(:resolve_binary, { "PATH" => "/bin" })
        end
      end
      assert_equal [ [ "prdigest", "prdigest", "~> 0.1.0" ] ], gem_bin_calls

      with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(*) { nil }) do
        with_replaced_singleton_method(Gem, :bin_path, ->(*) { File.join(dir, "missing") }) do
          assert_nil runner.send(:resolve_binary, { "PATH" => "/bin" })
        end
        with_replaced_singleton_method(
          Gem,
          :bin_path,
          ->(*) { raise Gem::GemNotFoundException, "missing" }
        ) do
          assert_nil runner.send(:resolve_binary, { "PATH" => "/bin" })
        end
      end
    end
  end

  def test_default_config_loader_keeps_only_digest_and_bot_blocks
    runner = build_runner
    with_replaced_singleton_method(
      Hive::Config,
      :load_global_digest_block,
      -> { { "enabled" => true, "max_catchup_days" => 4 } }
    ) do
      with_replaced_singleton_method(
        Hive::Config,
        :load_global_bot,
        -> { { "chat_id_allowlist" => [ 7 ] } }
      ) do
        assert_equal(
          {
            "digest" => { "enabled" => true, "max_catchup_days" => 4 },
            "bot" => { "chat_id_allowlist" => [ 7 ] }
          },
          runner.send(:load_config)
        )
      end
    end
  end

  private

  def build_runner(dry_run: false, cfg: nil, env: nil, process_runner: nil,
                   binary_resolver: nil, date: "2026-06-13", clock: -> { Time.now })
    entries = [
      { "name" => "One", "repository_identity" => "github.com/owner/one" },
      { "name" => "Two", "repository_identity" => "github.com/owner/two" }
    ]
    Hive::Prdigest::Runner.new(
      date: date,
      dry_run: dry_run,
      cfg: cfg || {
        "digest" => { "max_catchup_days" => 7 },
        "bot" => { "chat_id_allowlist" => [ -1001 ] }
      },
      env: env || {
        "GITHUB_TOKEN" => "github-secret",
        "HIVE_TELEGRAM_BOT_TOKEN" => "telegram-secret",
        "PATH" => "/bin"
      },
      registry: Hive::Prdigest::Registry.new(entries: entries),
      binary_resolver: binary_resolver || ->(_env) { "/usr/bin/prdigest" },
      token_resolver: ->(values) { values.fetch("GITHUB_TOKEN") },
      process_runner: process_runner || ->(*) { [ JSON.generate(success_payload), "", Status.new(0) ] },
      env_loader: Module.new { def self.load!(env:) = [] },
      clock: clock
    )
  end

  def success_payload(status = "success")
    {
      "schema" => "prdigest-result",
      "schema_version" => 1,
      "status" => status,
      "mode" => "explicit_date_replay",
      "requested_days" => [ "2026-06-13" ],
      "settled_days" => status == "success" ? [ "2026-06-13" ] : [],
      "skipped_days" => [],
      "failed_date" => nil,
      "remaining_days" => [],
      "error" => nil,
      "chunks" => status == "dry_run" ? [ "preview" ] : [],
      "delivery" => nil
    }
  end
end
