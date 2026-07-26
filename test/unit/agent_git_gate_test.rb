require "test_helper"
require "hive/agent_git_gate"

class AgentGitGateTest < Minitest::Test
  include HiveTestHelper

  def test_closed_reads_reject_unknown_operations_and_arguments_before_spawn
    assert_raises(Hive::AgentGitGate::UnsupportedOperation) do
      Hive::AgentGitGate.read("/tmp", :config)
    end
    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate.read("/tmp", :status, executable_helper: "/tmp/escape")
    end
    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate.read("/tmp", :commit_oid, oid: "--help")
    end
  end

  def test_hardened_reads_do_not_execute_repository_selected_helpers
    with_tmp_git_repo do |repo|
      marker = File.join(repo, "fsmonitor-ran")
      helper = File.join(repo, "fsmonitor-helper")
      File.write(helper, <<~SH)
        #!/bin/sh
        : > "#{marker}"
        printf '\n'
      SH
      File.chmod(0o755, helper)
      run!("git", "-C", repo, "config", "core.fsmonitor", helper)

      run!("git", "-C", repo, "status", "--porcelain=v1")
      assert File.exist?(marker), "precondition: ordinary Git invokes the helper"
      FileUtils.rm_f(marker)

      result = Hive::AgentGitGate.read(repo, :status)

      assert result.success?, result.stderr
      refute File.exist?(marker)
      assert_predicate result.stdout, :frozen?
      assert_predicate result.stderr, :frozen?
    end
  end

  def test_exact_materialization_does_not_execute_repository_hooks
    with_tmp_git_repo do |repo|
      oid = commit_file(repo, "one.txt", "one\n", "one")
      Dir.mktmpdir("agent-git-hooks") do |root|
        marker = File.join(root, "post-checkout-ran")
        hooks = File.join(root, "hooks")
        FileUtils.mkdir_p(hooks)
        hook = File.join(hooks, "post-checkout")
        File.write(hook, "#!/bin/sh\n: > \"#{marker}\"\n")
        File.chmod(0o755, hook)
        run!("git", "-C", repo, "config", "core.hooksPath", hooks)

        ordinary = File.join(root, "ordinary")
        run!("git", "-C", repo, "worktree", "add", "--detach", ordinary, oid)
        assert File.exist?(marker), "precondition: ordinary worktree add invokes the hook"
        run!("git", "-C", repo, "worktree", "remove", ordinary)
        FileUtils.rm_f(marker)

        managed_root = File.join(root, "managed")
        FileUtils.mkdir_p(managed_root)
        Hive::AgentGitGate.materialize(
          repository_path: repo, oid: oid,
          destination: File.join(managed_root, "exact"),
          destination_root: managed_root
        )
        refute File.exist?(marker)
      end
    end
  end

  def test_repository_selected_content_filters_fail_closed_before_execution
    with_tmp_git_repo do |repo|
      commit_file(repo, "filtered.txt", "raw\n", "filtered fixture")
      Dir.mktmpdir("agent-git-filter") do |root|
        marker = File.join(root, "filter-ran")
        helper = File.join(root, "filter-helper")
        File.write(helper, <<~SH)
          #!/bin/sh
          : > "#{marker}"
          cat
        SH
        File.chmod(0o755, helper)
        File.write(File.join(repo, ".gitattributes"), "*.txt filter=agent-helper\n")
        run!("git", "-C", repo, "add", ".gitattributes")
        run!("git", "-C", repo, "commit", "-m", "select filter", "--quiet")
        oid = run!("git", "-C", repo, "rev-parse", "HEAD").strip
        run!("git", "-C", repo, "config", "filter.agent-helper.smudge", helper)

        ordinary = File.join(root, "ordinary")
        run!("git", "-C", repo, "worktree", "add", "--detach", ordinary, oid)
        assert File.exist?(marker), "precondition: ordinary checkout invokes the filter"
        run!("git", "-C", repo, "worktree", "remove", ordinary)
        FileUtils.rm_f(marker)

        managed_root = File.join(root, "managed")
        FileUtils.mkdir_p(managed_root)
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: oid,
            destination: File.join(managed_root, "exact"),
            destination_root: managed_root
          )
        end
        refute File.exist?(marker)
        refute File.exist?(File.join(managed_root, "exact"))
      end
    end
  end

  def test_exact_publication_requires_expected_state_and_returns_remote_proof
    with_local_remote do |repo, remote|
      first = commit_file(repo, "first.txt", "first\n", "first")

      receipt = Hive::AgentGitGate.publish(
        repository_path: repo,
        oid: first,
        branch: "agent/change",
        remote: remote,
        expected_remote_absent: true,
        allow_local_transport: true
      )

      assert receipt.success?
      assert_nil receipt.before_oid
      assert_nil receipt.expected_oid
      assert_equal first, receipt.after_oid
      assert_equal first, receipt.published_oid
      refute_includes receipt.inspect, remote

      conflict = assert_raises(Hive::AgentGitGate::RemoteConflict) do
        Hive::AgentGitGate.publish(
          repository_path: repo,
          oid: first,
          branch: "agent/change",
          remote: remote,
          expected_remote_absent: true,
          allow_local_transport: true
        )
      end
      assert_match(/changed before exact publication/, conflict.message)

      second = commit_file(repo, "second.txt", "second\n", "second")
      replacement = Hive::AgentGitGate.publish(
        repository_path: repo,
        oid: second,
        branch: "agent/change",
        remote: remote,
        expected_remote_oid: first,
        allow_local_transport: true
      )
      assert_equal first, replacement.before_oid
      assert_equal first, replacement.expected_oid
      assert_equal second, replacement.after_oid
    end
  end

  def test_publication_rejects_missing_expectation_and_forbidden_transports
    with_tmp_git_repo do |repo|
      oid = commit_file(repo, "one.txt", "one\n", "one")

      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.publish(
          repository_path: repo, oid: oid, branch: "agent/change",
          remote: "https://example.com/repo.git"
        )
      end
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.observe_remote_branch(
          repository_path: repo, branch: "main", remote: "ext::helper %S repo"
        )
      end
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.observe_remote_branch(
          repository_path: repo, branch: "main", remote: "/tmp/local.git"
        )
      end
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.observe_remote_branch(
          repository_path: repo, branch: "main",
          remote: "https://token@example.com/repo.git"
        )
      end
    end
  end

  def test_exact_detached_materialization_is_stale_safe_and_root_constrained
    with_tmp_git_repo do |repo|
      oid = commit_file(repo, "one.txt", "one\n", "one")
      Dir.mktmpdir("agent-git-materialization") do |root|
        destination = File.join(root, "exact")
        created = Hive::AgentGitGate.materialize(
          repository_path: repo, oid: oid,
          destination: destination, destination_root: root
        )
        existing = Hive::AgentGitGate.materialize(
          repository_path: repo, oid: oid,
          destination: destination, destination_root: root
        )

        assert_equal :created, created.disposition
        assert_equal :existing, existing.disposition
        assert_equal oid, created.oid
        assert_equal "", run!("git", "-C", destination, "branch", "--show-current").strip
        assert_equal oid, run!("git", "-C", destination, "rev-parse", "HEAD").strip

        File.write(File.join(destination, "dirty.txt"), "dirty\n")
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: oid,
            destination: destination, destination_root: root
          )
        end
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: oid,
            destination: File.join(root, "..", "escape"), destination_root: root
          )
        end

        outside = Dir.mktmpdir("agent-git-outside")
        File.symlink(outside, File.join(root, "linked"))
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: oid,
            destination: File.join(root, "linked", "escape"),
            destination_root: root
          )
        end
        FileUtils.remove_entry(outside)
      end
    end
  end

  def test_remote_materialization_refuses_ref_movement_after_observation
    with_local_remote do |repo, remote|
      first = commit_file(repo, "first.txt", "first\n", "first")
      Hive::AgentGitGate.publish(
        repository_path: repo, oid: first, branch: "source",
        remote: remote, expected_remote_absent: true,
        allow_local_transport: true
      )
      observation = Hive::AgentGitGate.observe_remote_branch(
        repository_path: repo, branch: "source", remote: remote,
        allow_local_transport: true
      )
      second = commit_file(repo, "second.txt", "second\n", "second")
      Hive::AgentGitGate.publish(
        repository_path: repo, oid: second, branch: "source",
        remote: remote, expected_remote_oid: first,
        allow_local_transport: true
      )

      Dir.mktmpdir("agent-git-remote-materialization") do |root|
        assert_raises(Hive::AgentGitGate::RemoteConflict) do
          Hive::AgentGitGate.materialize_remote(
            repository_path: repo, remote: remote,
            observation: observation,
            destination: File.join(root, "exact"), destination_root: root,
            allow_local_transport: true
          )
        end
        refute File.exist?(File.join(root, "exact"))

        current = Hive::AgentGitGate.observe_remote_branch(
          repository_path: repo, branch: "source", remote: remote,
          allow_local_transport: true
        )
        receipt = Hive::AgentGitGate.materialize_remote(
          repository_path: repo, remote: remote,
          observation: current,
          destination: File.join(root, "current"), destination_root: root,
          allow_local_transport: true
        )
        assert_equal second, receipt.oid
      end
    end
  end

  private

  def with_local_remote
    Dir.mktmpdir("agent-git-remote") do |root|
      remote = File.join(root, "remote.git")
      run!("git", "init", "--bare", "--quiet", remote)
      with_tmp_git_repo { |repo| yield repo, remote }
    end
  end

  def commit_file(repo, name, content, message)
    File.write(File.join(repo, name), content)
    run!("git", "-C", repo, "add", name)
    run!("git", "-C", repo, "commit", "-m", message, "--quiet")
    run!("git", "-C", repo, "rev-parse", "HEAD").strip
  end
end
