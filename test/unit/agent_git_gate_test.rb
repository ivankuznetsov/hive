require "test_helper"
require "hive/agent_git_gate"

class AgentGitGateTest < Minitest::Test
  include HiveTestHelper

  GateStatus = Data.define(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

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

  def test_repository_selected_transport_and_credential_helpers_fail_closed
    dangerous = {
      "credential.helper" => "!false",
      "url.ext::false.insteadOf" => "https://example.com/",
      "remote.origin.uploadpack" => "/tmp/agent-selected-upload-pack",
      "core.alternateRefsCommand" => "/tmp/agent-selected-alternate-refs",
      "core.worktree" => "/tmp/agent-selected-worktree",
      "http.sslVerify" => "false"
    }

    with_tmp_git_repo do |repo|
      dangerous.each do |name, value|
        run!("git", "-C", repo, "config", "--local", name, value)
        error = assert_raises(Hive::AgentGitGate::InvalidRequest, name) do
          Hive::AgentGitGate.read(repo, :head_oid)
        end
        assert_includes error.message, "executable Git helpers", name
        run!("git", "-C", repo, "config", "--local", "--unset", name)
      end
    end
  end

  def test_repository_selected_helpers_in_included_local_config_fail_closed
    with_tmp_git_repo do |repo|
      Dir.mktmpdir("agent-git-included-config") do |root|
        included = File.join(root, "included.config")
        File.write(included, <<~CONFIG)
          [filter "audit"]
            clean = /tmp/agent-selected-filter
        CONFIG
        run!("git", "-C", repo, "config", "--local", "include.path", included)
        assert_equal "/tmp/agent-selected-filter", run!(
          "git", "-C", repo, "config", "--local", "--includes",
          "--get", "filter.audit.clean"
        ).strip

        error = assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.read(repo, :head_oid)
        end
        assert_includes error.message, "executable Git helpers"
      end
    end
  end

  def test_repository_config_inspection_failure_fails_closed
    failed = GateStatus.new(exitstatus: 1)
    with_replaced_singleton_method(
      Hive::ManagedGit, :executable_local_config,
      ->(*) { [ [], "inspection failed", failed ] }
    ) do
      error = assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.read("/tmp", :head_oid)
      end
      assert_includes error.message, "could not be inspected safely"
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

  def test_closed_read_vocabulary_covers_object_history_and_diff_queries
    with_tmp_git_repo do |repo|
      base = commit_file(repo, "one.txt", "one\n", "one")
      head = commit_file(repo, "two.txt", "two\n", "two")

      assert_equal head, Hive::AgentGitGate.read(repo, :commit_oid, oid: head).stdout.strip
      assert Hive::AgentGitGate.read(repo, :ancestor, base_oid: base, head_oid: head).success?
      assert_equal "1", Hive::AgentGitGate.read(
        repo, :commit_count, base_oid: base, head_oid: head
      ).stdout.strip
      assert_equal [ head ], Hive::AgentGitGate.read(
        repo, :commits, base_oid: base, head_oid: head
      ).stdout.lines.map(&:strip)
      assert_predicate Hive::AgentGitGate.read(
        repo, :object_list, base_oid: base, head_oid: head
      ).stdout, :frozen?
      assert_equal "commit", Hive::AgentGitGate.read(repo, :object_type, oid: head).stdout.strip
      assert_operator Integer(
        Hive::AgentGitGate.read(repo, :object_size, oid: head).stdout.strip, 10
      ), :positive?
      assert_equal "two\n", Hive::AgentGitGate.read(
        repo, :object_content, oid: head, path: "two.txt"
      ).stdout
      assert_equal [ "two.txt" ], Hive::AgentGitGate.read(
        repo, :changed_paths, base_oid: base, head_oid: head
      ).stdout.split("\0")
      assert_includes Hive::AgentGitGate.read(
        repo, :diff, base_oid: base, head_oid: head
      ).stdout, "two.txt"
      assert_includes Hive::AgentGitGate.read(repo, :commit_patch, oid: head).stdout, "two"

      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.read(repo, :object_content, oid: head, path: "/etc/passwd")
      end
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.read(repo, :status, max_stdout_bytes: Object.new)
      end
    end
  end

  def test_materialization_rejects_mismatched_objects_and_unsafe_destinations
    with_tmp_git_repo do |repo|
      first = commit_file(repo, "one.txt", "one\n", "one")
      second = commit_file(repo, "two.txt", "two\n", "two")
      Dir.mktmpdir("agent-git-materialization-errors") do |root|
        occupied = File.join(root, "occupied")
        File.write(occupied, "not a worktree\n")
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: occupied, destination_root: root
          )
        end

        attached = File.join(root, "attached")
        run!("git", "-C", repo, "branch", "agent-attached", first)
        run!("git", "-C", repo, "worktree", "add", attached, "agent-attached")
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: attached, destination_root: root
          )
        end

        mismatched = File.join(root, "mismatched")
        run!("git", "-C", repo, "worktree", "add", "--detach", mismatched, first)
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: second,
            destination: mismatched, destination_root: root
          )
        end

        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: File.join(root, "missing", "exact"),
            destination_root: File.join(root, "missing")
          )
        end

        outside = Dir.mktmpdir("agent-git-materialization-outside")
        File.symlink(outside, File.join(root, "outside-link"))
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: File.join(root, "outside-link"), destination_root: root
          )
        end
        File.symlink(File.join(root, "missing-target"), File.join(root, "broken-link"))
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: File.join(root, "broken-link"), destination_root: root
          )
        end
        File.symlink(root, File.join(root, "root-link"))
        assert_raises(Hive::AgentGitGate::InvalidRequest) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: File.join(root, "root-link"), destination_root: root
          )
        end
        FileUtils.remove_entry(outside)
      end

      with_replaced_singleton_method(
        Hive::AgentGitGate, :command!, ->(*) { "f" * 40 }
      ) do
        Dir.mktmpdir("agent-git-resolution-mismatch") do |root|
          assert_raises(Hive::AgentGitGate::MaterializationFailed) do
            Hive::AgentGitGate.materialize(
              repository_path: repo, oid: first,
              destination: File.join(root, "exact"), destination_root: root
            )
          end
        end
      end
      with_replaced_singleton_method(
        Hive::AgentGitGate, :contained_destination,
        ->(*) { raise Errno::EACCES, "blocked" }
      ) do
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.materialize(
            repository_path: repo, oid: first,
            destination: "/tmp/exact", destination_root: "/tmp"
          )
        end
      end
    end
  end

  def test_materialization_removal_requires_repository_registration
    with_tmp_git_repo do |repo|
      oid = commit_file(repo, "one.txt", "one\n", "one")
      Dir.mktmpdir("agent-git-materialization-removal") do |root|
        destination = File.join(root, "exact")
        Hive::AgentGitGate.materialize(
          repository_path: repo, oid: oid,
          destination: destination, destination_root: root
        )
        assert_equal :removed, Hive::AgentGitGate.remove_materialization(
          repository_path: repo, destination: destination, destination_root: root
        )
        assert_equal :absent, Hive::AgentGitGate.remove_materialization(
          repository_path: repo,
          destination: File.join(root, "absent"), destination_root: root
        )

        unregistered = File.join(root, "unregistered")
        FileUtils.mkdir_p(unregistered)
        assert_raises(Hive::AgentGitGate::MaterializationFailed) do
          Hive::AgentGitGate.remove_materialization(
            repository_path: repo,
            destination: unregistered, destination_root: root
          )
        end
      end
    end
  end

  def test_remote_observation_rejects_ambiguous_invalid_and_changed_targets
    absent = Hive::AgentGitGate::RemoteObservation.new(
      remote_fingerprint: "f" * 64, branch: "main",
      ref: "refs/heads/main", oid: nil
    )
    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate.materialize_remote(
        repository_path: "/tmp", remote: "https://example.com/repo.git",
        observation: absent, destination: "/tmp/root/exact",
        destination_root: "/tmp/root"
      )
    end

    present = absent.with(oid: "a" * 40)
    assert_raises(Hive::AgentGitGate::RemoteConflict) do
      Hive::AgentGitGate.materialize_remote(
        repository_path: "/tmp", remote: "https://example.com/repo.git",
        observation: present, destination: "/tmp/root/exact",
        destination_root: "/tmp/root"
      )
    end

    with_replaced_singleton_method(
      Hive::AgentGitGate, :remote_urls, ->(**) { %w[https://one.example/repo.git https://two.example/repo.git] }
    ) do
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.observe_remote_branch(
          repository_path: "/tmp", branch: "main", remote: "origin"
        )
      end
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.send(
          :resolve_remote_target, "/tmp", "origin",
          push: true, allow_local_transport: false
        )
      end
    end
    with_replaced_singleton_method(
      Hive::AgentGitGate, :remote_urls, ->(**) { [ "https://one.example/repo.git" ] }
    ) do
      assert_equal "https://one.example/repo.git", Hive::AgentGitGate.send(
        :resolve_remote_target, "/tmp", "origin",
        push: false, allow_local_transport: false
      )
    end

    successful = GateStatus.new(exitstatus: 0)
    outputs = [
      "#{'a' * 40}\trefs/heads/main\n#{'b' * 40}\trefs/heads/main\n",
      "not-an-oid\trefs/heads/main\n"
    ]
    with_replaced_singleton_method(
      Hive::AgentGitGate, :capture,
      ->(*) { [ outputs.shift, "", successful, false ] }
    ) do
      2.times do
        assert_raises(Hive::AgentGitGate::CommandFailed) do
          Hive::AgentGitGate.observe_remote_branch(
            repository_path: "/tmp", branch: "main",
            remote: "https://example.com/repo.git"
          )
        end
      end
    end

    failed = Hive::AgentGitGate::ReadResult.new(
      operation: :remote_urls, stdout: "", stderr: "failed",
      exitstatus: 1, overflow: false
    )
    with_replaced_singleton_method(
      Hive::AgentGitGate, :read_result, ->(*) { failed }
    ) do
      assert_raises(Hive::AgentGitGate::CommandFailed) do
        Hive::AgentGitGate.remote_urls(repository_path: "/tmp")
      end
    end
  end

  def test_transport_and_branch_validation_cover_supported_and_refused_shapes
    accepted = [
      "git@example.com:acme/repo.git",
      "https://example.com/acme/repo.git",
      "https://example.com:8443/acme/repo.git",
      "ssh://git@example.com:2222/acme/repo.git",
      "git://reader@example.com:9418/acme/repo.git"
    ]
    accepted.each do |target|
      value = Hive::AgentGitGate.send(
        :validate_transport_target, target, allow_local_transport: false
      )
      assert_equal target, value
      assert_predicate value, :frozen?
    end

    [
      "-bad",
      "http://example.com/repo.git",
      "ssh:///repo.git",
      "ssh://git@/repo.git",
      "ssh://git@@example.com/repo.git",
      "https://token@example.com/repo.git",
      "ssh://git:token@example.com/repo.git",
      "git://reader%3Atoken@example.com/repo.git"
    ].each do |target|
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.send(
          :validate_transport_target, target, allow_local_transport: false
        )
      end
    end
    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate.observe_remote_branch(
        repository_path: "/tmp", branch: "bad//branch",
        remote: "https://example.com/repo.git"
      )
    end
  end

  def test_public_values_reject_invalid_shapes
    valid_read = {
      operation: :status, stdout: "", stderr: "",
      exitstatus: 0, overflow: false
    }
    [
      valid_read.merge(operation: Object.new),
      valid_read.merge(stdout: Object.new),
      valid_read.merge(overflow: nil),
      valid_read.merge(exitstatus: -1),
      valid_read.merge(exitstatus: Object.new)
    ].each do |attributes|
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate::ReadResult.new(**attributes)
      end
    end

    valid_observation = {
      remote_fingerprint: "f" * 64, branch: "main",
      ref: "refs/heads/main", oid: "a" * 40
    }
    [
      valid_observation.merge(remote_fingerprint: "not-a-fingerprint"),
      valid_observation.merge(branch: "bad//branch", ref: "refs/heads/bad//branch"),
      valid_observation.merge(ref: "refs/heads/other"),
      valid_observation.merge(oid: "not-an-oid")
    ].each do |attributes|
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate::RemoteObservation.new(**attributes)
      end
    end

    valid_materialization = {
      destination: "/tmp/agent-git/exact",
      oid: "a" * 40,
      disposition: :created
    }
    [
      valid_materialization.merge(destination: "relative"),
      valid_materialization.merge(oid: "not-an-oid"),
      valid_materialization.merge(disposition: :unknown)
    ].each do |attributes|
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate::MaterializationReceipt.new(**attributes)
      end
    end

    valid_publication = {
      remote_fingerprint: "f" * 64, branch: "main",
      expected_oid: "a" * 40, before_oid: "a" * 40,
      published_oid: "b" * 40, after_oid: "b" * 40
    }
    [
      valid_publication.merge(remote_fingerprint: "not-a-fingerprint"),
      valid_publication.merge(branch: "bad//branch"),
      valid_publication.merge(expected_oid: "not-an-oid"),
      valid_publication.merge(before_oid: "b" * 40),
      valid_publication.merge(published_oid: "not-an-oid"),
      valid_publication.merge(after_oid: "c" * 40)
    ].each do |attributes|
      assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate::PublicationReceipt.new(**attributes)
      end
    end
  end

  def test_public_values_copy_input_bytes_and_enforce_identity_invariants
    stdout = +"output"
    stderr = +"warning"
    result = Hive::AgentGitGate::ReadResult.new(
      operation: "status", stdout: stdout, stderr: stderr,
      exitstatus: "0", overflow: false
    )
    stdout.replace("changed")
    stderr.replace("changed")
    assert_equal :status, result.operation
    assert_equal "output", result.stdout
    assert_equal "warning", result.stderr
    assert_predicate result.stdout, :frozen?
    assert_predicate result.stderr, :frozen?

    fingerprint = "f" * 64
    branch = +"agent/change"
    ref = +"refs/heads/agent/change"
    oid = "a" * 40
    observation = Hive::AgentGitGate::RemoteObservation.new(
      remote_fingerprint: fingerprint, branch: branch, ref: ref, oid: oid
    )
    fingerprint.replace("0" * 64)
    branch.replace("other")
    ref.replace("refs/heads/other")
    oid.replace("b" * 40)
    assert_equal "f" * 64, observation.remote_fingerprint
    assert_equal "agent/change", observation.branch
    assert_equal "refs/heads/agent/change", observation.ref
    assert_equal "a" * 40, observation.oid
    assert_predicate observation.remote_fingerprint, :frozen?
    assert_predicate observation.branch, :frozen?
    assert_predicate observation.ref, :frozen?
    assert_predicate observation.oid, :frozen?

    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate::RemoteObservation.new(
        remote_fingerprint: "f" * 64, branch: "main",
        ref: "--upload-pack=helper", oid: "a" * 40
      )
    end

    destination = +"/tmp/agent-git/exact"
    materialized_oid = "c" * 40
    materialization = Hive::AgentGitGate::MaterializationReceipt.new(
      destination: destination, oid: materialized_oid, disposition: :created
    )
    destination.replace("/tmp/changed")
    materialized_oid.replace("d" * 40)
    assert_equal "/tmp/agent-git/exact", materialization.destination
    assert_equal "c" * 40, materialization.oid
    assert_predicate materialization.destination, :frozen?
    assert_predicate materialization.oid, :frozen?

    receipt_fingerprint = "e" * 64
    receipt_branch = +"agent/change"
    published = "f" * 40
    receipt = Hive::AgentGitGate::PublicationReceipt.new(
      remote_fingerprint: receipt_fingerprint, branch: receipt_branch,
      expected_oid: nil, before_oid: nil,
      published_oid: published, after_oid: published
    )
    receipt_fingerprint.replace("0" * 64)
    receipt_branch.replace("other")
    published.replace("0" * 40)
    assert_equal "e" * 64, receipt.remote_fingerprint
    assert_equal "agent/change", receipt.branch
    assert_equal "f" * 40, receipt.published_oid
    assert_predicate receipt.remote_fingerprint, :frozen?
    assert_predicate receipt.branch, :frozen?
    assert_predicate receipt.published_oid, :frozen?
    assert_raises(Hive::AgentGitGate::InvalidRequest) do
      Hive::AgentGitGate::PublicationReceipt.new(
        remote_fingerprint: "f" * 64, branch: "main",
        expected_oid: "a" * 40, before_oid: "b" * 40,
        published_oid: "c" * 40, after_oid: "c" * 40
      )
    end
  end

  def test_publication_refuses_unverifiable_local_and_remote_outcomes
    oid = "a" * 40
    with_replaced_singleton_method(
      Hive::AgentGitGate, :command!, ->(*) { "b" * 40 }
    ) do
      assert_raises(Hive::AgentGitGate::PublicationFailed) do
        Hive::AgentGitGate.publish(
          repository_path: "/tmp", oid: oid, branch: "agent/change",
          remote: "https://example.com/repo.git",
          expected_remote_absent: true
        )
      end
    end

    assert_stubbed_publication_failure(
      before_oid: nil, after_oid: "b" * 40, exitstatus: 1,
      error_class: Hive::AgentGitGate::RemoteConflict,
      message: "changed during exact publication"
    )
    assert_stubbed_publication_failure(
      before_oid: nil, after_oid: nil, exitstatus: 0,
      error_class: Hive::AgentGitGate::PublicationFailed,
      message: "was not observable"
    )
    assert_stubbed_publication_failure(
      before_oid: nil, after_oid: nil, exitstatus: 1,
      error_class: Hive::AgentGitGate::PublicationFailed,
      message: "publication failed"
    )

    with_replaced_singleton_method(
      Hive::AgentGitGate, :publication_expectation,
      ->(*) { raise TypeError, "invalid expectation type" }
    ) do
      error = assert_raises(Hive::AgentGitGate::InvalidRequest) do
        Hive::AgentGitGate.publish(
          repository_path: "/tmp", oid: oid, branch: "agent/change",
          remote: "https://example.com/repo.git",
          expected_remote_absent: true
        )
      end
      assert_includes error.message, "invalid expectation type"
    end
  end

  private

  def assert_stubbed_publication_failure(before_oid:, after_oid:, exitstatus:,
                                         error_class:, message:)
    oid = "a" * 40
    observations = [ before_oid, after_oid ].map do |observed_oid|
      Hive::AgentGitGate::RemoteObservation.new(
        remote_fingerprint: "f" * 64, branch: "agent/change",
        ref: "refs/heads/agent/change", oid: observed_oid
      )
    end
    with_replaced_singleton_method(
      Hive::AgentGitGate, :command!, ->(*) { oid }
    ) do
      with_replaced_singleton_method(
        Hive::AgentGitGate, :resolve_remote_target,
        ->(*) { "https://example.com/repo.git" }
      ) do
        with_replaced_singleton_method(
          Hive::AgentGitGate, :observe_resolved_remote,
          ->(*) { observations.shift }
        ) do
          with_replaced_singleton_method(
            Hive::AgentGitGate, :capture,
            ->(*) { [ "", "", GateStatus.new(exitstatus: exitstatus), false ] }
          ) do
            error = assert_raises(error_class) do
              Hive::AgentGitGate.publish(
                repository_path: "/tmp", oid: oid, branch: "agent/change",
                remote: "https://example.com/repo.git",
                expected_remote_absent: true
              )
            end
            assert_includes error.message, message
          end
        end
      end
    end
  end

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
