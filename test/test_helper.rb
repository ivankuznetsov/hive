$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

if ENV["HIVE_COVERAGE"]
  require_relative "support/coverage"
  HiveTestCoverage.start!(root: File.expand_path("..", __dir__))
end

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "yaml"
require "shellwords"
require "English"
require "hive"
require_relative "support/workflow_helpers"

# Route the default worktree base (`<base>/<project>.worktrees`) into a
# tmp sandbox so tests that exercise worktree creation never seed the
# developer's real ~/Dev. `||=` lets an explicit outer override win, and
# the `hive-test-wtbase*` name lives under Dir.tmpdir so `rake test:clean_tmp`
# also sweeps it. Cleaned on suite exit.
ENV["HIVE_WORKTREE_BASE"] ||= Dir.mktmpdir("hive-test-wtbase")
ENV["HIVE_PROVIDER_ROUTING_STATE_HOME"] ||= Dir.mktmpdir("hive-test-routing-state")
Minitest.after_run do
  FileUtils.rm_rf(ENV["HIVE_WORKTREE_BASE"]) if ENV["HIVE_WORKTREE_BASE"]&.include?("hive-test-wtbase")
  if ENV["HIVE_PROVIDER_ROUTING_STATE_HOME"]&.include?("hive-test-routing-state")
    FileUtils.rm_rf(ENV["HIVE_PROVIDER_ROUTING_STATE_HOME"])
  end
end

if ENV["HIVE_COVERAGE"]
  HiveTestCoverage.install_reporter!
  HiveTestCoverage.load_all_sources! unless ENV["HIVE_COVERAGE_LOAD_ALL"] == "0"
end

module HiveTestStdinIsolation
  # Keep tests hermetic when the suite is launched from a real terminal:
  # production `hive init` prompts on TTY stdin, but tests that need the
  # interactive path inject their own tty-flagged StringIO explicitly.
  def before_setup
    @hive_original_stdin = $stdin
    @hive_original_skip_llm_wiki_scheduler = ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"]
    @hive_original_skip_llm_wiki_post_commit = ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"]
    ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
    ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = "1"
    routing_home = ENV["HIVE_PROVIDER_ROUTING_STATE_HOME"]
    if routing_home&.include?("hive-test-routing-state")
      FileUtils.rm_f(Dir[File.join(routing_home, "{,.}*")])
    end
    $stdin = StringIO.new
    super
  end

  def after_teardown
    super
  ensure
    if defined?(@hive_original_skip_llm_wiki_scheduler)
      if @hive_original_skip_llm_wiki_scheduler.nil?
        ENV.delete("HIVE_SKIP_LLM_WIKI_SCHEDULER")
      else
        ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = @hive_original_skip_llm_wiki_scheduler
      end
    end
    if defined?(@hive_original_skip_llm_wiki_post_commit)
      if @hive_original_skip_llm_wiki_post_commit.nil?
        ENV.delete("HIVE_SKIP_LLM_WIKI_POST_COMMIT")
      else
        ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = @hive_original_skip_llm_wiki_post_commit
      end
    end
    $stdin = @hive_original_stdin if defined?(@hive_original_stdin)
  end
end

Minitest::Test.include(HiveTestStdinIsolation)
Minitest::Test.include(HiveWorkflowTestHelper)

# Shared fixture paths for tests. Constants here so a future move of
# test/fixtures lands in one place instead of every test that needs
# fake-gh / fake-claude. Use as `FAKE_GH_FIXTURE` / `FAKE_CLAUDE_FIXTURE`.
FAKE_GH_FIXTURE = File.expand_path("fixtures/fake-gh", __dir__).freeze
FAKE_CLAUDE_FIXTURE = File.expand_path("fixtures/fake-claude", __dir__).freeze

