$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# Tests create thousands of disposable projects. Keep scheduler and post-commit
# side effects disabled for the entire process, including setup hooks and child
# processes. The one scheduler integration test temporarily opts back in while
# HOME points at a throwaway directory.
ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = "1"

if ENV["HIVE_COVERAGE"]
  require_relative "support/coverage"
  HiveTestCoverage.start!(root: File.expand_path("..", __dir__))
end

require "minitest/autorun"
require "digest"
require "tmpdir"
require "fileutils"
require "stringio"
require "yaml"
require "shellwords"
require "English"
require_relative "support/tmp_cleanup"

HIVE_TEST_SUITE_TMP_DIRS = []
HIVE_TEST_PARENT_GEM_PATH = Gem.path.join(File::PATH_SEPARATOR).freeze

# Never let a normal test subprocess inherit the operator's Hive state, home,
# XDG roots, agent configuration, GitHub configuration, or global Git config.
# Set only HOME and remove the optional overrides so production defaults keep
# following HOME when an individual test replaces it. Authenticated smoke tests
# opt out explicitly because they exercise the operator's real agent login.
unless ENV["HIVE_TEST_ALLOW_REAL_USER_ENV"] == "1"
  HIVE_TEST_USER_ROOT = Dir.mktmpdir("hive-test-user").freeze
  HIVE_TEST_SUITE_TMP_DIRS << HIVE_TEST_USER_ROOT
  test_home = File.join(HIVE_TEST_USER_ROOT, "home")
  FileUtils.mkdir_p(test_home)
  # Bundler is activated before tests isolate HOME. Ruby subprocess fixtures
  # inherit that activation, so preserve the parent's already-resolved locked
  # gem path instead of making them rediscover gems beneath the throwaway HOME.
  ENV["GEM_PATH"] = HIVE_TEST_PARENT_GEM_PATH if ENV["BUNDLE_GEMFILE"]
  ENV["HOME"] = test_home
  %w[
    HIVE_HOME
    HIVE_RUNTIME_CHANNEL
    HIVE_RUNTIME_BUILD_SHA
    HIVE_RUNTIME_DEPLOYMENT_ID
    XDG_CONFIG_HOME
    XDG_DATA_HOME
    XDG_STATE_HOME
    XDG_CACHE_HOME
    XDG_BIN_HOME
    CLAUDE_CONFIG_DIR
    CODEX_HOME
    PI_CODING_AGENT_DIR
    GROK_HOME
    GH_CONFIG_DIR
    GIT_CONFIG_GLOBAL
  ].each { |key| ENV.delete(key) }
end

require "hive"
require_relative "support/workflow_helpers"
require_relative "support/failure_evidence"

# CI failure evidence: registers on every suite; emits only when running on a
# hosted runner (CI + GITHUB_STEP_SUMMARY) and only when tests failed.
Minitest.extensions << HiveFailureEvidence

if ENV.delete("HIVE_REQUIRE_TEST_RUNS") == "1"
  module HiveCiGateRunGuard
    class Reporter < Minitest::StatisticsReporter
      def record(result)
        return if result.skipped?

        synchronize { super }
      end

      def valid?
        count.positive? && assertions.positive?
      end
    end

    class << self
      attr_accessor :reporter
    end

    def self.minitest_plugin_init(options)
      self.reporter = Reporter.new(options.fetch(:io), options)
      Minitest.reporter << reporter
    end
  end

  Minitest.extensions << HiveCiGateRunGuard
  Minitest.after_run do
    reporter = HiveCiGateRunGuard.reporter
    next if reporter&.valid?

    abort "CI gate selected zero non-skipped tests with assertions " \
          "(runs=#{reporter&.count || 0}, assertions=#{reporter&.assertions || 0})"
  end
end

# Route the default worktree base (`<base>/<project>.worktrees`) into a
# tmp sandbox so tests that exercise worktree creation never seed the
# developer's real ~/Dev. An explicit outer override wins and is never added
# to the cleanup registry. The generated `hive-test-wtbase*` name lives under
# Dir.tmpdir so `rake test:clean_tmp` also recognizes it after a crashed suite.
HIVE_TEST_WORKTREE_BASE = if ENV["HIVE_WORKTREE_BASE"]
  nil
