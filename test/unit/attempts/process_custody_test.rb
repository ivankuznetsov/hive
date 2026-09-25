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

  def test_linux_adapter_requires_delegated_domain_and_unwritable_parent
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

      custody = Hive::Attempts::ProcessCustody::LinuxCgroupV2.new(
        cgroup_root: root, current_path_reader: -> { "/parent/attempt.scope" }
      )
      assert_equal [ 4242 ], custody.members("/parent/attempt.scope")
    end
  end
end
