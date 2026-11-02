# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"

$LOAD_PATH.unshift(File.expand_path("../../templates/builtins/bench/runtime/harness", __dir__))
require "lib/isolation_exec"
require "lib/profile"
require "profiles/slate"

module BenchIsolationFixture
  KEYS = %w[OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY].freeze
  DECLARATION_ERROR = "hive-bench: gen requires HB_API_KEYS to be one supported API variable " \
                      "or explicitly empty for one OAuth file — failing closed\n"
  AUTH_ERROR = "hive-bench: gen credentials require one API variable without OAuth, or exactly one regular OAuth file — failing closed\n"

  def setup
    super
    @isolation_dir = Dir.mktmpdir("bench-isolation")
    @work = File.join(@isolation_dir, "work with spaces")
    @bin = File.join(@isolation_dir, "bin")
    FileUtils.mkdir_p([@work, @bin])
    @claude_auth = File.join(@isolation_dir, "claude auth.json")
    @codex_auth = File.join(@isolation_dir, "codex auth.json")
    File.write(@claude_auth, "decoy-claude-oauth")
    File.write(@codex_auth, "decoy-codex-oauth")
    @spawn_log = File.join(@isolation_dir, "spawned")
    @spawn_script = File.join(@isolation_dir, "spawn.sh")
    File.write(@spawn_script, "printf spawned > #{Shellwords.escape(@spawn_log)}\n")
    @docker_log = File.join(@isolation_dir, "docker.json")
    File.write(File.join(@bin, "docker"), <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      names = ARGV.each_index.filter_map { |i| ARGV[i + 1] if ARGV[i] == "-e" }
      forwarded = names.to_h { |name| k, v = name.split("=", 2); [k, v || ENV[k]] }
      File.write(ENV.fetch("HB_TEST_DOCKER_LOG"), JSON.generate("argv" => ARGV, "env" => forwarded))
      puts '{"type":"message_end","message":{"role":"assistant","usage":{"input":1}}}'
      warn ENV["HB_TEST_DOCKER_ERROR"] if ENV["HB_TEST_DOCKER_ERROR"]
      exit ENV.fetch("HB_TEST_DOCKER_EXIT", "0").to_i
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, "docker"))
  end

  def teardown
    FileUtils.remove_entry(@isolation_dir)
    super
  end

  def profile(harness = "pi", model = "openrouter/vendor/model:high", auth: nil)
    HiveBench::Profile.new(id: "test", harness: harness, model: model, bin: harness,
                           auth_path: auth, headless_argv: ->(prompt:) { [harness, prompt] })
  end

  def fixture_env
    KEYS.to_h { |key| [key, "decoy-#{key}"] }.merge(
      "PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "HB_TEST_DOCKER_LOG" => @docker_log,
      "HB_API_KEYS" => nil, "HB_CLAUDE_AUTH" => nil, "HB_CODEX_AUTH" => nil,
      "HB_TEST_DOCKER_ERROR" => nil, "HB_TEST_DOCKER_EXIT" => nil,
      "HB_ALLOW_EGRESS" => "1", "HB_RUNNER_IMAGE" => "decoy-runner",
      "HB_CPUS" => "8", "HB_MEMORY" => "16g", "HB_PIDS" => "4096"
    )
  end

  def with_isolation_env(overrides = {})
    values = fixture_env.merge(overrides)
    previous = values.to_h { |key, _| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def shell_run(overrides = {}, mode: "gen", bash: "bash", command: ["sh", "-c", "printf '%s' 'a b; $x'"])
    FileUtils.rm_f(@docker_log)
    Open3.capture3(fixture_env.merge(overrides), bash, HiveBench::IsolationExec::SCRIPT, mode, @work, *command)
  end

  def docker_record
    JSON.parse(File.read(@docker_log))
  end

  def credential_names(record)
    record.fetch("env").keys & KEYS
  end

  def mounts(record)
    args = record.fetch("argv")
    args.each_index.filter_map { |i| args[i + 1] if args[i] == "-v" }
  end

  def assert_no_secrets(text)
    (KEYS.map { |key| "decoy-#{key}" } + [@claude_auth, @codex_auth]).each do |secret|
      refute_includes text, secret
    end
  end
end