else
  Dir.mktmpdir("hive-test-wtbase").tap { |path| ENV["HIVE_WORKTREE_BASE"] = path }
end
HIVE_TEST_SUITE_TMP_DIRS << HIVE_TEST_WORKTREE_BASE if HIVE_TEST_WORKTREE_BASE
Minitest.after_run do
  HiveTestTmpCleanup.remove_all!(HIVE_TEST_SUITE_TMP_DIRS)
end

if ENV["HIVE_COVERAGE"]
  HiveTestCoverage.install_reporter!
  if ENV["HIVE_COVERAGE_LOAD_ALL"] == "0"
    HiveTestCoverage.reload_preloaded_entrypoint!
  else
    HiveTestCoverage.load_all_sources!
  end
end

module HiveTestStdinIsolation
  # Keep tests hermetic when the suite is launched from a real terminal:
  # production `hive init` prompts on TTY stdin, but tests that need the
  # interactive path inject their own tty-flagged StringIO explicitly.
  def before_setup
    reset_test_runtime_owners!
    @hive_original_stdin = $stdin
    @hive_original_skip_llm_wiki_scheduler = ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"]
    @hive_original_skip_llm_wiki_systemctl = ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"]
    @hive_original_skip_llm_wiki_post_commit = ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"]
    ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
    ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = "1"
    ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = "1"
    $stdin = StringIO.new
    super
  end

  def after_teardown
    teardown_error = nil
    begin
      super
    rescue StandardError => e
      teardown_error = e
    ensure
      begin
        cleanup_test_task_leases if respond_to?(:cleanup_test_task_leases, true)
        HiveTestTmpCleanup.remove_all!(@hive_tracked_tmp_dirs)
      rescue StandardError => e
        teardown_error ||= e
      ensure
        @hive_tracked_tmp_dirs = nil
        reset_test_runtime_owners!
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
        if defined?(@hive_original_skip_llm_wiki_systemctl)
          if @hive_original_skip_llm_wiki_systemctl.nil?
            ENV.delete("HIVE_SKIP_LLM_WIKI_SYSTEMCTL")
          else
            ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = @hive_original_skip_llm_wiki_systemctl
          end
        end
        $stdin = @hive_original_stdin if defined?(@hive_original_stdin)
      end
    end
    raise teardown_error if teardown_error
  end

  private

  def reset_test_runtime_owners!
    Hive::RuntimeControlPlane.disconnect if defined?(Hive::RuntimeControlPlane)
    Hive::Lock.remove_instance_variable(:@task_lease_repository) if
      defined?(Hive::Lock) && Hive::Lock.instance_variable_defined?(:@task_lease_repository)
    Hive::TaskCounter.remove_instance_variable(:@database) if
      defined?(Hive::TaskCounter) && Hive::TaskCounter.instance_variable_defined?(:@database)
    Hive::UsageDb.remove_instance_variable(:@database) if
      defined?(Hive::UsageDb) && Hive::UsageDb.instance_variable_defined?(:@database)
    Thread.current[:hive_task_locks] = nil
    reset_default_test_hive_homes!
  end

  def reset_default_test_hive_homes!
    return unless defined?(HIVE_TEST_USER_ROOT)

    home = File.join(HIVE_TEST_USER_ROOT, "home")
    %w[.local/state/hive .local/share/hive .config/hive].each do |relative|
      path = File.join(home, relative)
      FileUtils.remove_entry(path) if File.exist?(path) || File.symlink?(path)
    end
  end
end

Minitest::Test.include(HiveTestStdinIsolation)
Minitest::Test.include(HiveWorkflowTestHelper)

# Shared fixture paths for tests. Constants here so a future move of
# test/fixtures lands in one place instead of every test that needs
# fake-gh / fake-claude. Use as `FAKE_GH_FIXTURE` / `FAKE_CLAUDE_FIXTURE`.
FAKE_GH_FIXTURE = File.expand_path("fixtures/fake-gh", __dir__).freeze
FAKE_CLAUDE_FIXTURE = File.expand_path("fixtures/fake-claude", __dir__).freeze

