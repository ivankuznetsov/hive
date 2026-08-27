require "test_helper"
require "open3"
require "hive/agent_git_gate"
require "hive/patrol_fix/agent_git_isolation"

class PatrolFixAgentGitIsolationTest < Minitest::Test
  include HiveTestHelper

  Profile = Data.define(:relative_configuration_directory) do
    def configuration_directory(home:, environment:)
      File.join(home, relative_configuration_directory)
    end
  end

  EnvironmentProfile = Data.define(:environment_key) do
    def configuration_directory(home:, environment:)
      environment.fetch(environment_key)
    end
  end

  def test_fix_sandbox_contains_git_config_writes_and_adopts_the_agent_commit
    with_isolated_repository do |repo, task_folder, home|
      repository_config = git(repo, "rev-parse", "--path-format=absolute", "--git-path", "config").strip
      common_dir = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip
      git_dir = git(repo, "rev-parse", "--absolute-git-dir").strip
      worktree_pointer = File.join(repo, ".git")
      global_config = File.join(home, ".gitconfig")
      xdg_config = File.join(home, ".config", "git", "config")
      originals = [ repository_config, worktree_pointer, global_config, xdg_config ].to_h do |path|
        [ path, File.binread(path) ]
      end
      base = git(repo, "rev-parse", "HEAD").strip
      output = File.join(task_folder, "patrol-fix-fix-report.json")
      replacement = File.join(task_folder, "replacement-config")
      File.write(replacement, "[hostile]\n\tvalue = replacement\n")

      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo,
        task_folder: task_folder,
        writable_worktree: true
      )
      script = <<~SH
        set -eu
        git config --local agent.private true
        if printf '[hostile]\n\tvalue = direct\n' > "$HOST_REPOSITORY_CONFIG"; then exit 71; fi
        if mv "$HOST_REPLACEMENT_CONFIG" "$HOST_REPOSITORY_CONFIG"; then exit 72; fi
        if printf '[hostile]\n\tvalue = global\n' > "$HOST_GLOBAL_CONFIG"; then exit 73; fi
        if printf '[hostile]\n\tvalue = xdg\n' > "$HOST_XDG_CONFIG"; then exit 74; fi
        if printf 'gitdir: /tmp/foreign\n' > .git; then exit 75; fi
        printf 'puts :changed\n' > app.rb
        git add app.rb
        git commit -m 'Fix isolated change'
        printf '{}\n' > "$REPORT_PATH"
      SH
      environment = isolation.environment.merge(
        "HOST_REPOSITORY_CONFIG" => repository_config,
        "HOST_REPLACEMENT_CONFIG" => replacement,
        "HOST_GLOBAL_CONFIG" => global_config,
        "HOST_XDG_CONFIG" => xdg_config,
        "REPORT_PATH" => output
      )

      _stdout, stderr, status = Open3.capture3(
        environment, *isolation.command_prefix, "/bin/sh", "-c", script,
        chdir: repo
      )
      assert status.success?, stderr

      receipt = isolation.adopt!
      head = git(repo, "rev-parse", "HEAD").strip
      refute_equal base, head
      assert_equal head, receipt.head_oid
      assert_empty git(repo, "status", "--porcelain")
      assert_equal "puts :changed\n", File.binread(File.join(repo, "app.rb"))
      assert File.file?(output)
      originals.each { |path, bytes| assert_equal bytes, File.binread(path), path }
      assert_equal "true", git(
        isolation.metadata.git_dir, "config", "--local", "--get", "agent.private"
      ).strip
    ensure
      isolation&.cleanup!
    end
  end

  def test_read_only_sandbox_denies_source_and_shared_config_writes_but_allows_report
    with_isolated_repository do |repo, task_folder, _home|
      repository_config = git(repo, "rev-parse", "--path-format=absolute", "--git-path", "config").strip
      original_source = File.binread(File.join(repo, "app.rb"))
      original_config = File.binread(repository_config)
      output = File.join(task_folder, "patrol-fix-review-report.json")

      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo,
        task_folder: task_folder,
        writable_worktree: false
      )
      script = <<~SH
        set -eu
        git config --local review.private true
        if printf 'puts :tampered\n' > app.rb; then exit 81; fi
        if printf '[hostile]\n\tvalue = direct\n' > "$HOST_REPOSITORY_CONFIG"; then exit 82; fi
        printf '{}\n' > "$REPORT_PATH"
      SH
      environment = isolation.environment.merge(
        "HOST_REPOSITORY_CONFIG" => repository_config,
        "REPORT_PATH" => output
      )

      _stdout, stderr, status = Open3.capture3(
        environment, *isolation.command_prefix, "/bin/sh", "-c", script,
        chdir: repo
      )

      assert status.success?, stderr
      assert_equal original_source, File.binread(File.join(repo, "app.rb"))
      assert_equal original_config, File.binread(repository_config)
      assert File.file?(output)
      assert_equal "true", git(
        isolation.metadata.git_dir, "config", "--local", "--get", "review.private"
      ).strip
    ensure
      isolation&.cleanup!
    end
  end

  def test_regular_worktree_git_directory_is_read_only_while_agent_commits_privately
    with_isolated_repository do |_repo, task_folder, _home, source|
      base = git(source, "rev-parse", "HEAD").strip
      git_head = File.join(source, ".git", "HEAD")
      original_git_head = File.binread(git_head)
      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: source, task_folder: task_folder,
        writable_worktree: true
      )
      script = <<~SH
        set -eu
        printf 'puts :regular_changed\n' > app.rb
        git add app.rb
        git commit -m 'Fix regular isolated change'
      SH

      _stdout, stderr, status = Open3.capture3(
        isolation.environment,
        *isolation.command_prefix, "/bin/sh", "-c", script,
        chdir: source
      )
      assert status.success?, stderr

      receipt = isolation.adopt!
      refute_equal base, receipt.head_oid
      assert_equal receipt.head_oid, git(source, "rev-parse", "HEAD").strip
      assert_equal original_git_head, File.binread(git_head)
      assert_empty git(source, "status", "--porcelain")
    ensure
      isolation&.cleanup!
    end
  end

  def test_absent_external_git_config_cannot_be_created
    isolation = nil
    with_isolated_repository do |repo, task_folder, home|
      absent_config = File.join(File.dirname(home), "external-config", "gitconfig")
      with_env("GIT_CONFIG_GLOBAL" => absent_config) do
        isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false
        )
        script = <<~SH
          if mkdir -p "$(dirname "$HOST_ABSENT_CONFIG")" 2>/dev/null &&
             printf 'hostile\n' > "$HOST_ABSENT_CONFIG" 2>/dev/null; then
            exit 92
          fi
          exit 0
        SH
        _stdout, stderr, status = Open3.capture3(
          isolation.environment.merge("HOST_ABSENT_CONFIG" => absent_config),
          *isolation.command_prefix, "/bin/sh", "-c", script,
          chdir: repo
        )
        assert status.success?, stderr
      end
      refute File.exist?(absent_config)
    ensure
      isolation&.cleanup!
    end
  end

  def test_read_only_root_denies_sibling_and_unrelated_host_writes
    isolation = nil
    with_isolated_repository do |repo, task_folder, _home, source|
      sibling = File.join(source, "app.rb")
      unrelated = File.join(File.dirname(repo), "unrelated.txt")
      File.write(unrelated, "untouched\n")
      output = File.join(task_folder, "patrol-fix-review-report.json")
      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: false
      )
      script = <<~SH
        set -eu
        if printf 'tampered\\n' > "$HOST_SIBLING"; then exit 101; fi
        if printf 'tampered\\n' > "$HOST_UNRELATED"; then exit 102; fi
        printf '{}\\n' > "$REPORT_PATH"
      SH

      _stdout, stderr, status = Open3.capture3(
        isolation.environment.merge(
          "HOST_SIBLING" => sibling,
          "HOST_UNRELATED" => unrelated,
          "REPORT_PATH" => output
        ),
        *isolation.command_prefix, "/bin/sh", "-c", script, chdir: repo
      )

      assert status.success?, stderr
      assert_equal "puts :original\n", File.binread(sibling)
      assert_equal "untouched\n", File.binread(unrelated)
      assert_equal "{}\n", File.binread(output)
    ensure
      isolation&.cleanup!
    end
  end

  def test_absent_git_configs_leave_selected_provider_state_and_report_writable
    isolation = nil
    with_isolated_repository do |repo, task_folder, home|
      File.unlink(File.join(home, ".gitconfig"))
      File.unlink(File.join(home, ".config", "git", "config"))
      provider_state = File.join(home, ".config", "provider-state")
      FileUtils.mkdir_p(provider_state)
      output = File.join(task_folder, "patrol-fix-review-report.json")
      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: false,
        profile: EnvironmentProfile.new("HIVE_TEST_PROVIDER_STATE"),
        provider_environment: { "HIVE_TEST_PROVIDER_STATE" => provider_state }
      )
      script = <<~SH
        set -eu
        printf 'provider-state\\n' > "$PROVIDER_STATE/provider.txt"
        printf '{}\\n' > "$REPORT_PATH"
      SH

      _stdout, stderr, status = Open3.capture3(
        isolation.environment.merge(
          "PROVIDER_STATE" => provider_state,
          "REPORT_PATH" => output
        ),
        *isolation.command_prefix, "/bin/sh", "-c", script, chdir: repo
      )

      assert status.success?, stderr
      assert_equal "provider-state\n", File.binread(File.join(provider_state, "provider.txt"))
      assert_equal "{}\n", File.binread(output)
    ensure
      isolation&.cleanup!
    end
  end

  def test_nested_git_discovery_is_not_redirected_to_private_metadata
    isolation = nil
    with_isolated_repository do |repo, task_folder, _home|
      nested = File.join(task_folder, "nested-fixture")
      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: false
      )
      script = <<~SH
        set -eu
        mkdir -p "$NESTED"
        git -C "$NESTED" init -q
        git -C "$NESTED" config user.email fixture@example.invalid
        git -C "$NESTED" config user.name Fixture
        printf 'fixture\\n' > "$NESTED/file.txt"
        git -C "$NESTED" add file.txt
        git -C "$NESTED" commit -qm fixture
      SH

      _stdout, stderr, status = Open3.capture3(
        isolation.environment.merge("NESTED" => nested),
        *isolation.command_prefix, "/bin/sh", "-c", script, chdir: repo
      )

      assert status.success?, stderr
      assert_equal isolation.metadata.base_oid,
                   git(isolation.metadata.git_dir, "rev-parse", "HEAD").strip
      assert_equal "fixture", git(nested, "log", "-1", "--format=%s").strip
      %w[GIT_DIR GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_WORK_TREE].each do |key|
        refute isolation.environment.key?(key), key
      end
    ensure
      isolation&.cleanup!
    end
  end

  def test_checked_out_submodule_git_pointer_cannot_be_replaced
    isolation = nil
    with_isolated_repository do |repo, task_folder, _home, source|
      module_repo = File.join(File.dirname(repo), "module-source")
      FileUtils.mkdir_p(module_repo)
      git(module_repo, "init", "-b", "main")
      git(module_repo, "config", "user.email", "module@example.invalid")
      git(module_repo, "config", "user.name", "Module")
      File.write(File.join(module_repo, "module.rb"), "puts :module\n")
      git(module_repo, "add", "module.rb")
      git(module_repo, "commit", "-m", "module")
      git(source, "-c", "protocol.file.allow=always", "submodule", "add", module_repo, "vendor/module")
      git(source, "commit", "-m", "Add module")
      git(repo, "merge", "--no-edit", "main")
      git(repo, "-c", "protocol.file.allow=always", "submodule", "update", "--init")
      pointer = File.join(repo, "vendor", "module", ".git")
      replacement = File.join(task_folder, "replacement-submodule-git")
      File.write(replacement, "gitdir: /tmp/foreign\n")
      original = File.binread(pointer)

      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: true
      )
      script = <<~SH
        set -eu
        if printf 'gitdir: /tmp/foreign\\n' > "$SUBMODULE_POINTER"; then exit 111; fi
        if mv "$REPLACEMENT" "$SUBMODULE_POINTER"; then exit 112; fi
      SH

      _stdout, stderr, status = Open3.capture3(
        isolation.environment.merge(
          "SUBMODULE_POINTER" => pointer,
          "REPLACEMENT" => replacement
        ),
        *isolation.command_prefix, "/bin/sh", "-c", script, chdir: repo
      )

      assert status.success?, stderr
      assert_equal original, File.binread(pointer)
    ensure
      isolation&.cleanup!
    end
  end

  def test_pre_resolved_git_controls_are_reused_without_more_git_probes
    isolation = nil
    with_isolated_repository do |repo, task_folder, _home|
      controls = Hive::PatrolFix::AgentGitIsolation.git_control_paths!(repo)
      unexpected = lambda do |*|
        raise "Git control paths were resolved more than once"
      end
      isolation = with_replaced_singleton_method(
        Hive::PatrolFix::AgentGitIsolation, :git_control_paths!, unexpected
      ) do
        Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false, git_control_paths: controls
        )
      end

      assert File.directory?(isolation.metadata.git_dir)
    ensure
      isolation&.cleanup!
    end
  end

  def test_prepare_fails_before_creating_metadata_when_bubblewrap_is_unavailable
    with_isolated_repository do |repo, task_folder, _home|
      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo,
          task_folder: task_folder,
          writable_worktree: true,
          sandbox_path: File.join(task_folder, "missing-bwrap")
        )
      end

      assert_includes error.message, "bubblewrap"
      assert_empty Dir.glob(File.join(task_folder, "agent-git-isolation-*"))
    end
  end

  def test_cleanup_failure_is_reported_without_masking_the_completed_attempt
    with_isolated_repository do |repo, task_folder, _home|
      isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo,
        task_folder: task_folder,
        writable_worktree: false
      )
      failure = lambda do |*|
        raise Errno::EACCES, "cleanup denied"
      end

      _stdout, stderr = capture_io do
        result = with_replaced_singleton_method(
          FileUtils, :remove_entry_secure, failure
        ) { isolation.cleanup! }
        assert_equal :retained, result
      end

      assert_includes stderr, "retained Patrol agent Git isolation"
      assert File.directory?(isolation.metadata.git_dir)
    ensure
      isolation&.cleanup!
    end
  end

  def test_invalid_roots_and_home_fail_before_provider_launch
    with_tmp_dir do |root|
      task_folder = File.join(root, "task")
      FileUtils.mkdir_p(task_folder)
      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.new(
          worktree_path: File.join(root, "missing"),
          task_folder: task_folder, writable_worktree: true,
          profile: nil, sandbox_path: "/usr/bin/bwrap"
        )
      end
      assert_includes error.message, "roots are unavailable"
    end

    with_isolated_repository do |repo, task_folder, _home|
      with_env("HOME" => File::SEPARATOR) do
        error = assert_raises(Hive::StageError) do
          Hive::PatrolFix::AgentGitIsolation.prepare!(
            worktree_path: repo, task_folder: task_folder,
            writable_worktree: true
          )
        end
        assert_includes error.message, "HOME is invalid"
      end

      with_env("HOME" => nil) do
        error = assert_raises(Hive::StageError) do
          Hive::PatrolFix::AgentGitIsolation.prepare!(
            worktree_path: repo, task_folder: task_folder,
            writable_worktree: true
          )
        end
        assert_includes error.message, "could not be prepared"
      end
    end
  end

  def test_adoption_failures_are_wrapped_at_the_stage_boundary
    with_isolated_repository do |repo, task_folder, _home|
      read_only = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: false
      )
      error = assert_raises(Hive::StageError) { read_only.adopt! }
      assert_includes error.message, "read-only"

      failed_head = Hive::AgentGitGate::ReadResult.new(
        operation: :head_oid, stdout: "", stderr: "missing",
        exitstatus: 1, overflow: false
      )
      with_replaced_singleton_method(
        Hive::AgentGitGate, :read, ->(*) { failed_head }
      ) do
        error = assert_raises(Hive::StageError) { read_only.adopt_if_changed! }
        assert_includes error.message, "HEAD is unavailable"
      end
      with_replaced_singleton_method(
        Hive::AgentGitGate, :read,
        ->(*) { raise Hive::AgentGitGate::InvalidRequest, "invalid private metadata" }
      ) do
        error = assert_raises(Hive::StageError) { read_only.adopt_if_changed! }
        assert_includes error.message, "could not be inspected"
      end
    ensure
      read_only&.cleanup!
    end

    with_isolated_repository do |repo, task_folder, _home|
      writable = Hive::PatrolFix::AgentGitIsolation.prepare!(
        worktree_path: repo, task_folder: task_folder,
        writable_worktree: true
      )
      with_replaced_singleton_method(
        Hive::AgentGitGate, :adopt_isolated_metadata,
        ->(*) { raise Hive::AgentGitGate::IsolationFailed, "adoption refused" }
      ) do
        error = assert_raises(Hive::StageError) { writable.adopt! }
        assert_includes error.message, "could not be adopted"
      end
    ensure
      writable&.cleanup!
    end
  end

  def test_provider_state_directories_are_writable_without_exposing_home
    isolation = nil
    with_isolated_repository do |repo, task_folder, home|
      state_paths = [
        File.join(home, ".first-agent", "state"),
        File.join(home, ".second-agent")
      ]
      state_paths.each { |path| FileUtils.mkdir_p(path) }

      state_paths.each do |path|
        relative = path.delete_prefix("#{home}/")
        isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false, profile: Profile.new(relative)
        )
        assert_includes isolation.command_prefix.each_cons(3).to_a,
                        [ "--bind", path, path ]
        isolation.cleanup!
      end
    ensure
      isolation&.cleanup!
    end
  end

  def test_provider_state_mounts_reject_outside_home_and_symlink_escapes
    with_isolated_repository do |repo, task_folder, home|
      outside_home = File.join(File.dirname(home), "outside-provider-state")
      FileUtils.mkdir_p(outside_home)

      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false,
          provider_environment: { "XDG_STATE_HOME" => outside_home }
        )
      end
      assert_includes error.message, "strictly below HOME"

      escaped = File.join(home, ".provider-state-escape")
      File.symlink(outside_home, escaped)
      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false,
          profile: EnvironmentProfile.new("HIVE_TEST_PROVIDER_STATE"),
          provider_environment: { "HIVE_TEST_PROVIDER_STATE" => escaped }
        )
      end
      assert_includes error.message, "strictly below HOME"
    end
  end

  def test_provider_state_mount_rejects_explicit_binding_inside_selected_worktree
    with_isolated_repository(worktree_under_home: true) do |repo, task_folder, _home|
      provider_state = File.join(repo, ".provider-state")
      FileUtils.mkdir_p(provider_state)

      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: repo, task_folder: task_folder,
          writable_worktree: false,
          profile: EnvironmentProfile.new("HIVE_TEST_PROVIDER_STATE"),
          provider_environment: { "HIVE_TEST_PROVIDER_STATE" => provider_state }
        )
      end

      assert_includes error.message, "overlaps the selected task or worktree"
    end
  end

  def test_protected_path_and_git_path_resolution_fail_closed
    with_tmp_dir do |root|
      task_folder = File.join(root, "task")
      FileUtils.mkdir_p(task_folder)
      loop_path = File.join(task_folder, "loop")
      File.symlink("loop", loop_path)
      isolation = Hive::PatrolFix::AgentGitIsolation.new(
        worktree_path: root, task_folder: task_folder,
        writable_worktree: false, profile: nil,
        sandbox_path: "/usr/bin/bwrap"
      )

      error = assert_raises(Hive::StageError) do
        isolation.send(:protected_mounts, [ loop_path ])
      end
      assert_includes error.message, "protected Git path is unavailable"

      error = assert_raises(Hive::StageError) do
        Hive::PatrolFix::AgentGitIsolation.git_control_paths!(root)
      end
      assert_includes error.message, "control path is unavailable"
    end
  end

  private

  def with_isolated_repository(worktree_under_home: false)
    with_tmp_dir do |root|
      home = File.join(root, "home")
      source = File.join(root, "source")
      repo = File.join(worktree_under_home ? home : root, "worktree")
      FileUtils.mkdir_p([ home, source, File.join(home, ".config", "git") ])
      File.write(File.join(home, ".gitconfig"), "[user]\n\tname = Host User\n")
      File.write(
        File.join(home, ".config", "git", "config"),
        "[user]\n\temail = host@example.com\n"
      )
      git(source, "init", "-b", "main")
      git(source, "config", "user.email", "test@example.com")
      git(source, "config", "user.name", "Test")
      File.write(File.join(source, ".gitignore"), ".hive-state/\n")
      File.write(File.join(source, "app.rb"), "puts :original\n")
      git(source, "add", ".gitignore", "app.rb")
      git(source, "commit", "-m", "Initial")
      git(source, "worktree", "add", "-b", "fix/repair-one", repo, "main")
      task_folder = File.join(source, ".hive-state", "stages", "2-fix", "repair-one")
      FileUtils.mkdir_p(task_folder)

      with_env(
        "HOME" => home,
        "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "GIT_CONFIG_GLOBAL" => nil,
        "GIT_CONFIG_SYSTEM" => nil
      ) { yield repo, task_folder, home, source }
    end
  end

  def git(path, *args)
    out, error, status = Open3.capture3("git", "-C", path, *args)
    raise error unless status.success?

    out
  end
end