module HiveTestHelper
  UNSET_ENV = Object.new.freeze

  # Temporarily replace `receiver.name` with `replacement` for the duration
  # of the block; restore the original singleton method in `ensure`. Used
  # to stub module-level methods like `Hive::Gh.push_branch!` or class
  # methods like `Hive::Lock.process_start_time` without reaching for a
  # mocking library. Both name forms work: pass a lambda or a method object.
  def with_replaced_singleton_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original) if original
  end

  def with_env(overrides)
    old = overrides.keys.to_h { |key| [ key, ENV.key?(key) ? ENV[key] : UNSET_ENV ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old&.each do |key, value|
      value.equal?(UNSET_ENV) ? ENV.delete(key) : ENV[key] = value
    end
  end

  # Tests run real `git` inside the tmpdir; pack-objects renames internal
  # state like `bitmap-ref-tips_*` between scan and unlink, so `Dir.mktmpdir`'s
  # built-in cleanup (which uses `FileUtils.remove_entry`) intermittently
  # raises `Errno::ENOENT` under CI load. Replace the block form with an
  # explicit ensure that uses `FileUtils.rm_rf`, which tolerates concurrent
  # disappearance instead of raising.
  def with_tmp_dir
    dir = Dir.mktmpdir("hive-test")
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def with_tmp_git_repo
    with_tmp_dir do |dir|
      run!("git", "-C", dir, "init", "-b", "master", "--quiet")
      run!("git", "-C", dir, "config", "user.email", "test@example.com")
      run!("git", "-C", dir, "config", "user.name", "Test")
      run!("git", "-C", dir, "config", "commit.gpgsign", "false")
      File.write(File.join(dir, "README.md"), "test\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "initial", "--quiet")
      yield(dir)
    end
  end

  def run!(*cmd)
    out = `#{cmd.shelljoin} 2>&1`
    raise "command failed: #{cmd.shelljoin}\n#{out}" unless $CHILD_STATUS&.success?

    out
  end

  def with_tmp_global_config(home: nil)
    dir = Dir.mktmpdir("hive-global")
    begin
      fake_bin = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(fake_bin)
      %w[systemctl launchctl].each do |name|
        path = File.join(fake_bin, name)
        File.write(path, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, path)
      end
      with_env(
        "HIVE_HOME" => dir,
        "HOME" => home || dir,
        "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      ) do
        File.write(File.join(dir, "config.yml"), { "registered_projects" => [] }.to_yaml)
        yield(dir)
      end
    ensure
      # Same race-tolerant cleanup as `with_tmp_dir`: tests inside this
      # tmpdir invoke `hive`/git subprocesses that can leave the tree
      # mid-rename.
      FileUtils.rm_rf(dir) if dir
    end
  end

  def set_project_claude_mode(project_root, mode)
    cfg_path = File.join(project_root, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(cfg_path)) || {}
    cfg["claude"] ||= {}
    cfg["claude"]["mode"] = mode.to_s
    File.write(cfg_path, cfg.to_yaml)
  end

  # Variant that also overrides HOME - needed by tests that exercise
  # daemon ServiceInstaller, which anchors on the real user home for
  # launchd/systemd paths and would otherwise write units to the
  # developer's actual $HOME.
  def with_tmp_global_config_and_home
    dir = Dir.mktmpdir("hive-global")
    old_hive_home = ENV["HIVE_HOME"]
    old_home = ENV["HOME"]
    ENV["HIVE_HOME"] = dir
    ENV["HOME"] = dir
    File.write(File.join(dir, "config.yml"), { "registered_projects" => [] }.to_yaml)
    begin
      yield(dir)
    ensure
      old_hive_home.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = old_hive_home
      old_home.nil? ? ENV.delete("HOME") : ENV["HOME"] = old_home
      # Same race-tolerant cleanup as `with_tmp_dir`: tests inside this
      # tmpdir invoke `hive`/git subprocesses that can leave the tree
      # mid-rename.
      FileUtils.rm_rf(dir) if dir
    end
  end

  # Set up a sandboxed XDG_*/HOME environment for tests that exercise
  # the XDG path resolvers (paths_test, uninstall_test, etc). Yields the
  # sandbox root.
  def with_xdg_home
    with_tmp_dir do |dir|
      keys = %w[HOME HIVE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_BIN_HOME]
      old = keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
      ENV["HOME"] = File.join(dir, "home")
      ENV.delete("HIVE_HOME")
      ENV["XDG_CONFIG_HOME"] = File.join(dir, "config")
      ENV["XDG_DATA_HOME"] = File.join(dir, "data")
      ENV["XDG_STATE_HOME"] = File.join(dir, "state")
      ENV["XDG_CACHE_HOME"] = File.join(dir, "cache")
      ENV.delete("XDG_BIN_HOME")
      yield dir
    ensure
      old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  # Run a block that may either call `exit N` directly or `raise Hive::Error`.
  # Captures stdout/stderr and returns [out, err, exit_code]. Mirrors what
  # `bin/hive` does in production: a raised Hive::Error is mapped to its
  # exit_code and its message is sent to stderr as `hive: <message>`.
  def with_captured_exit
    out_pipe = StringIO.new
    err_pipe = StringIO.new
    real_stdout = $stdout
    real_stderr = $stderr
    $stdout = out_pipe
    $stderr = err_pipe
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    rescue Hive::Error => e
      err_pipe.puts "hive: #{e.message}"
      status = e.exit_code
    ensure
      $stdout = real_stdout
      $stderr = real_stderr
    end
    [ out_pipe.string, err_pipe.string, status ]
  end
end
