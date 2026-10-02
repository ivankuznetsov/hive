require_relative "../../test_helper"
require "fileutils"
require "socket"
require_relative "replay_safety"

class E2EReplaySafetyTest < Minitest::Test
  RUN_ID = "2026-08-30T10-11-12Z-1234-abcd"
  SCENARIO = "safe-scenario"

  class NativeProxy
    attr_reader :close_calls, :opened

    def initialize(delegate, error_for: nil, fail_closes: false)
      @delegate = delegate
      @error_for = error_for
      @fail_closes = fail_closes
      @opened = []
      @close_calls = 0
    end

    def open_absolute_directory(path)
      raise Errno::EACCES, path if @error_for == :root

      remember(@delegate.open_absolute_directory(path))
    end

    def open_directory(parent, name)
      raise Errno::EACCES, name if @error_for == name

      remember(@delegate.open_directory(parent, name))
    end

    def open_file(parent, name, flags, mode: nil)
      raise Errno::EACCES, name if @error_for == name

      remember(@delegate.open_file(parent, name, flags, mode: mode))
    end

    private

    def remember(handle)
      handle = CloseFailureHandle.new(handle, -> { @close_calls += 1 }) if @fail_closes
      @opened << handle
      handle
    end
  end

  class CloseFailureHandle
    def initialize(handle, record_close)
      @handle = handle
      @record_close = record_close
    end

    def close
      @record_close.call
      @handle.close
      raise IOError, "injected close failure"
    end

    def method_missing(name, *arguments, **keywords, &block)
      @handle.public_send(name, *arguments, **keywords, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @handle.respond_to?(name, include_private) || super
    end
  end

  def test_stable_tree_yields_only_a_verified_descriptor_alias
    with_replay_tree do |runs_root, script|
      custody = replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
      begin
        alias_stat = File.stat(custody.descriptor_alias)

        assert_equal [ alias_stat.dev, alias_stat.ino, alias_stat.mode & 0o170000 ],
                     custody.script_identity
        assert_equal custody.script_fd,
                     Integer(File.basename(custody.descriptor_alias), 10)
        assert_equal 0, IO.for_fd(custody.script_fd, autoclose: false).pos
        assert_equal File.realpath(runs_root), custody.canonical_root
        assert_equal File.stat(script).ino, alias_stat.ino
        assert IO.for_fd(custody.script_fd, autoclose: false).close_on_exec?
      ensure
        custody.close
      end

      assert custody.closed?
    end
  end

  def test_symlinked_ancestor_is_allowed_but_symlinked_runs_root_is_rejected
    Dir.mktmpdir("replay-safety") do |tmp|
      real_parent = File.join(tmp, "real-parent")
      alias_parent = File.join(tmp, "alias-parent")
      real_root = File.join(real_parent, "runs")
      script = create_replay_tree(real_root)
      File.symlink(real_parent, alias_parent)

      custody = replay_safety(File.join(alias_parent, "runs")).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      assert_equal File.realpath(real_root), custody.canonical_root
      assert_equal File.stat(script).ino, File.stat(custody.descriptor_alias).ino
      custody.close

      link = File.join(tmp, "runs-link")
      File.symlink(real_root, link)
      assert_replay_error("unusable_repro", "runs_root_symlink") do
        replay_safety(link).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end
  end

  def test_non_directory_runs_root_is_initially_unusable
    Dir.mktmpdir("replay-safety") do |tmp|
      root = File.join(tmp, "runs")
      File.write(root, "not a directory")

      assert_replay_error("unusable_repro", "runs_root_unusable") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end
  end

  def test_initial_missing_entries_have_entry_specific_missing_reasons
    Dir.mktmpdir("replay-safety") do |tmp|
      root = File.join(tmp, "runs")
      assert_replay_error("missing_repro", "runs_root_missing") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end

      FileUtils.mkdir_p(root)
      assert_replay_error("missing_repro", "run_missing") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end

      FileUtils.mkdir_p(File.join(root, RUN_ID))
      assert_replay_error("missing_repro", "scenarios_missing") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end

      FileUtils.mkdir_p(File.join(root, RUN_ID, "scenarios"))
      assert_replay_error("missing_repro", "scenario_missing") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end

      FileUtils.mkdir_p(File.join(root, RUN_ID, "scenarios", SCENARIO))
      assert_replay_error("missing_repro", "repro_missing") do
        replay_safety(root).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end
  end

  def test_initial_unsafe_components_have_entry_specific_unusable_reasons
    %w[run scenarios scenario].each do |entry|
      with_replay_tree do |runs_root, _script|
        path = component_path(runs_root, entry)
        parked = "#{path}.parked"
        File.rename(path, parked)
        File.symlink(parked, path)

        assert_replay_error("unusable_repro", "#{entry}_unusable") do
          replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
        end
      end
    end
  end

  def test_initial_unsafe_script_kinds_and_mode_are_rejected_without_blocking
    cases = %i[symlink dangling directory fifo socket non_executable]
    cases.each do |kind|
      with_replay_tree do |runs_root, script|
        File.unlink(script)
        socket = replace_script_with_kind(script, kind)

        assert_replay_error("unusable_repro", "repro_unusable") do
          replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
        end
      ensure
        socket&.close
      end
    end
  end

  def test_open_permission_failures_are_normalized_as_repro_unreadable
    {
      "root" => :root,
      "run" => RUN_ID,
      "scenarios" => "scenarios",
      "scenario" => SCENARIO,
      "repro" => "repro.sh"
    }.each do |_label, entry|
      with_replay_tree do |runs_root, _script|
        native = NativeProxy.new(
          Hive::ManagedDirectory.build_native_at_adapter,
          error_for: entry
        )

        assert_replay_error("unusable_repro", "repro_unreadable") do
          replay_safety(runs_root, native: native).select(
            run_id: RUN_ID, scenario: SCENARIO
          )
        end
      end
    end
  end

  def test_root_mutations_before_the_fence_are_classified_and_never_return_custody
    mutations = {
      "runs_root_symlink" => lambda do |root, parked|
        File.rename(root, parked)
        File.symlink(parked, root)
      end,
      "runs_root_missing" => ->(root, parked) { File.rename(root, parked) },
      "runs_root_changed" => lambda do |root, parked|
        File.rename(root, parked)
        FileUtils.mkdir_p(root)
      end
    }

    mutations.each do |reason, mutation|
      with_replay_tree do |runs_root, _script|
        parked = "#{runs_root}.parked"
        observer = lambda do |event|
          mutation.call(runs_root, parked) if event == :artifact_pinned
        end

        assert_replay_error("unusable_repro", reason) do
          replay_safety(runs_root, on_event: observer).select(
            run_id: RUN_ID, scenario: SCENARIO
          )
        end
      end
    end
  end

  def test_component_and_script_mutations_before_the_fence_are_changed
    %w[run scenarios scenario repro].each do |entry|
      with_replay_tree do |runs_root, _script|
        path = component_path(runs_root, entry)
        parked = "#{path}.parked"
        observer = lambda do |event|
          next unless event == :artifact_pinned

          File.rename(path, parked)
          if entry == "repro"
            File.write(path, "#!/bin/sh\nexit 99\n")
            File.chmod(0o755, path)
          else
            FileUtils.mkdir_p(path)
          end
        end

        assert_replay_error("unusable_repro", "#{entry}_changed") do
          replay_safety(runs_root, on_event: observer).select(
            run_id: RUN_ID, scenario: SCENARIO
          )
        end
      end
    end
  end

  def test_same_script_inode_losing_execute_mode_is_unusable
    with_replay_tree do |runs_root, script|
      observer = ->(event) { File.chmod(0o644, script) if event == :artifact_pinned }

      assert_replay_error("unusable_repro", "repro_unusable") do
        replay_safety(runs_root, on_event: observer).select(
          run_id: RUN_ID, scenario: SCENARIO
        )
      end
    end
  end

  def test_move_and_restore_of_the_same_chain_is_accepted_at_the_fence
    with_replay_tree do |runs_root, script|
      parked = "#{runs_root}.parked"
      observer = lambda do |event|
        next unless event == :artifact_pinned

        File.rename(runs_root, parked)
        File.rename(parked, runs_root)
      end

      custody = replay_safety(runs_root, on_event: observer).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      assert_equal File.stat(script).ino, File.stat(custody.descriptor_alias).ino
      custody.close
    end
  end

  def test_missing_or_mismatched_descriptor_alias_fails_closed_and_cleans_up
    with_replay_tree do |runs_root, _script|
      native = NativeProxy.new(Hive::ManagedDirectory.build_native_at_adapter)
      Dir.mktmpdir("fake-fd-root") do |alias_root|
        error = assert_replay_error("preflight", "descriptor_exec_unavailable") do
          replay_safety(
            runs_root,
            native: native,
            descriptor_alias_roots: [ alias_root ]
          ).select(run_id: RUN_ID, scenario: SCENARIO)
        end

        assert_equal "replay preflight failed (descriptor_exec_unavailable)",
                     error.message
      end

      assert native.opened.all? { |handle| closed_handle?(handle) },
             "every descriptor opened before alias failure must be closed"
    end
  end

  def test_identity_mismatched_descriptor_alias_is_not_accepted
    with_replay_tree do |runs_root, _script|
      native = NativeProxy.new(Hive::ManagedDirectory.build_native_at_adapter)
      Dir.mktmpdir("fake-fd-root") do |alias_root|
        observer = lambda do |event|
          next unless event == :final_fence_passed

          script = native.opened.reverse.find do |handle|
            !closed_handle?(handle) && handle.stat.file?
          end
          File.write(File.join(alias_root, script.fileno.to_s), "different inode")
        end

        assert_replay_error("preflight", "descriptor_exec_unavailable") do
          replay_safety(
            runs_root,
            native: native,
            descriptor_alias_roots: [ alias_root ],
            on_event: observer
          ).select(run_id: RUN_ID, scenario: SCENARIO)
        end
      end
    end
  end

  def test_cleanup_attempts_every_descriptor_when_individual_closes_fail
    with_replay_tree do |runs_root, _script|
      native = NativeProxy.new(
        Hive::ManagedDirectory.build_native_at_adapter,
        fail_closes: true
      )

      assert_replay_error("preflight", "descriptor_exec_unavailable") do
        replay_safety(
          runs_root,
          native: native,
          descriptor_alias_roots: []
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end

      assert_equal native.opened.size, native.close_calls
      assert native.opened.all? { |handle| closed_handle?(handle) }
    end
  end

  def test_descriptor_capability_failure_is_normalized
    factory = -> { raise Hive::ManagedDirectory::NativeAdapterUnavailable,
                        "host-specific detail" }

    error = assert_replay_error("preflight", "descriptor_exec_unavailable") do
      Hive::E2E::ReplaySafety.new(
        runs_root: "/not-opened",
        native_factory: factory
      )
    end
    refute_includes error.message, "host-specific"
  end

  private

  def replay_safety(root, **options)
    Hive::E2E::ReplaySafety.new(runs_root: root, **options)
  end

  def with_replay_tree
    # Keep the prefix short enough for the Unix-domain socket fixture after
    # the generated run/scenario components are appended.
    Dir.mktmpdir("rs") do |tmp|
      runs_root = File.join(tmp, "runs")
      script = create_replay_tree(runs_root)
      yield runs_root, script
    end
  end

  def create_replay_tree(runs_root)
    scenario = File.join(runs_root, RUN_ID, "scenarios", SCENARIO)
    FileUtils.mkdir_p(scenario)
    script = File.join(scenario, "repro.sh")
    File.write(script, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, script)
    script
  end

  def component_path(runs_root, entry)
    case entry
    when "run"
      File.join(runs_root, RUN_ID)
    when "scenarios"
      File.join(runs_root, RUN_ID, "scenarios")
    when "scenario"
      File.join(runs_root, RUN_ID, "scenarios", SCENARIO)
    when "repro"
      File.join(runs_root, RUN_ID, "scenarios", SCENARIO, "repro.sh")
    else
      raise "unknown component #{entry.inspect}"
    end
  end

  def replace_script_with_kind(script, kind)
    case kind
    when :symlink
      target = "#{script}.target"
      File.write(target, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, target)
      File.symlink(target, script)
      nil
    when :dangling
      File.symlink("#{script}.missing", script)
      nil
    when :directory
      FileUtils.mkdir_p(script)
      nil
    when :fifo
      system("mkfifo", script, exception: true)
      nil
    when :socket
      UNIXServer.new(script)
    when :non_executable
      File.write(script, "#!/bin/sh\nexit 0\n")
      File.chmod(0o644, script)
      nil
    end
  end

  def assert_replay_error(kind, reason)
    error = assert_raises(Hive::E2E::ReplaySafety::Error) { yield }
    assert_equal kind, error.kind
    assert_equal kind, error.error_kind
    assert_equal reason, error.reason
    error
  end

  def closed_handle?(handle)
    handle.fileno
    false
  rescue IOError
    true
  end
end