# Legacy attempt tests use compact SQL fixtures while production requires an
# injected, already migrated control plane and registered task subjects.
require "hive/attempts/repository"
module HiveTestAttemptRepository
  def initialize(root: Hive::Paths.runtime_payload_root, database: nil,
                 create_directories: true, migrate: false)
    fixture_database = database.nil?
    database ||= Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(File.expand_path(root))
    )
    database.migrate! if migrate
    super(root: root, database: database, create_directories: create_directories)
    @hive_test_register_subjects = fixture_database && migrate
  end

  def create_launching(source_fingerprint: nil, **attributes)
    subject = attributes[:subject]
    fixture_task = !subject.is_a?(Hash) || subject["kind"] != "module_hook"
    register_test_subject(attributes, source_fingerprint) if
      @hive_test_register_subjects && fixture_task
    super(source_fingerprint: source_fingerprint, **attributes)
  end

  private

  def register_test_subject(attributes, source_fingerprint)
    now = Hive::Attempts::Record.iso8601(attributes.fetch(:now))
    project_name = attributes.fetch(:project).to_s
    task_id = attributes.fetch(:task_id).to_s
    task_slug = attributes.fetch(:task_slug).to_s
    project_id = "test-#{Digest::SHA256.hexdigest(project_name)[0, 32]}"
    project_root = File.join(@root, "fixture-projects", project_id)
    database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert_conflict.insert(
        project_id: project_id, installation_id: installation,
        registration_id: project_id, name: project_name, observed_path: project_root,
        state_root_path: File.join(project_root, ".hive-state"), active: 1,
        registered_at: now, last_observed_at: now
      )
      subject = {
        task_id: task_id, project_id: project_id, workflow_id: "coding",
        task_slug: task_slug, observed_path: File.join(project_root, task_slug),
        source_fingerprint: (source_fingerprint || attributes[:progress_token]).to_s,
        generation: Integer(attributes.fetch(:task_input_epoch, 0)),
        created_at: now, last_observed_at: now
      }
      updates = subject.slice(
        :observed_path, :source_fingerprint, :generation, :last_observed_at
      )
      db[:task_subjects].insert_conflict(target: :task_id, update: updates).insert(subject)
    end
  end
end
Hive::Attempts::Repository.prepend(HiveTestAttemptRepository)

