require "test_helper"
require "hive/runtime_control_plane/storage_attributes"

class RuntimeStorageAttributesTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    @root = File.join(tracked_tmp_dir, "NOCOW space")
    Dir.mkdir(@root, 0o700)
    @path = File.join(@root, "custom db")
    @calls = []
    @flags = Hash.new("---------------C------")
    @runner = lambda do |name, *args|
      @calls << [ name, *args ]
      case name
      when "stat" then "9123683e btrfs\n"
      when "lsattr" then "#{@flags[args.last]} #{args.last}\n"
      when "chattr"
        @flags[args.last] = "---------------C------"
        ""
      else flunk "unexpected executable #{name}"
      end
    end
  end

  def storage(runner: @runner, path: @path, platform: "linux")
    Hive::RuntimeControlPlane::StorageAttributes.new(path: path, platform: platform, runner: runner)
  end

  def test_inspect_identifies_each_mismatch_without_writing
    paths = [ @root, @path ] + %w[-wal -shm -journal].map { |suffix| @path + suffix }
    paths.drop(1).each { |p| File.write(p, "") }
    assert_equal "healthy", storage.inspect_storage[:outcome]
    paths.each do |path|
      @flags[path] = "----------------------"
      result = storage.inspect_storage
      assert_equal "warning", result[:outcome]
      assert_equal [ path ], result[:paths].select { |r| r[:outcome] == "warning" }.map { |r| r[:path] }
      @flags.delete(path)
    end
    assert_empty @calls.select { |name, *| name == "chattr" }
  end

  def test_orphan_and_missing_directory
    File.write(@path + "-shm", "")
    @flags[@path + "-shm"] = "----------------------"
    assert_equal "warning", storage.inspect_storage[:outcome]
    @calls.clear
    result = storage(path: File.join(@root, "absent", "db")).inspect_storage
    assert_equal "uninitialized", result[:outcome]
    assert_empty @calls
    assert_equal [ "custom db-shm" ], Dir.children(@root)
  end

  def test_non_linux_and_known_non_btrfs_skip_attributes
    assert_equal "not_applicable", storage(platform: "darwin").prepare[:outcome]
    assert_empty @calls
    assert_equal "not_applicable", storage(runner: ->(name, *) { assert_equal "stat", name; "ef53 ext2/ext3\n" }).prepare[:outcome]
  end

  def test_missing_evidence_is_indeterminate_and_never_authorizes_mutation
    [ "", "junk", "9123683e tmpfs", Errno::EACCES.new, Errno::ENOENT.new, Timeout::Error.new ].each do |failure|
      runner = lambda do |name, *|
        assert_equal "stat", name
        raise failure if failure.is_a?(Exception)
        failure
      end
      result = storage(runner: runner).prepare
      assert_equal "indeterminate", result[:outcome]
      assert_includes result[:message], "stat"
    end
    [ "", "C", "---------------------- wrong-path", "garbage #{@root}", "#{'C' * 22} #{@root}" ].each do |bad|
      runner = ->(cmd, *args) { cmd == "lsattr" ? bad : @runner.call(cmd, *args) }
      assert_equal "indeterminate", storage(runner: runner).inspect_storage[:outcome]
    end
  end

  def test_failed_tool_and_bounded_timeout
    probe = Hive::RuntimeControlPlane::StorageAttributes.method(:run_command)
    with_env("PATH" => @root) do
      assert_match(/executable not found/, assert_raises(Hive::RuntimeControlPlane::StorageAttributes::ProbeError) { probe.call("stat") }.message)
      script = File.join(@root, "fake-probe")
      File.write(script, "#!/bin/sh\necho unavailable\nexit 3\n")
      File.chmod(0o700, script)
      assert_match(/exit 3.*unavailable/, assert_raises(Hive::RuntimeControlPlane::StorageAttributes::ProbeError) { probe.call("fake-probe") }.message)
      pid_path = File.join(@root, "child")
      File.write(script, "#!/bin/sh\necho $$ > \"$1\"\nexec /bin/sleep 30\n")
      assert_raises(Timeout::Error) { probe.call("fake-probe", pid_path) }
      assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(pid_path))) }
    end
  end

  def test_disappearing_file_and_confirmed_warning_remain_visible
    File.write(@path, "")
    @flags[@root] = "----------------------"
    runner = lambda do |cmd, *args|
      File.unlink(@path) if cmd == "lsattr" && args.last == @path
      @runner.call(cmd, *args)
    end
    result = storage(runner: runner).inspect_storage
    assert_equal "warning", result[:outcome]
    assert_equal "indeterminate", result[:paths][1][:outcome]
    assert_includes result[:message], "could not determine NOCOW status"
  end

  def test_only_empty_private_directory_is_prepared_once_and_verified
    Dir.rmdir(@root)
    @flags[@root] = "----------------------"
    assert_equal "healthy", storage.prepare[:outcome]
    assert_equal 0o700, File.stat(@root).mode & 0o777
    assert_equal "healthy", storage.prepare[:outcome]
    assert_equal [ [ "chattr", "+C", @root ] ], @calls.select { |cmd, *| cmd == "chattr" }
    @flags[@root] = "----------------------"
    runner = ->(cmd, *args) { cmd == "chattr" ? "" : @runner.call(cmd, *args) }
    result = storage(runner: runner).prepare
    assert_equal "warning", result[:outcome]
    assert_includes result[:message], "could not be verified"
  end

  def test_a_late_file_between_eligibility_checks_prevents_chattr
    @flags[@root] = "----------------------"
    empty = Dir.method(:empty?)
    once = true
    late_file = lambda do |path|
      result = empty.call(path)
      if once
        once = false
        File.write(File.join(path, "newcomer"), "")
      end
      result
    end
    with_replaced_singleton_method(Dir, :empty?, late_file) do
      assert_equal "warning", storage.prepare[:outcome]
    end
    assert_empty @calls.select { |cmd, *| cmd == "chattr" }
  end

  def test_unsafe_and_populated_roots_are_preserved
    @flags[@root] = "----------------------"
    File.chmod(0o770, @root)
    assert_equal "warning", storage.prepare[:outcome]
    File.chmod(0o700, @root)
    other_uid = Process.uid + 1
    with_replaced_singleton_method(Process, :uid, -> { other_uid }) do
      assert_equal "warning", storage.prepare[:outcome]
    end
    runner = lambda do |cmd, *args|
      File.write(File.join(@root, ".lock"), "") if cmd == "lsattr"
      @runner.call(cmd, *args)
    end
    assert_equal "warning", storage(runner: runner).prepare[:outcome]
    File.write(@path, "existing db")
    assert_equal "warning", storage.prepare[:outcome]
    assert_equal "existing db", File.read(@path)
    assert_empty @calls.select { |cmd, *| cmd == "chattr" }

    alias_path = @root + "-alias"
    File.symlink(@root, alias_path)
    @calls.clear
    [ alias_path, @path ].each do |unsafe|
      subject = storage(path: File.join(unsafe, "db"))
      assert_equal "indeterminate", subject.inspect_storage[:outcome]
      assert_equal "indeterminate", subject.prepare[:outcome]
    end
    assert_empty @calls
  end
end
