require_relative "../../test_helper"
require "digest"
require "fileutils"
require "socket"
require_relative "paths"
require_relative "replay_safety"

class E2EReplaySafetyTest < Minitest::Test
  RUN_ID = "2026-08-30T10-11-12Z-1234-abcd"
  SCENARIO = "safe-scenario"
  OTHER_SCENARIO = "other-scenario"

  class StatProxy
    def initialize(stat, overrides)
      @stat = stat
      @overrides = overrides
    end

    def method_missing(name, *arguments, **keywords, &block)
      return @overrides.fetch(name) if @overrides.key?(name)

      @stat.public_send(name, *arguments, **keywords, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @overrides.key?(name) || @stat.respond_to?(name, include_private) || super
    end
  end

  class LockOperationsProxy
    attr_reader :flock_calls

    def initialize(stat_transform: nil, mkdir_error: nil, flock_error: nil)
      @stat_transform = stat_transform
      @mkdir_error = mkdir_error
      @flock_error = flock_error
      @flock_calls = []
    end

    def mkdir_p(path, mode:)
      raise @mkdir_error if @mkdir_error

      FileUtils.mkdir_p(path, mode: mode)
    end

    def lstat(path)
      transform(:path, path, File.lstat(path))
    end

    def stat(handle)
      transform(
        :descriptor,
        handle,
        IO.for_fd(handle.fileno, autoclose: false).stat
      )
    end

    def flock(handle, operation, shard_index)
      @flock_calls << [ operation, shard_index ]
      raise @flock_error if @flock_error

      handle.flock(operation)
    end

    def euid
      Process.euid
    end

    private

    def transform(source, target, stat)
      return stat unless @stat_transform

      @stat_transform.call(source, target, stat)
    end
  end

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

        control_root = control_root_for(runs_root)
        assert_equal 0o700, File.stat(control_root).mode & 0o7777
        shards = Dir.children(control_root)
        assert_includes 1..3, shards.length
        shards.each do |name|
          stat = File.lstat(File.join(control_root, name))
          assert stat.file?
          assert_equal 0o600, stat.mode & 0o7777
          assert_equal 1, stat.nlink
          assert_equal 0, stat.size
        end
      ensure
        custody.close
      end

      assert custody.closed?
    end
  end

  def test_replay_control_dir_uses_absolute_xdg_state_or_effective_account_home
    account_lookup = lambda do |uid|
      assert_equal 42, uid
      Struct.new(:dir).new("/effective/home")
    end
    noise = {
      "TMPDIR" => "/ignored/tmp",
      "TMP" => "/ignored/tmp-two",
      "TEMP" => "/ignored/tmp-three",
      "HIVE_HOME" => "/ignored/hive"
    }

    absolute = Hive::E2E::Paths.replay_control_dir(
      env: noise.merge("XDG_STATE_HOME" => "/stable/state"),
      euid: 42,
      account_lookup: ->(_uid) { flunk "absolute XDG state must not query the account" }
    )
    fallback = Hive::E2E::Paths.replay_control_dir(
      env: noise.merge("XDG_STATE_HOME" => "relative/state"),
      euid: 42,
      account_lookup: account_lookup
    )

    assert_equal "/stable/state/hive-e2e/replay-42/locks-v1", absolute
    assert_equal "/effective/home/.local/state/hive-e2e/replay-42/locks-v1", fallback
  end

  def test_same_selection_is_busy_until_custody_closes_then_retry_succeeds
    with_replay_tree do |runs_root, _script|
      events = []
      first = replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
      begin
        error = assert_replay_error("replay_busy", "replay_busy") do
          replay_safety(runs_root, on_event: ->(event) { events << event }).select(
            run_id: RUN_ID, scenario: SCENARIO
          )
        end
        assert_equal "replay preflight failed (replay_busy)", error.message
        refute_includes events, :artifact_pinned
      ensure
        first.close
      end

      retry_custody = replay_safety(runs_root).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      retry_custody.close
    end
  end

  def test_admission_keys_are_domain_tagged_length_prefixed_and_bounded
    with_replay_tree do |runs_root, _script|
      captured = nil
      selector = lambda do |tuples|
        captured = tuples
        tuples.map { |tuple| Digest::SHA256.digest(tuple).getbyte(0) }
      end
      custody = replay_safety(runs_root, shard_selector: selector).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      stat = File.stat(runs_root)

      assert_equal [
        [ "configured-root-v1", File.expand_path(runs_root), RUN_ID, SCENARIO ],
        [ "canonical-root-v1", File.realpath(runs_root), RUN_ID, SCENARIO ],
        [ "root-identity-v1", stat.dev.to_s, stat.ino.to_s, RUN_ID, SCENARIO ]
      ], captured.map { |tuple| decode_length_prefixed_tuple(tuple) }
      expected = captured.map do |tuple|
        format("replay-%02x.lock", Digest::SHA256.digest(tuple).getbyte(0))
      end.uniq.sort
      assert_equal expected, Dir.children(control_root_for(runs_root)).sort
      custody.close
    end
  end

  def test_configured_aliases_to_the_same_root_share_admission
    Dir.mktmpdir("rs-alias") do |tmp|
      real_parent = File.join(tmp, "real")
      alias_parent = File.join(tmp, "alias")
      runs_root = File.join(real_parent, "runs")
      create_replay_tree(runs_root)
      File.symlink(real_parent, alias_parent)
      control_root = File.join(tmp, "control")

      first = replay_safety(runs_root, control_root: control_root).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      begin
        assert_replay_error("replay_busy", "replay_busy") do
          replay_safety(
            File.join(alias_parent, "runs"), control_root: control_root
          ).select(run_id: RUN_ID, scenario: SCENARIO)
        end
      ensure
        first.close
      end
    end
  end

  def test_replacement_generation_at_same_configured_path_shares_admission
    with_replay_tree do |runs_root, _script|
      control_root = control_root_for(runs_root)
      first = replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
      parked = "#{runs_root}.old"
      File.rename(runs_root, parked)
      create_replay_tree(runs_root)
      events = []

      begin
        assert_replay_error("replay_busy", "replay_busy") do
          replay_safety(
            runs_root, control_root: control_root,
            on_event: ->(event) { events << event }
          ).select(run_id: RUN_ID, scenario: SCENARIO)
        end
        refute_includes events, :artifact_pinned
      ensure
        first.close
      end
    end
  end

  def test_distinct_selections_proceed_unless_their_bounded_shards_collide
    with_replay_tree do |runs_root, _script|
      create_scenario(runs_root, OTHER_SCENARIO)
      first = replay_safety(
        runs_root, shard_selector: ->(_tuples) { [ 1 ] }
      ).select(run_id: RUN_ID, scenario: SCENARIO)
      second = replay_safety(
        runs_root, shard_selector: ->(_tuples) { [ 2 ] }
      ).select(run_id: RUN_ID, scenario: OTHER_SCENARIO)

      assert_replay_error("replay_busy", "replay_busy") do
        replay_safety(
          runs_root, shard_selector: ->(_tuples) { [ 1 ] }
        ).select(run_id: RUN_ID, scenario: OTHER_SCENARIO)
      end
    ensure
      second&.close
      first&.close
    end
  end

  def test_shards_are_acquired_in_numeric_order_and_partial_sets_are_released
    with_replay_tree do |runs_root, _script|
      holder = replay_safety(
        runs_root, shard_selector: ->(_tuples) { [ 20 ] }
      ).select(run_id: RUN_ID, scenario: SCENARIO)
      operations = LockOperationsProxy.new

      assert_replay_error("replay_busy", "replay_busy") do
        replay_safety(
          runs_root,
          shard_selector: ->(_tuples) { [ 200, 20, 10 ] },
          lock_operations: operations
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end
      attempts = operations.flock_calls.filter_map do |operation, index|
        index if operation == (File::LOCK_EX | File::LOCK_NB)
      end
      assert_equal [ 10, 20 ], attempts

      released_partial = replay_safety(
        runs_root, shard_selector: ->(_tuples) { [ 10 ] }
      ).select(run_id: RUN_ID, scenario: SCENARIO)
      released_partial.close
      holder.close

      ordered = LockOperationsProxy.new
      custody = replay_safety(
        runs_root,
        shard_selector: ->(_tuples) { [ 200, 10, 200 ] },
        lock_operations: ordered
      ).select(run_id: RUN_ID, scenario: SCENARIO)
      attempts = ordered.flock_calls.filter_map do |operation, index|
        index if operation == (File::LOCK_EX | File::LOCK_NB)
      end
      assert_equal [ 10, 200 ], attempts
      custody.close
    end
  end

  def test_exception_before_the_fence_releases_admission_for_retry
    with_replay_tree do |runs_root, _script|
      observer = lambda do |event|
        raise "injected pre-fence failure" if event == :artifact_pinned
      end

      error = assert_raises(RuntimeError) do
        replay_safety(runs_root, on_event: observer).select(
          run_id: RUN_ID, scenario: SCENARIO
        )
      end
      assert_equal "injected pre-fence failure", error.message

      custody = replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
      custody.close
    end
  end

  def test_public_replacement_after_final_fence_cannot_redirect_descriptor_alias
    with_replay_tree do |runs_root, script|
      original = File.stat(script)
      parked = "#{script}.original"
      observer = lambda do |event|
        next unless event == :final_fence_passed

        File.rename(script, parked)
        File.write(script, "#!/bin/sh\nexit 99\n")
        File.chmod(0o755, script)
      end

      custody = replay_safety(runs_root, on_event: observer).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      alias_stat = File.stat(custody.descriptor_alias)
      assert_equal [ original.dev, original.ino ], [ alias_stat.dev, alias_stat.ino ]
      refute_equal File.stat(script).ino, alias_stat.ino
      custody.close
    end
  end

  def test_control_directory_symlink_mode_and_link_count_fail_closed
    %i[symlink mode links].each do |unsafe|
      with_replay_tree do |runs_root, _script|
        control_root = control_root_for(runs_root)
        case unsafe
        when :symlink
          target = "#{control_root}.target"
          FileUtils.mkdir_p(target, mode: 0o700)
          File.symlink(target, control_root)
        when :mode
          FileUtils.mkdir_p(control_root, mode: 0o700)
          File.chmod(0o755, control_root)
        when :links
          FileUtils.mkdir_p(File.join(control_root, "unexpected"), mode: 0o700)
        end

        assert_lock_unavailable do
          replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
        end
      end
    end
  end

  def test_shard_symlink_mode_and_link_count_fail_closed_without_repair
    %i[symlink mode links contents].each do |unsafe|
      with_replay_tree do |runs_root, _script|
        control_root = create_control_root(control_root_for(runs_root))
        shard = shard_path(control_root, 7)
        case unsafe
        when :symlink
          target = "#{shard}.target"
          File.write(target, "sentinel")
          File.chmod(0o600, target)
          File.symlink(target, shard)
        when :mode
          File.write(shard, "sentinel")
          File.chmod(0o640, shard)
        when :links
          File.write(shard, "sentinel")
          File.chmod(0o600, shard)
          File.link(shard, "#{shard}.link")
        when :contents
          File.write(shard, "sentinel")
          File.chmod(0o600, shard)
        end

        before = File.lstat(shard)
        contents = File.binread(shard) unless before.symlink?
        assert_lock_unavailable do
          replay_safety(
            runs_root, shard_selector: ->(_tuples) { [ 7 ] }
          ).select(run_id: RUN_ID, scenario: SCENARIO)
        end
        after = File.lstat(shard)
        assert_equal [ before.dev, before.ino, before.mode, before.nlink ],
                     [ after.dev, after.ino, after.mode, after.nlink ]
        assert_equal contents, File.binread(shard) if contents
      end
    end
  end

  def test_injected_wrong_owner_and_shard_substitution_fail_closed
    with_replay_tree do |runs_root, _script|
      transform = lambda do |_source, _target, stat|
        if stat.file?
          StatProxy.new(stat, uid: Process.euid + 1)
        else
          stat
        end
      end
      operations = LockOperationsProxy.new(stat_transform: transform)

      assert_lock_unavailable do
        replay_safety(
          runs_root,
          shard_selector: ->(_tuples) { [ 7 ] },
          lock_operations: operations
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end

    with_replay_tree do |runs_root, _script|
      control_root = control_root_for(runs_root)
      shard = shard_path(control_root, 7)
      observer = lambda do |event|
        next unless event == [ :lock_shard_opened, 7 ]

        File.rename(shard, "#{shard}.parked")
        File.write(shard, "replacement")
        File.chmod(0o600, shard)
      end

      assert_lock_unavailable do
        replay_safety(
          runs_root,
          shard_selector: ->(_tuples) { [ 7 ] },
          on_event: observer
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end
  end

  def test_injected_control_owner_and_binding_substitution_fail_closed
    with_replay_tree do |runs_root, _script|
      transform = lambda do |_source, _target, stat|
        if stat.directory?
          StatProxy.new(stat, uid: Process.euid + 1)
        else
          stat
        end
      end

      assert_lock_unavailable do
        replay_safety(
          runs_root,
          lock_operations: LockOperationsProxy.new(stat_transform: transform)
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end
    end

    with_replay_tree do |runs_root, _script|
      control_root = control_root_for(runs_root)
      observer = lambda do |event|
        next unless event == :control_directory_opened

        File.rename(control_root, "#{control_root}.parked")
        create_control_root(control_root)
      end

      assert_lock_unavailable do
        replay_safety(runs_root, on_event: observer).select(
          run_id: RUN_ID, scenario: SCENARIO
        )
      end
    end
  end

  def test_control_permission_and_flock_capability_failures_are_normalized
    [
      LockOperationsProxy.new(mkdir_error: Errno::EACCES.new("control")),
      LockOperationsProxy.new(flock_error: NotImplementedError.new("flock"))
    ].each do |operations|
      with_replay_tree do |runs_root, _script|
        error = assert_lock_unavailable do
          replay_safety(runs_root, lock_operations: operations).select(
            run_id: RUN_ID, scenario: SCENARIO
          )
        end
        refute_match(/EACCES|flock/, error.message)
      end
    end
  end

  def test_shard_open_permission_failure_releases_every_descriptor
    with_replay_tree do |runs_root, _script|
      native = NativeProxy.new(
        Hive::ManagedDirectory.build_native_at_adapter,
        error_for: "replay-07.lock"
      )

      assert_lock_unavailable do
        replay_safety(
          runs_root,
          native: native,
          shard_selector: ->(_tuples) { [ 7 ] }
        ).select(run_id: RUN_ID, scenario: SCENARIO)
      end
      assert native.opened.all? { |handle| closed_handle?(handle) }
    end
  end

  def test_busy_loser_leaves_persistent_shards_and_runs_tree_unchanged
    with_replay_tree do |runs_root, script|
      control_root = control_root_for(runs_root)
      first = replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
      shard_snapshot = Dir.children(control_root).sort.to_h do |name|
        path = File.join(control_root, name)
        stat = File.lstat(path)
        [ name, [ stat.dev, stat.ino, stat.mode, stat.nlink, File.binread(path) ] ]
      end
      script_snapshot = [ File.stat(script).ino, File.binread(script) ]

      begin
        assert_replay_error("replay_busy", "replay_busy") do
          replay_safety(runs_root).select(run_id: RUN_ID, scenario: SCENARIO)
        end
        after = Dir.children(control_root).sort.to_h do |name|
          path = File.join(control_root, name)
          stat = File.lstat(path)
          [ name, [ stat.dev, stat.ino, stat.mode, stat.nlink, File.binread(path) ] ]
        end
        assert_equal shard_snapshot, after
        assert_equal script_snapshot, [ File.stat(script).ino, File.binread(script) ]
      ensure
        first.close
      end
    end
  end

  def test_every_non_script_custody_and_admission_descriptor_is_close_on_exec
    with_replay_tree do |runs_root, _script|
      native = NativeProxy.new(Hive::ManagedDirectory.build_native_at_adapter)
      custody = replay_safety(runs_root, native: native).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      live_handles = native.opened.reject { |handle| closed_handle?(handle) }

      assert_operator live_handles.length, :>, 1
      live_handles.each do |handle|
        fd = handle.fileno
        assert IO.for_fd(fd, autoclose: false).close_on_exec?, "fd #{fd} must be close-on-exec"
      end
      refute_respond_to custody, :lock_fds
      assert_respond_to custody, :script_fd
      custody.close
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

      retry_custody = replay_safety(runs_root).select(
        run_id: RUN_ID, scenario: SCENARIO
      )
      retry_custody.close
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
    options = { control_root: control_root_for(root) }.merge(options)
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
    create_scenario(runs_root, SCENARIO)
  end

  def create_scenario(runs_root, scenario_name)
    scenario = File.join(runs_root, RUN_ID, "scenarios", scenario_name)
    FileUtils.mkdir_p(scenario)
    script = File.join(scenario, "repro.sh")
    File.write(script, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, script)
    script
  end

  def control_root_for(runs_root)
    File.join(File.dirname(File.expand_path(runs_root)), "replay-control")
  end

  def create_control_root(path)
    FileUtils.mkdir_p(path, mode: 0o700)
    File.chmod(0o700, path)
    path
  end

  def shard_path(control_root, index)
    File.join(control_root, format("replay-%02x.lock", index))
  end

  def decode_length_prefixed_tuple(tuple)
    fields = []
    offset = 0
    while offset < tuple.bytesize
      length = tuple.byteslice(offset, 4).unpack1("N")
      offset += 4
      fields << tuple.byteslice(offset, length)
      offset += length
    end
    fields
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

  def assert_lock_unavailable(&block)
    assert_replay_error("preflight", "replay_lock_unavailable", &block)
  end

  def closed_handle?(handle)
    handle.fileno
    false
  rescue IOError
    true
  end
end