module HiveTestHelper
  UNSET_ENV = Object.new.freeze

  def prepare_runtime_project(state_home:, name:, path: state_home,
                              state_root_path: File.join(path, ".hive-state"),
                              project_id: nil)
    require "digest"
    require "time"
    require "hive/runtime_control_plane"
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state_home)
    ).migrate!
    register_runtime_project(
      database: database, name: name, path: path,
      state_root_path: state_root_path, project_id: project_id
    )
    database
  end

  def activate_test_control_plane(state_home)
    require "hive/runtime_control_plane/cutover_manifest"
    epoch = 20260829120000
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state_home)
    ).migrate!
    identity = database.read { |db| db[:installations].first }
    database.transaction do |db|
      db[:installations].update(
        activation_epoch: epoch, activated_at: "2026-08-29T12:00:00.000000Z"
      )
    end
    database.disconnect
    root = File.join(state_home, ".runtime-cutover", "current")
    FileUtils.mkdir_p(root)
    document = Hive::RuntimeControlPlane::CutoverManifest.build(
      phase: "active", installation_id: identity.fetch(:installation_id),
      source_release: "0.7.1",
      target_release: Hive::VERSION, exclusions: [], task_authority: [],
      evidence: { "activation_epoch" => epoch }
    )
    Hive::RuntimeControlPlane::CutoverManifest.new(
      path: File.join(root, "active.json")
    ).publish(document)
  end

  def register_runtime_project(database:, name:, path:,
                               state_root_path: File.join(path, ".hive-state"),
                               project_id: nil, registration_id: name)
    timestamp = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation = db[:installations].first.fetch(:installation_id)
      db[:projects].insert_conflict.insert(
        project_id: project_id || "test-project-#{Digest::SHA256.hexdigest(name)[0, 16]}",
        installation_id: installation, registration_id: registration_id, name: name,
        observed_path: path, state_root_path: state_root_path, active: 1,
        registered_at: timestamp, last_observed_at: timestamp
      )
    end
    database
  end

  # Publish a typed task lease for tests that exercise task liveness. The
  # production cutover deliberately has no filesystem-lock compatibility, so
  # fixtures must use the same SQLite repository as runtime code.
  def publish_test_task_lease(task_folder, payload = nil, state_home: nil, **payload_keywords)
    payload = (payload || {}).merge(payload_keywords.transform_keys(&:to_s))
    repository = prepare_test_task_lease_repository(task_folder, state_home: state_home)
    held = repository.acquire(task_folder, { "op" => "test" }, create: false)
    repository.update(task_folder, payload, lock_id: held.fetch("lock_id"))
    held
  end

  def prepare_test_task_lease_repository(task_folder, state_home: nil)
    require "digest"
    require "hive/task_meta"
    expanded = File.expand_path(task_folder)
    project_root, separator, relative_task = expanded.partition("/.hive-state/stages/")
    if separator.empty? || project_root.empty? || relative_task.empty?
      raise ArgumentError, "task folder is outside .hive-state/stages"
    end

    repository = prepare_test_runtime_project(project_root, state_home: state_home)
    Hive::Lock.task_lease_repository = repository
    ensure_test_task_identity(task_folder)
    repository
  end

  # Direct agent/stage unit tests bypass the command boundary that normally
  # holds the task lease. Model that production precondition explicitly so
  # Agent may update the lease without gaining a test-only acquisition path.
  def prepare_test_task_run(task_folder, state_home: nil)
    repository = prepare_test_task_lease_repository(task_folder, state_home: state_home)
    key = repository.lease_key(task_folder)
    held = (Thread.current[:hive_task_locks] ||= {})
    return repository if held.dig(key, :pid) == Process.pid

    lock = repository.acquire(task_folder, { "op" => "test_task_run" }, create: false)
    held[key] = { depth: 1, lock_id: lock.fetch("lock_id"), pid: Process.pid }
    repository
  end

  def release_test_task_run(task_folder)
    repository = Hive::Lock.task_lease_repository
    key = repository.lease_key(task_folder)
    entry = Thread.current[:hive_task_locks].to_h.delete(key)
    repository.release(task_folder, lock_id: entry.fetch(:lock_id)) if entry
  end

  def prepare_test_runtime_project(
    project_root, state_home: nil, state_root_path: File.join(project_root, ".hive-state")
  )
    require "digest"
    require "hive/task_counter"
    state_home ||= (@hive_test_runtime_state_home ||= tracked_tmp_dir("hive-test-runtime"))
    project_name = "test-#{Digest::SHA256.hexdigest(project_root)[0, 16]}"
    database = prepare_runtime_project(
      state_home: state_home, name: project_name, path: project_root,
      state_root_path: state_root_path
    )
    (@hive_test_runtime_databases ||= []) << database
    unless instance_variable_defined?(:@hive_test_runtime_prior_globals_captured)
      @hive_test_prior_task_lease_repository_defined =
        Hive::Lock.instance_variable_defined?(:@task_lease_repository)
      @hive_test_prior_task_lease_repository =
        Hive::Lock.instance_variable_get(:@task_lease_repository)
      @hive_test_prior_task_counter_database_defined =
        Hive::TaskCounter.instance_variable_defined?(:@database)
      @hive_test_prior_task_counter_database =
        Hive::TaskCounter.instance_variable_get(:@database)
      @hive_test_runtime_prior_globals_captured = true
    end
    repository = Hive::RuntimeControlPlane::TaskLeaseRepository.new(
      database: database,
      process_start_time: Hive::Lock.method(:process_start_time),
      process_alive: lambda { |pid, recorded_start_time:|
        Hive::Lock.send(
          :process_identity_alive?, pid, recorded_start_time: recorded_start_time
        )
      }
    )
    Hive::Lock.task_lease_repository = repository
    Hive::TaskCounter.database = database
    repository
  end

  def cleanup_test_task_leases
    if instance_variable_defined?(:@hive_test_runtime_prior_globals_captured)
      if @hive_test_prior_task_lease_repository_defined
        Hive::Lock.task_lease_repository = @hive_test_prior_task_lease_repository
      elsif Hive::Lock.instance_variable_defined?(:@task_lease_repository)
        Hive::Lock.remove_instance_variable(:@task_lease_repository)
      end
      if @hive_test_prior_task_counter_database_defined
        Hive::TaskCounter.database = @hive_test_prior_task_counter_database
      elsif Hive::TaskCounter.instance_variable_defined?(:@database)
        Hive::TaskCounter.remove_instance_variable(:@database)
      end
    end
    Array(@hive_test_runtime_databases).each(&:disconnect)
    %i[
      @hive_test_prior_task_lease_repository_defined
      @hive_test_prior_task_lease_repository
      @hive_test_prior_task_counter_database_defined
      @hive_test_prior_task_counter_database
      @hive_test_runtime_prior_globals_captured
      @hive_test_runtime_databases
      @hive_test_runtime_state_home
    ].each do |name|
      remove_instance_variable(name) if instance_variable_defined?(name)
    end
  end

  def ensure_test_task_identity(task_folder)
    path = Hive::TaskMeta.path(task_folder)
    raw = YAML.safe_load(File.read(path)) || {}
    raw = {} unless raw.is_a?(Hash)
    unless Hive::TaskMeta.read(task_folder)[:id]
      raw["id"] = Digest::SHA256.hexdigest(File.expand_path(task_folder))[0, 12].to_i(16)
    end
    raw["slug"] ||= File.basename(task_folder)
    raw["display_name"] = nil unless raw.key?("display_name")
    File.write(path, raw.to_yaml)
  rescue Errno::ENOENT
    File.write(path, {
      "id" => Digest::SHA256.hexdigest(File.expand_path(task_folder))[0, 12].to_i(16),
      "slug" => File.basename(task_folder), "display_name" => nil
    }.to_yaml)
  end

  def with_runtime_dispatch_repository(state_home)
    require "hive/runtime_control_plane/dispatch_repository"
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state_home)
    ).open!
    yield Hive::RuntimeControlPlane::DispatchRepository.new(database: database)
  ensure
    database&.disconnect
  end

  # Register a tmpdir that must outlive its creating statement. The global
  # teardown hook removes it securely after the current test, including trees
  # whose subject changed nested directories/files to 0555/0444.
  def tracked_tmp_dir(prefix = "hive-test")
    path = Dir.mktmpdir(prefix)
    unless HiveTestTmpCleanup::TMP_BASE_PATTERN.match?(File.basename(path))
      FileUtils.remove_entry(path)
      raise ArgumentError, "tracked_tmp_dir prefix is not a recognized Hive test tmp shape: #{prefix}"
    end

    (@hive_tracked_tmp_dirs ||= []) << path
    path
  end

  # A cleanup failure should fail an otherwise-green test, but it must not
  # replace the assertion or exception that made the test fail in the first
  # place. `$!` still carries that active exception when an ensure calls here.
  def cleanup_tmp_dir!(path)
    active_error = $!
    HiveTestTmpCleanup.remove_with_related!(path)
  rescue StandardError => cleanup_error
    raise cleanup_error unless active_error

    warn "Hive test tmp cleanup also failed: #{cleanup_error.class}: #{cleanup_error.message}"
  end

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

  # Production deliberately exposes no Context.with/new escape hatch: a
  # caller-controlled context would bypass durable admission. Tests that need
  # to exercise already-admitted worker code replace only the observer seam
  # and mark the synthetic context as already generation-validated. Dedicated
  # Context/Run tests cover the real pre-side-effect validation boundary.
  def with_attempt_context(attempt_id:, task_generation:, ownership_generation: nil)
    require "hive/attempts/context"
    context = Hive::Attempts::Context.send(
      :new, attempt_id: attempt_id, task_generation: task_generation,
      ownership_generation: ownership_generation
    )
    context.instance_variable_set(:@generation_validated, true)
    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) { yield }
  end

  # Surrounding workflow tests can replace the independently unit-tested
  # outcome-evidence controller at its orchestration seam. The replacement
  # publishes the same controller-owned marker shape as an accepted package;
  # it never restores the removed agent-authored completion authority.
  def with_accepted_outcome_evidence
    require "hive/stages/artifacts"
    replacement = lambda do |task, _cfg, **|
      Hive::Stages::Artifacts.publish_complete_marker!(
        task,
        { "generation" => "f" * 64, "attempt_id" => "test-accepted-attempt" }
      )
      { commit: "artifacts_collected", status: :complete }
    end
    with_replaced_singleton_method(
      Hive::Stages::Artifacts, :run_outcome_evidence!, replacement
    ) { yield }
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

  # Project capture delegates content validation to ffprobe and ffmpeg, but
  # those optional runtime tools are not present on every test host. Keep the
  # provider tests hermetic with tiny stand-ins that accept the fixture's known
  # PNG and reject corrupt bytes while preserving the real argv/process path.
  def with_fake_png_media_tools
    Dir.mktmpdir("hive-test-media-tools") do |root|
      fake_bin = File.join(root, "bin")
      FileUtils.mkdir_p(fake_bin)
      tool = <<~RUBY
        #!#{RbConfig.ruby}
        require "json"

        path = if File.basename($PROGRAM_NAME) == "ffmpeg"
          ARGV.fetch(ARGV.index("-i") + 1)
        else
          ARGV.last
        end
        signature = File.binread(path, 8)
        valid = signature == [ 137, 80, 78, 71, 13, 10, 26, 10 ].pack("C*")
        exit 1 unless valid

        if File.basename($PROGRAM_NAME) == "ffprobe"
          puts JSON.generate(
            "streams" => [ { "codec_name" => "png", "codec_type" => "video" } ],
            "format" => { "format_name" => "png_pipe", "duration" => "0" }
          )
        end
      RUBY
      %w[ffprobe ffmpeg].each do |name|
        path = File.join(fake_bin, name)
        File.write(path, tool)
        FileUtils.chmod(0o755, path)
      end
      with_env(
        "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      ) { yield fake_bin }
    end
  end

  # Tests run real `git` inside the tmpdir; pack-objects renames internal
  # state like `bitmap-ref-tips_*` between scan and unlink, so `Dir.mktmpdir`'s
  # built-in cleanup (which uses `FileUtils.remove_entry`) intermittently
  # raises `Errno::ENOENT` under CI load. Replace the block form with an
  # explicit ensure with verified, race-tolerant cleanup. This also handles
  # subjects that make managed-package fixture trees read-only.
  def with_tmp_dir
    dir = Dir.mktmpdir("hive-test")
    yield dir
  ensure
    cleanup_tmp_dir!(dir) if dir
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

  def with_tmp_global_config(home: nil, runtime: true)
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
        with_test_runtime_home do
          File.write(File.join(dir, "config.yml"), { "registered_projects" => [] }.to_yaml)
          activate_test_control_plane(dir) if runtime
          yield(dir)
        end
      end
    ensure
      # Same verified cleanup as `with_tmp_dir`.
      cleanup_tmp_dir!(dir) if dir
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
  def with_tmp_global_config_and_home(runtime: true)
    dir = Dir.mktmpdir("hive-global")
    old_hive_home = ENV["HIVE_HOME"]
    old_home = ENV["HOME"]
    ENV["HIVE_HOME"] = dir
    ENV["HOME"] = dir
    begin
      with_test_runtime_home do
        File.write(File.join(dir, "config.yml"), { "registered_projects" => [] }.to_yaml)
        activate_test_control_plane(dir) if runtime
        yield(dir)
      end
    ensure
      old_hive_home.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = old_hive_home
      old_home.nil? ? ENV.delete("HOME") : ENV["HOME"] = old_home
      # Same verified cleanup as `with_tmp_dir`.
      cleanup_tmp_dir!(dir) if dir
    end
  end

  def with_test_runtime_home
    owners = [ [ Hive::Lock, :@task_lease_repository ] ]
    owners << [ Hive::TaskCounter, :@database ] if defined?(Hive::TaskCounter)
    owners << [ Hive::UsageDb, :@database ] if defined?(Hive::UsageDb)
    owners = owners.to_h do |owner, variable|
      [ [ owner, variable ], owner.instance_variable_defined?(variable) ?
        [ true, owner.instance_variable_get(variable) ] : [ false, nil ] ]
    end
    Hive::RuntimeControlPlane.disconnect
    owners.each_key do |owner, variable|
      owner.remove_instance_variable(variable) if owner.instance_variable_defined?(variable)
    end
    yield
  ensure
    Hive::RuntimeControlPlane.disconnect
    owners&.each do |(owner, variable), (defined, value)|
      owner.remove_instance_variable(variable) if owner.instance_variable_defined?(variable)
      owner.instance_variable_set(variable, value) if defined
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
