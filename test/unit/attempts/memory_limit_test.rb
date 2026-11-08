require "test_helper"
require "hive/attempts/memory_limit"

class AttemptsMemoryLimitTest < Minitest::Test
  include HiveTestHelper

  MemoryLimit = Hive::Attempts::MemoryLimit

  def test_accepts_systemd_sizes_bytes_and_disabled
    [ false, "6G", "512M", "1.5G", "50%", "infinity", 4_294_967_296 ].each do |value|
      assert_nil MemoryLimit.invalid_reason(value, allow_zero: false), value.inspect
    end
    [ "0", 0, "0M" ].each do |value|
      assert_nil MemoryLimit.invalid_reason(value, allow_zero: true), value.inspect
    end
  end

  def test_rejects_malformed_and_zero_memory_caps
    [ nil, true, "", "6 GB", "6g", "-1G", "off", -1, 1.5 ].each do |value|
      refute_nil MemoryLimit.invalid_reason(value, allow_zero: true), value.inspect
    end
    [ "0", 0, "0G", "0%" ].each do |value|
      assert_includes MemoryLimit.invalid_reason(value, allow_zero: false), "a positive", value.inspect
    end
  end

  def test_scope_properties_follow_cap_swap_and_systemd_version
    assert_equal [], MemoryLimit.scope_properties(memory_max: false, memory_swap_max: "0", systemd_version: 262)
    assert_equal [], MemoryLimit.scope_properties(memory_max: nil, memory_swap_max: "0", systemd_version: 262)
    assert_equal(
      [ "--property=MemoryMax=6G", "--property=MemorySwapMax=0", "--property=OOMPolicy=continue" ],
      MemoryLimit.scope_properties(memory_max: "6G", memory_swap_max: "0", systemd_version: 253)
    )
    assert_equal(
      [ "--property=MemoryMax=6G" ],
      MemoryLimit.scope_properties(memory_max: "6G", memory_swap_max: false, systemd_version: 252)
    )
    assert_equal(
      [ "--property=MemoryMax=6G", "--property=MemorySwapMax=1G" ],
      MemoryLimit.scope_properties(memory_max: "6G", memory_swap_max: "1G", systemd_version: nil)
    )
  end

  def test_systemd_version_parses_the_banner_and_tolerates_failures
    status = Struct.new(:ok) { def success? = ok }
    with_replaced_singleton_method(Open3, :capture2e, ->(*) { [ "systemd 262 (262.1-1-arch)\n+PAM", status.new(true) ] }) do
      assert_equal 262, MemoryLimit.systemd_version("systemd-run")
    end
    with_replaced_singleton_method(Open3, :capture2e, ->(*) { [ "unexpected", status.new(true) ] }) do
      assert_nil MemoryLimit.systemd_version("systemd-run")
    end
    with_replaced_singleton_method(Open3, :capture2e, ->(*) { [ "", status.new(false) ] }) do
      assert_nil MemoryLimit.systemd_version("systemd-run")
    end
    with_replaced_singleton_method(Open3, :capture2e, ->(*) { raise Errno::ENOENT }) do
      assert_nil MemoryLimit.systemd_version("systemd-run")
    end
  end

  def test_oom_kill_count_reads_the_current_cgroup_memory_events
    with_tmp_dir do |root|
      proc_cgroup = File.join(root, "cgroup")
      scope = File.join(root, "fs", "user.slice", "hive-attempt-x.scope")
      FileUtils.mkdir_p(scope)
      File.write(proc_cgroup, "0::/user.slice/hive-attempt-x.scope\n")
      File.write(File.join(scope, "memory.events"), "low 0\nhigh 0\nmax 9\noom 2\noom_kill 2\n")

      assert_equal 2, MemoryLimit.oom_kill_count(proc_cgroup: proc_cgroup, cgroup_root: File.join(root, "fs"))

      File.write(File.join(scope, "memory.events"), "low 0\n")
      assert_nil MemoryLimit.oom_kill_count(proc_cgroup: proc_cgroup, cgroup_root: File.join(root, "fs"))

      File.write(proc_cgroup, "1:memory:/legacy\n")
      assert_nil MemoryLimit.oom_kill_count(proc_cgroup: proc_cgroup, cgroup_root: File.join(root, "fs"))

      assert_nil MemoryLimit.oom_kill_count(proc_cgroup: File.join(root, "missing"))
    end
  end
end
