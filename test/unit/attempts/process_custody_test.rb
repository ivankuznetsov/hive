require "test_helper"
require "hive/attempts/process_custody"

class AttemptsProcessCustodyTest < Minitest::Test
  include HiveTestHelper

  def test_unsupported_adapter_is_explicit_and_fail_closed
    custody = Hive::Attempts::ProcessCustody.unsupported("no delegated domain")
    refute custody.available?
    assert_equal "unverified", custody.mode
    assert_equal "no delegated domain", custody.reason
    refute custody.verifiable?("custody_path" => nil)
  end

  def test_linux_adapter_requires_delegated_domain_and_non_writable_parent_boundary
    with_tmp_dir do |root|
      parent = File.join(root, "parent")
      domain = File.join(parent, "attempt.scope")
      FileUtils.mkdir_p(domain)
      File.write(File.join(root, "cgroup.controllers"), "cpu memory pids\n")
      File.write(File.join(parent, "cgroup.procs"), "")
      File.chmod(0o444, File.join(parent, "cgroup.procs"))
      File.write(File.join(domain, "cgroup.procs"), "#{Process.pid}\n")
      File.write(File.join(domain, "cgroup.subtree_control"), "")
      File.write(File.join(domain, "cgroup.events"), "populated 1\n")

      custody = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/parent/attempt.scope" }
      )

      refute custody.current_evidence.fetch("eligible")
      assert_equal "parent_cgroup_writable", custody.reason,
                   "a writable parent remains an unverified escape surface"

      File.chmod(0o555, parent)
      evidence = custody.current_evidence
      assert custody.available?
      assert_equal "delegated_cgroup_v2", evidence.fetch("mode")
      assert custody.verifiable?(
        "custody_mode" => evidence.fetch("mode"),
        "custody_path" => evidence.fetch("path"),
        "custody_evidence_json" => JSON.generate(evidence)
      )

      File.chmod(0o600, File.join(parent, "cgroup.procs"))
      refute custody.current_evidence.fetch("eligible")
      assert_equal "parent_cgroup_writable", custody.reason
    ensure
      File.chmod(0o755, parent) if parent && File.exist?(parent)
    end
  end

  def test_membership_recurses_into_descendant_cgroups
    with_tmp_dir do |root|
      parent = File.join(root, "parent")
      domain = File.join(parent, "attempt.scope")
      nested = File.join(domain, "escaped-session")
      FileUtils.mkdir_p(nested)
      File.write(File.join(root, "cgroup.controllers"), "cpu memory pids\n")
      File.write(File.join(parent, "cgroup.procs"), "")
      File.chmod(0o444, File.join(parent, "cgroup.procs"))
      File.write(File.join(domain, "cgroup.procs"), "")
      File.write(File.join(domain, "cgroup.subtree_control"), "")
      File.write(File.join(domain, "cgroup.events"), "populated 1\n")
      File.write(File.join(nested, "cgroup.procs"), "4242\n")
      File.chmod(0o555, parent)

      custody = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/parent/attempt.scope" }
      )
      assert_equal [ 4242 ], custody.members("/parent/attempt.scope")
    ensure
      File.chmod(0o755, parent) if parent && File.exist?(parent)
    end
  end

  def test_linux_adapter_does_not_exempt_a_writable_hierarchy_root
    with_tmp_dir do |root|
      domain = File.join(root, "attempt.scope")
      FileUtils.mkdir_p(domain)
      File.write(File.join(root, "cgroup.controllers"), "memory pids\n")
      File.write(File.join(root, "cgroup.procs"), "")
      File.write(File.join(domain, "cgroup.procs"), "#{Process.pid}\n")
      File.write(File.join(domain, "cgroup.subtree_control"), "")

      custody = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/attempt.scope" }
      )

      refute custody.current_evidence.fetch("eligible")
      assert_equal "parent_cgroup_writable", custody.reason
    end
  end

  def test_linux_adapter_failures_are_explicit_and_fail_closed
    custody = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
      current_path_reader: -> { raise IOError, "unreadable" }
    )
    refute custody.current_evidence.fetch("eligible")
    assert_equal "cgroup_unavailable", custody.reason

    refute custody.evidence_for("not-a-pid").fetch("eligible")
    refute custody.verifiable?(
      "custody_mode" => custody.mode, "custody_path" => "/scope",
      "custody_evidence_json" => "{invalid"
    )

    unsupported = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
      current_path_reader: -> { "/scope" }
    )
    unsupported.define_singleton_method(:linux?) { false }
    refute unsupported.current_evidence.fetch("eligible")
    assert_equal "platform_unsupported", unsupported.reason

    with_tmp_dir do |root|
      File.write(File.join(root, "cgroup.controllers"), "cpu\n")
      domain = File.join(root, "scope")
      FileUtils.mkdir_p(domain)
      undelegated = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/scope" }
      )
      refute undelegated.current_evidence.fetch("eligible")
      assert_equal "domain_not_delegated", undelegated.reason

      unavailable = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/missing" }
      )
      refute unavailable.current_evidence.fetch("eligible")
      assert_equal "cgroup_unavailable", unavailable.reason
    end
  end
end
