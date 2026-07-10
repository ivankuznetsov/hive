require "test_helper"
require "open3"
require "pty"
require "rbconfig"
require "timeout"
require "hive/babysitter/dry_run_env"

class BabysitterDryRunEnvTest < Minitest::Test
  include HiveTestHelper

  def test_with_env_intercepts_mutating_git_and_gh_calls
    with_tmp_dir do |dir|
      Hive::Babysitter::DryRunEnv.with_env(dir) do
        git_out, git_err, git_status = Open3.capture3("git", "push", "origin", "feature", "--force-with-lease")
        gh_out, gh_err, gh_status = Open3.capture3("gh", "pr", "comment", "42", "--body", "hi")

        assert git_status.success?, git_err
        assert gh_status.success?, gh_err
        assert_equal "", git_out
        assert_equal "", gh_out
      end

      log = File.read(File.join(dir, ".babysitter-dry-run-skipped.log"))
      assert_includes log, "git push origin feature --force-with-lease skipped"
      assert_includes log, "gh pr comment 42 --body hi skipped"
    end
  end

  # The shims are pure tooling that nobody reads after the block, so `with_env`
  # removes the overlay dir on exit. The skip log is left in place on purpose —
  # the test above reads it after the block returns.
  def test_with_env_removes_overlay_bin_on_exit
    with_tmp_dir do |dir|
      overlay = File.join(dir, ".hive-babysitter-dry-run-bin")

      Hive::Babysitter::DryRunEnv.with_env(dir) do
        assert File.directory?(overlay), "overlay shims must exist inside the block"
        assert File.executable?(File.join(overlay, "git"))
        assert File.executable?(File.join(overlay, "gh"))
        # Exercise a mutating command so the skip log is actually written.
        _out, _err, status = Open3.capture3("git", "push", "origin", "HEAD:feature")
        assert status.success?
      end

      refute File.exist?(overlay), "overlay-bin dir must be cleaned up on exit"
      assert File.exist?(File.join(dir, ".babysitter-dry-run-skipped.log")),
             "skip log must survive exit — it is the dry-run diagnostic record"
    end
  end

  def test_with_env_scrubs_and_restores_dynamic_loader_environment
    parent_env = {
      "LD_HIVE_TEST" => "parent-ld",
      "DYLD_HIVE_TEST" => "parent-dyld"
    }

    with_env(parent_env) do
      with_tmp_dir do |dir|
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          parent_env.each_key { |key| refute ENV.key?(key), "#{key} must not reach the dry-run agent" }
          ENV["LD_AGENT_ADDED"] = "agent-ld"
          ENV["DYLD_AGENT_ADDED"] = "agent-dyld"
        end

        assert_equal parent_env, ENV.to_h.slice(*parent_env.keys)
        refute ENV.key?("LD_AGENT_ADDED")
        refute ENV.key?("DYLD_AGENT_ADDED")
      end
    end
  end

  # The dry-run artifacts must be gitignored in the real repo so a stage-exit
  # CleanExit treats them as clean rather than out-of-scope residue. Removing
  # any of these `.gitignore` entries turns this red.
  def test_dry_run_artifacts_are_gitignored_in_repo
    repo_root = File.expand_path("../../..", __dir__)
    %w[
      .babysitter-dry-run-skipped.log
      .babysitter-dry-run-plan.md
      .hive-babysitter-dry-run-bin/git
    ].each do |path|
      _out, _err, status = Open3.capture3("git", "-C", repo_root, "check-ignore", "-q", path)
      assert status.success?, "#{path} must be gitignored (git check-ignore failed)"
    end
  end

  def test_with_env_pins_real_binaries_against_command_local_overrides
    with_tmp_dir do |dir|
      recording_binary(dir, "git")
      recording_binary(dir, "gh")
      pwn_git = recording_binary(dir, "pwn-git")
      pwn_gh = recording_binary(dir, "pwn-gh")

      with_env("PATH" => [ dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          _out, git_err, git_status = Open3.capture3(
            { "HIVE_BABYSITTER_REAL_GIT" => pwn_git },
            "git",
            "status",
            "--short"
          )
          _out, gh_err, gh_status = Open3.capture3(
            { "HIVE_BABYSITTER_REAL_GH" => pwn_gh },
            "gh",
            "repo",
            "view",
            "owner/repo"
          )

          assert git_status.success?, git_err
          assert gh_status.success?, gh_err
        end
      end

      real_invocations = File.read(File.join(dir, "real.log"))
      assert_includes real_invocations,
                      "git -c core.fsmonitor=false -c core.askPass= -c log.showSignature=false " \
                      "-c gpg.program=false -c gpg.openpgp.program=false -c gpg.x509.program=false " \
                      "-c gpg.ssh.program=false --no-pager status --short"
      assert_includes real_invocations, "gh repo view owner/repo"
      refute_includes real_invocations, "pwn-git"
      refute_includes real_invocations, "pwn-gh"
    end
  end

  def test_with_env_canonicalizes_relative_path_real_binaries_before_agent_cwd_changes
    with_tmp_dir do |dir|
      parent = File.join(dir, "parent")
      worktree = File.join(dir, "worktree")
      parent_bin = File.join(parent, "bin")
      worktree_bin = File.join(worktree, "bin")
      FileUtils.mkdir_p([ parent_bin, worktree_bin ])
      recording_binary(parent_bin, "git")
      recording_binary(parent_bin, "gh")
      pwn_git = File.join(worktree, "pwn-git-ran")
      pwn_gh = File.join(worktree, "pwn-gh-ran")
      executable_touch_binary(worktree_bin, "git", pwn_git)
      executable_touch_binary(worktree_bin, "gh", pwn_gh)

      Dir.chdir(parent) do
        with_env("PATH" => [ "bin", ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
          Hive::Babysitter::DryRunEnv.with_env(worktree) do
            Dir.chdir(worktree) do
              _out, git_err, git_status = Open3.capture3("git", "status", "--short")
              _out, gh_err, gh_status = Open3.capture3("gh", "repo", "view", "owner/repo")

              assert git_status.success?, git_err
              assert gh_status.success?, gh_err
            end
          end
        end
      end

      real_invocations = File.read(File.join(parent_bin, "real.log"))
      assert_includes real_invocations, "git -c core.fsmonitor=false"
      assert_includes real_invocations, "--no-pager status --short"
      assert_includes real_invocations, "gh repo view owner/repo"
      refute_path_exists pwn_git
      refute_path_exists pwn_gh
    end
  end

  # Companion to the real-binary canonicalization test above, but for the *interpreter*.
  # The overlay shim and the stub it hands off to are both Ruby scripts; a
  # `#!/usr/bin/env ruby` shebang resolves `ruby` from PATH at exec time. With a relative
  # PATH component and the agent chdir'd into the worktree, a worktree-controlled
  # `bin/ruby` would be picked as the interpreter and run arbitrary code — defeating the
  # canonicalized HIVE_BABYSITTER_REAL_* pins entirely. Pinning the shim shebang and the
  # stub handoff to the running Ruby's absolute path must keep that poison out.
  def test_overlay_shims_pin_ruby_interpreter_against_worktree_cwd_ruby
    with_tmp_dir do |dir|
      parent = File.join(dir, "parent")
      worktree = File.join(dir, "worktree")
      parent_bin = File.join(parent, "bin")
      worktree_bin = File.join(worktree, "bin")
      FileUtils.mkdir_p([ parent_bin, worktree_bin ])
      recording_binary(parent_bin, "git")
      recording_binary(parent_bin, "gh")
      pwn_ruby = File.join(worktree, "pwn-ruby-ran")
      executable_touch_binary(worktree_bin, "ruby", pwn_ruby)

      Dir.chdir(parent) do
        with_env("PATH" => [ "bin", ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
          Hive::Babysitter::DryRunEnv.with_env(worktree) do
            Dir.chdir(worktree) do
              _out, git_err, git_status = Open3.capture3("git", "status", "--short")
              _out, gh_err, gh_status = Open3.capture3("gh", "repo", "view", "owner/repo")

              assert git_status.success?, git_err
              assert gh_status.success?, gh_err
            end
          end
        end
      end

      refute_path_exists pwn_ruby,
                         "worktree-controlled bin/ruby interpreted a dry-run shim or its stub"
      real_invocations = File.read(File.join(parent_bin, "real.log"))
      assert_includes real_invocations, "git -c core.fsmonitor=false"
      assert_includes real_invocations, "--no-pager status --short"
      assert_includes real_invocations, "gh repo view owner/repo"
    end
  end

  def test_gh_stub_does_not_load_caller_rubylib
    with_tmp_dir do |dir|
      poison_dir = File.join(dir, "rubylib")
      FileUtils.mkdir_p(poison_dir)
      marker = File.join(dir, "rubylib-loaded")
      %w[tmpdir uri].each do |feature|
        File.write(File.join(poison_dir, "#{feature}.rb"), "File.write(#{marker.dump}, #{feature.dump})\n")
      end

      env = {
        "RUBYLIB" => poison_dir,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log")
      }

      _out, err, status = Open3.capture3(env, stub_path("gh"), "pr", "comment", "42", "--body", "hi")

      assert status.success?, err
      assert_includes err, "[dry-run] gh pr comment 42 --body hi skipped"
      refute_path_exists marker, "gh stub loaded caller-controlled Ruby before the skip gate"

      real_gh = recording_binary(dir, "real-gh")
      _out, err, status = Open3.capture3(
        env.merge("HIVE_BABYSITTER_REAL_GH" => real_gh),
        stub_path("gh"),
        "repo",
        "view",
        "owner/repo"
      )

      assert status.success?, err
      assert_includes File.read(File.join(dir, "real.log")), "real-gh repo view owner/repo"
      refute_path_exists marker, "gh stub loaded caller-controlled Ruby before passthrough"
    end
  end

  def test_overlay_shims_scrub_ruby_startup_environment_before_stub_handoff
    with_tmp_dir do |dir|
      poison_dir = File.join(dir, "poison")
      marker = File.join(dir, "rubyopt-loaded")
      FileUtils.mkdir_p(poison_dir)
      File.write(
        File.join(poison_dir, "pwn.rb"),
        "File.write(ENV.fetch(\"HIVE_RUBYOPT_MARKER\"), \"loaded\")\n"
      )
      recording_binary(dir, "git")
      recording_binary(dir, "gh")

      with_env("PATH" => [ dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          injected = {
            "RUBYOPT" => "-rpwn",
            "RUBYLIB" => poison_dir,
            "HIVE_RUBYOPT_MARKER" => marker
          }

          _out, git_err, git_status = Open3.capture3(injected, "git", "status", "--short")
          _out, gh_err, gh_status = Open3.capture3(injected, "gh", "repo", "view", "owner/repo")

          assert git_status.success?, git_err
          assert gh_status.success?, gh_err
        end
      end

      refute_path_exists marker, "RUBYOPT/RUBYLIB loaded code before the dry-run stub guarded the call"
      real_invocations = File.read(File.join(dir, "real.log"))
      assert_includes real_invocations, "git -c core.fsmonitor=false"
      assert_includes real_invocations, "--no-pager status --short"
      assert_includes real_invocations, "gh repo view owner/repo"
    end
  end

  def test_overlay_shims_unset_known_dynamic_loader_environment_before_ruby_handoff
    with_tmp_dir do |dir|
      recording_binary(dir, "git")
      recording_binary(dir, "gh")

      with_env("PATH" => [ dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          %w[git gh].each do |binary|
            launcher = File.read(File.join(dir, ".hive-babysitter-dry-run-bin", binary))
            %w[
              LD_AUDIT LD_LIBRARY_PATH LD_PRELOAD
              DYLD_FALLBACK_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
              DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH DYLD_VERSIONED_LIBRARY_PATH
            ].each do |key|
              assert_match(/\b#{key}\b/, launcher, "#{binary} launcher must unset #{key}")
            end
          end
        end
      end
    end
  end

  def test_stubs_refuse_relative_real_binary_paths
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      pwn_git = File.join(dir, "pwn-git-ran")
      pwn_gh = File.join(dir, "pwn-gh-ran")
      executable_touch_binary(bin_dir, "git", pwn_git)
      executable_touch_binary(bin_dir, "gh", pwn_gh)

      [
        [ "git", "HIVE_BABYSITTER_REAL_GIT", [ "status", "--short" ], pwn_git ],
        [ "gh", "HIVE_BABYSITTER_REAL_GH", [ "repo", "view", "owner/repo" ], pwn_gh ]
      ].each do |binary, env_name, args, pwn_path|
        env = {
          env_name => "bin/#{binary}",
          "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "#{binary}-skipped.log")
        }

        _out, err, status = Open3.capture3(env, stub_path(binary), *args, chdir: dir)

        assert_equal 127, status.exitstatus, err
        assert_includes err, "#{env_name} must be an absolute path"
        refute_path_exists pwn_path
      end
    end
  end

  def test_gh_stub_reports_missing_real_gh_without_backtrace
    with_tmp_dir do |dir|
      missing_gh = File.join(dir, "missing-gh")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => missing_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "gh-skipped.log")
      }

      _out, err, status = Open3.capture3(env, stub_path("gh"), "repo", "view", "owner/repo")

      assert_equal 127, status.exitstatus, err
      assert_includes err, "hive-babysitter dry-run: cannot exec real gh at #{missing_gh.inspect}:"
      refute_includes err, "hive-babysitter-stub-gh:"
    end
  end

  def test_with_env_isolates_gh_config_against_command_local_home
    with_tmp_dir do |dir|
      recording_binary(dir, "git")
      recording_env_binary(dir, "gh", %w[
        GH_CONFIG_DIR XDG_CONFIG_HOME HOME HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR
      ])
      parent_home = File.join(dir, "parent-home")
      evil_trusted_config = File.join(dir, "evil-trusted-gh-config")

      with_env(
        "PATH" => [ dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR),
        "GH_CONFIG_DIR" => nil,
        "XDG_CONFIG_HOME" => nil,
        "HOME" => parent_home
      ) do
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          _out, err, status = Open3.capture3(
            {
              "HOME" => File.join(dir, "evil-home"),
              "GH_CONFIG_DIR" => File.join(dir, "evil-gh-config"),
              "XDG_CONFIG_HOME" => File.join(dir, "evil-xdg-config"),
              "HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR" => evil_trusted_config
            },
            "gh",
            "repo",
            "view",
            "owner/repo"
          )

          assert status.success?, err
        end
      end

      recorded = File.read(File.join(dir, "env.log")).lines.map(&:chomp).to_h do |line|
        line.split("=", 2)
      end
      home = recorded.fetch("HOME")
      config_dir = recorded.fetch("GH_CONFIG_DIR")

      assert_equal "<unset>", recorded.fetch("XDG_CONFIG_HOME")
      assert_equal "<unset>", recorded.fetch("HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR")
      refute_equal File::NULL, home, "HOME must not be /dev/null -- gh cannot resolve config there"
      refute_equal parent_home, home, "parent HOME config must not be reused during gh passthrough"
      refute_equal File.join(dir, "evil-home"), home, "command-local HOME must not survive passthrough"
      refute_equal File.join(dir, "evil-gh-config"), config_dir,
                   "command-local GH_CONFIG_DIR must not survive passthrough"
      refute_equal evil_trusted_config, config_dir, "private trusted-config override must not survive passthrough"
      assert File.directory?(home), "HOME should point at a real directory gh can use"
      assert File.directory?(config_dir), "GH_CONFIG_DIR should point at a real directory gh can use"
      assert_empty Dir.children(config_dir),
                   "gh's config dir should start empty so no caller-controlled config is honored"
    end
  end

  def test_with_env_pins_skip_log_against_command_local_overrides
    with_tmp_dir do |dir|
      worktree = File.join(dir, "worktree")
      outside_log = File.join(dir, "outside.log")
      File.write(outside_log, "existing\n")

      Hive::Babysitter::DryRunEnv.with_env(worktree) do
        _out, git_err, git_status = Open3.capture3(
          { "HIVE_BABYSITTER_DRY_RUN_LOG" => outside_log },
          "git",
          "commit",
          "-m",
          "blocked"
        )
        _out, gh_err, gh_status = Open3.capture3(
          { "HIVE_BABYSITTER_DRY_RUN_LOG" => outside_log },
          "gh",
          "pr",
          "comment",
          "42",
          "--body",
          "blocked"
        )

        assert git_status.success?, git_err
        assert gh_status.success?, gh_err
      end

      assert_equal "existing\n", File.read(outside_log)
      skipped = File.read(File.join(worktree, ".babysitter-dry-run-skipped.log"))
      assert_includes skipped, "git commit -m blocked skipped"
      assert_includes skipped, "gh pr comment 42 --body blocked skipped"
    end
  end

  def test_stubs_refuse_symlinked_skip_log
    with_tmp_dir do |dir|
      target = File.join(dir, "target.log")
      link = File.join(dir, "skipped.log")
      File.write(target, "existing\n")
      File.symlink(target, link)
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => link }

      _out, git_err, git_status = Open3.capture3(env, stub_path("git"), "commit", "-m", "through-link")
      _out, gh_err, gh_status = Open3.capture3(env, stub_path("gh"), "pr", "comment", "42", "--body", "hi")

      assert git_status.success?, git_err
      assert gh_status.success?, gh_err
      assert_equal "existing\n", File.read(target)
      assert_includes git_err, "[dry-run] failed to write skip log #{link}:"
      assert_includes gh_err, "[dry-run] failed to write skip log #{link}:"
    end
  end

  def test_stubs_refuse_hardlinked_skip_log
    with_tmp_dir do |dir|
      target = File.join(dir, "target.log")
      link = File.join(dir, "skipped.log")
      File.write(target, "existing\n")
      File.link(target, link)
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => link }

      _out, git_err, git_status = Open3.capture3(env, stub_path("git"), "commit", "-m", "through-hardlink")
      _out, gh_err, gh_status = Open3.capture3(env, stub_path("gh"), "pr", "comment", "42", "--body", "hi")

      assert git_status.success?, git_err
      assert gh_status.success?, gh_err
      assert_equal "existing\n", File.read(target)
      assert_includes git_err, "[dry-run] failed to write skip log #{link}: dry-run skip log link count is not 1"
      assert_includes gh_err, "[dry-run] failed to write skip log #{link}: dry-run skip log link count is not 1"
    end
  end

  def test_stubs_refuse_fifo_skip_log_without_blocking
    with_tmp_dir do |dir|
      fifo = File.join(dir, "skipped.fifo")
      File.mkfifo(fifo, 0o600)
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => fifo }

      [
        [ "git", [ "commit", "-m", "through-fifo" ] ],
        [ "gh", [ "pr", "comment", "42", "--body", "hi" ] ]
      ].each do |binary, args|
        _out, err, status = capture_stub_with_timeout(env, binary, *args)

        assert status.success?, err
        assert_includes err, "[dry-run] failed to write skip log #{fifo}: dry-run skip log is not a regular file"
        assert_includes err, "[dry-run] #{binary} #{args.join(' ')} skipped"
      end
    end
  end

  def test_stubs_escape_control_characters_in_skip_log
    with_tmp_dir do |dir|
      log_path = File.join(dir, "skipped.log")
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path }

      _out, git_err, git_status = Open3.capture3(env, stub_path("git"), "commit", "-m", "line\nbreak")
      _out, gh_err, gh_status = Open3.capture3(env, stub_path("gh"), "pr", "comment", "42", "--body", "line\nbreak")

      assert git_status.success?, git_err
      assert gh_status.success?, gh_err
      assert_includes git_err, "git commit -m line\\x0Abreak skipped"
      assert_includes gh_err, "gh pr comment 42 --body line\\x0Abreak skipped"
      skipped = File.read(log_path)
      assert_includes skipped, "git commit -m line\\x0Abreak skipped"
      assert_includes skipped, "gh pr comment 42 --body line\\x0Abreak skipped"
      refute_includes skipped, "line\nbreak"
      refute_includes git_err, "line\nbreak"
      refute_includes gh_err, "line\nbreak"
    end
  end

  def test_git_stub_skips_invalid_utf8_argv_without_crashing
    with_tmp_dir do |dir|
      log_path = File.join(dir, "skipped.log")
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path }
      invalid_arg = "bad\xFF\nline".b

      _out, err, status = Open3.capture3(env, stub_path("git"), invalid_arg)

      assert status.success?, err
      expected = "git bad\xFF\\x0Aline skipped".b
      assert_includes err.b, expected
      skipped = File.binread(log_path)
      assert_includes skipped, expected
      refute_includes skipped, "bad\xFF\nline".b
    end
  end

  def test_gh_stub_skips_invalid_utf8_argv_without_crashing
    with_tmp_dir do |dir|
      log_path = File.join(dir, "skipped.log")
      env = { "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path }
      invalid_url = "https://evil.example.com/bad\xFF".b

      _out, err, status = Open3.capture3(env, stub_path("gh"), "api", invalid_url)

      assert status.success?, err
      expected = "gh api https://evil.example.com/bad\xFF skipped".b
      assert_includes err.b, expected
      refute_includes err.b, "ArgumentError"
      skipped = File.binread(log_path)
      assert_includes skipped, expected
    end
  end

  def test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands
    with_tmp_dir do |dir|
      real_gh = recording_binary(dir, "real-gh")
      real_git = recording_binary(dir, "real-git")
      log_path = File.join(dir, "skipped.log")
      @real_log = File.join(dir, "real.log")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_REAL_GIT" => real_git,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path
      }

      assert_stubbed env, "gh", "-R", "owner/repo", "pr", "ready", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "close", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "reopen", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "merge", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "lock", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "unlock", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "edit", "42", "--add-label", "ready"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "edit", "42", "--add-assignee", "@me"
      assert_stubbed env, "gh", "api", "-X", "POST", "repos/owner/repo/dispatches"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "-f", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "-F", "body=@comment.md"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--raw-field", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--field", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--input", "payload.json"
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "--input", "payload.json"
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-F", "q=@secret"
      assert_stubbed env, "gh", "workflow", "run", "release.yml"
      assert_stubbed env, "gh", "totally-new-write-command", "arg"
      assert_stubbed env, "gh", "repo", "view", "--web"
      assert_stubbed env, "gh", "pr", "view", "42", "--web"
      assert_stubbed env, "gh", "run", "view", "123", "-w"
      assert_stubbed env, "gh", "auth", "status", "--show-token"
      assert_stubbed env, "gh", "auth", "status", "-t"
      # gh (pflag) clusters boolean shorthands, so `-t` smuggled into a cluster
      # with `-a`/`--active` still reveals the token and must be skipped.
      assert_stubbed env, "gh", "auth", "status", "-at"
      assert_stubbed env, "gh", "auth", "status", "-ta"
      assert_stubbed env, "gh", "auth", "status", "-ath"
      # A host selector lets an agent redirect the authenticated status probe to an
      # arbitrary host, so every `-h`/`--hostname` form is skipped: long, glued, and
      # clustered behind boolean shorthands (where pflag consumes the rest as the value).
      assert_stubbed env, "gh", "auth", "status", "-h", "github.com"
      assert_stubbed env, "gh", "auth", "status", "-hgithub.com"
      assert_stubbed env, "gh", "auth", "status", "--hostname", "example.com"
      assert_stubbed env, "gh", "auth", "status", "--hostname=example.com"
      assert_stubbed env, "gh", "auth", "status", "-ah", "example.com"
      # Host-qualified `--repo`/`-R` redirect an allowlisted read at an agent-chosen host
      # (leading or trailing the subcommand); only the bare `OWNER/REPO` slug stays allowed.
      assert_stubbed env, "gh", "-R", "evil.example.com/owner/repo", "pr", "view", "42"
      assert_stubbed env, "gh", "--repo=evil.example.com/owner/repo", "pr", "view", "42"
      assert_stubbed env, "gh", "--repo=https://evil.example.com/owner/repo", "pr", "view", "42"
      assert_stubbed env, "gh", "pr", "view", "42", "-R", "evil.example.com/owner/repo"
      assert_stubbed env, "gh", "pr", "view", "42", "--repo", "evil.example.com/owner/repo"
      # Glued short `-R<val>` / `-R=<val>` (pflag strips the `=`) carry a host the same way
      # the separate and long forms do, so a host-qualified glued form trailing the subcommand
      # — where stripped_global_options leaves it for host_override? to catch — must skip too.
      # (Host strings are kept "w"-free so the skip is host_override?, not the external-launcher
      # `-w` heuristic.)
      assert_stubbed env, "gh", "pr", "view", "42", "-Revil.example.com/octo/repo"
      assert_stubbed env, "gh", "pr", "view", "42", "-R=evil.example.com/octo/repo"
      assert_stubbed env, "gh", "pr", "view", "42", "-Rhttps://evil.example.com/octo/repo"
      assert_stubbed env, "gh", "pr", "view", "42", "-cRevil.example.com/octo/repo"
      assert_stubbed env, "gh", "pr", "view", "42", "-cR", "evil.example.com/octo/repo"
      # `gh api`/`auth` honor `--hostname` after the subcommand too, so the gate must
      # reject command-position host overrides, not just leading globals.
      assert_stubbed env, "gh", "api", "rate_limit", "--hostname", "evil.example.com"
      assert_stubbed env, "gh", "api", "rate_limit", "--hostname=evil.example.com"
      assert_stubbed env, "gh", "api", "https://example.com"
      # `-p`/`--preview` takes a value; the api endpoint scanner must consume it so it
      # does not stop on the preview name and miss the trailing external URL. Cover the
      # separate short, glued short, and long forms.
      assert_stubbed env, "gh", "api", "-p", "shadow-cat", "https://evil.example.com"
      assert_stubbed env, "gh", "api", "-pshadow-cat", "https://evil.example.com"
      assert_stubbed env, "gh", "api", "--preview", "shadow-cat", "https://evil.example.com"
      # gh (pflag) clusters shorthands, so `-ip` is `-i -p`: the value-taking `-p` is the
      # cluster's last char and swallows the next argv as its preview value. The endpoint
      # scanner must mirror that consumption or it mistakes the preview name for the endpoint
      # and waves the trailing attacker host through.
      assert_stubbed env, "gh", "api", "-ip", "shadow-cat", "https://evil.example.com"
      # The read/write classifier has the same cluster blind spot: a value-taking shorthand
      # hidden behind a boolean (`-iX POST` = `-i -X POST`, `-if body=hi` = `-i -f body=hi`)
      # must still be seen as a method/payload so the mutating call is skipped, not exec'd.
      assert_stubbed env, "gh", "api", "-iX", "POST", "repos/owner/repo/dispatches"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "-if", "body=hi"
      # An scp-style `git@host:owner/repo` carries a host through a single-slash
      # `--repo`/`-R` value, so the colon (not just `://` or the slash count) must
      # disqualify it.
      assert_stubbed env, "gh", "-R", "git@evil.example.com:owner/repo", "pr", "view", "42"
      # Read-only subcommands also accept the target as a positional operand — a
      # host-qualified `HOST/OWNER/REPO` slug, a full URL, or an scp form — which the
      # `-R`/`--repo`/`--hostname` flag gate never inspects. Each must skip.
      assert_stubbed env, "gh", "repo", "view", "evil.example.com/owner/repo"
      assert_stubbed env, "gh", "repo", "view", "https://evil.example.com/owner/repo"
      assert_stubbed env, "gh", "repo", "view", "git@evil.example.com:owner/repo"
      assert_stubbed env, "gh", "pr", "view", "https://evil.example.com/owner/repo/pull/42"
      assert_stubbed env, "gh", "pr", "diff", "https://evil.example.com/owner/repo/pull/42"
      assert_stubbed env, "gh", "pr", "checks", "https://evil.example.com/owner/repo/pull/42"
      # The bare `OWNER/REPO` slug stays on the default host, so a glued short `-R<slug>`
      # must still reach real gh — the new glued branch must not over-block the safe form.
      # Leading: stripped_global_options shifts off the glued global; trailing: host_override?
      # clears it directly. (`octo/repo` is "w"-free so the external-launcher `-w` heuristic
      # stays out of the trailing case.)
      assert_passes env, "gh", "-Rowner/repo", "pr", "view", "42"
      assert_passes env, "gh", "pr", "view", "42", "-Rocto/repo"
      assert_passes env, "gh", "pr", "view", "42", "-cRocto/repo"
      assert_passes env, "gh", "pr", "view", "42", "-cR", "octo/repo"
      assert_passes env, "gh", "--repo=owner/repo", "pr", "view", "42"
      assert_passes env, "gh", "auth", "status"
      assert_passes env, "gh", "auth", "status", "-a"
      assert_passes env, "gh", "api", "repos/owner/repo"
      assert_passes env, "gh", "api", "graphql"
      # A `-p`/`--preview` read against a default-host endpoint must still reach real gh:
      # consuming the preview value must not over-block the safe, host-free form.
      assert_passes env, "gh", "api", "-p", "shadow-cat", "repos/owner/repo"
      assert_passes env, "gh", "api", "--preview", "shadow-cat", "repos/owner/repo"
      # The clustered `-ip` preview read against a default-host endpoint must also pass:
      # mirroring pflag's cluster consumption must not over-block the safe form.
      assert_passes env, "gh", "api", "-ip", "shadow-cat", "repos/owner/repo"
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-f", "state=open"
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-F", "state=open"
      # The safe positional forms must still reach real gh, so the new positional
      # gate does not over-block: a bare `OWNER/REPO` slug (one slash) on `repo view`,
      # a numeric operand on `pr view`, and a slash-bearing branch ref the pr-URL rule
      # must not mistake for a host (only a `scheme://` URL names a host for pr reads).
      assert_passes env, "gh", "repo", "view", "owner/repo"
      assert_passes env, "gh", "pr", "view", "42"
      assert_passes env, "gh", "pr", "view", "feature/topic/branch"

      # Glued/inline @file payload forms must be caught on explicit GET too,
      # not just the space-separated `-F q=@secret` form: each branch
      # reimplements the @-prefix check, so they need independent coverage.
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-Fq=@secret"
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-F=q=@secret"
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "--field=q=@secret"
      assert_stubbed env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "--input=payload.json"
      # Glued/inline forms with scalar values stay read-only on explicit GET.
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-Fstate=open"
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "--field=state=open"
      # A trailing `-F` with no argument must not crash the stub; with no
      # payload value it stays read-only on explicit GET.
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-F"

      assert_stubbed env, "git", "-C", dir, "push", "origin", "HEAD:feature"
      assert_stubbed env, "git", "commit", "-m", "dry run must not commit"
      assert_stubbed env, "git", "merge", "feature"
      assert_stubbed env, "git", "branch", "--contains", "HEAD", "-D", "feature"
      assert_stubbed env, "git", "branch", "-D", "feature", "--contains", "HEAD"
      assert_stubbed env, "git", "branch", "--show-current", "-m", "old", "new"
      assert_stubbed env, "git", "branch", "--contains=HEAD", "--set-upstream-to", "origin/main", "feature"
      assert_stubbed env, "git", "config", "user.name", "newvalue", "--get"
      assert_stubbed env, "git", "config", "user.email", "newvalue", "--get-all"
      assert_stubbed env, "git", "config", "commit.gpgsign", "false", "--list"
      assert_stubbed env, "git", "remote", "set-url", "origin", "git@example.com:owner/repo.git"
      assert_stubbed env, "git", "remote", "add", "upstream", "git@example.com:owner/upstream.git"
      assert_stubbed env, "git", "remote", "remove", "upstream"
      # Mutating `remote` subcommands beyond set-url/add/remove must skip too.
      assert_stubbed env, "git", "remote", "rename", "origin", "upstream"
      assert_stubbed env, "git", "remote", "prune", "origin"
      assert_stubbed env, "git", "remote", "update"
      assert_stubbed env, "git", "remote", "set-head", "origin", "main"
      assert_stubbed env, "git", "remote", "set-branches", "origin", "main"
      assert_stubbed env, "git", "-c", "diff.external=touch /tmp/hive-dryrun-pwn", "diff"
      assert_stubbed env, "git", "-c", "core.fsmonitor=touch /tmp/hive-fsmonitor-pwn", "status"
      assert_stubbed env, "git", "--config-env=core.pager=HIVE_TEST_PAGER", "log", "--oneline"
      assert_stubbed env, "git", "--paginate", "log", "--oneline"
      assert_stubbed env, "git", "grep", "--open-files-in-pager=touch /tmp/hive-pager-pwn", "needle"
      assert_stubbed env, "git", "grep", "-e", "--", "--open-files-in-pager=/tmp/hive-pager-sep-pwn"
      assert_stubbed env, "git", "grep", "-e", "--", "--textconv"
      # On `git grep`, `-O` is the short form of `--open-files-in-pager`; both glued and
      # separate forms run an attacker-controlled pager command and must be rejected. (On
      # diff/log/show `-O` is the read-only `--output-ordering` — see the passthrough cases.)
      assert_stubbed env, "git", "grep", "-Otouch /tmp/hive-pager-short-pwn", "needle"
      assert_stubbed env, "git", "grep", "-nOtouch /tmp/hive-pager-cluster-pwn", "needle"
      assert_stubbed env, "git", "grep", "-O", "touch /tmp/hive-pager-sep-pwn", "needle"
      # git resolves any unambiguous long-option prefix, so abbreviated spellings of
      # `--open-files-in-pager` (down to the shortest unique `--op`) still launch the pager
      # and must be rejected, with or without a glued `=<cmd>`.
      assert_stubbed env, "git", "grep", "--open=touch /tmp/hive-pager-abbrev-pwn", "needle"
      assert_stubbed env, "git", "grep", "--open-files=touch /tmp/hive-pager-abbrev2-pwn", "needle"
      assert_stubbed env, "git", "grep", "--op=touch /tmp/hive-pager-abbrev3-pwn", "needle"
      # Same-class arbitrary-exec config keys are rejected by the allowlist (reject all
      # global config overrides), not by a denylist that has to enumerate each one.
      assert_stubbed env, "git", "-c", "diff.x.textconv=touch /tmp/hive-textconv-pwn", "diff"
      assert_stubbed env, "git", "-c", "diff.x.command=touch /tmp/hive-diffcmd-pwn", "diff"
      assert_stubbed env, "git", "-c", "filter.x.clean=touch /tmp/hive-filter-pwn", "diff"
      assert_stubbed env, "git", "-c", "gpg.ssh.program=touch /tmp/hive-gpg-pwn", "log", "--show-signature"
      assert_stubbed env, "git", "-cdiff.x.textconv=touch /tmp/hive-glued-pwn", "diff"
      assert_stubbed env, "git", "--config-env", "core.pager=HIVE_TEST_PAGER", "log"
      # Arbitrary file-write options defeat the no-mutation boundary on allowed reads.
      assert_stubbed env, "git", "diff", "--output=/tmp/hive-output-pwn"
      assert_stubbed env, "git", "log", "-p", "--output", "/tmp/hive-output-sep-pwn"
      # A separate-word `--pretty` / `--format` on log/show/rev-list is stuck-only: git does NOT
      # consume the next token as its format value (a bare `--pretty` uses the default format),
      # so the argv scan must keep scanning the following token. Otherwise a trailing file-writing
      # `--output` rides past the write guard and the stub execs real git, creating the file.
      assert_stubbed env, "git", "log", "--pretty", "--output=/tmp/hive-pretty-output-pwn"
      assert_stubbed env, "git", "show", "--pretty", "--output", "/tmp/hive-show-pretty-output-sep-pwn"
      assert_stubbed env, "git", "rev-list", "--format", "--output=/tmp/hive-revlist-format-output-pwn", "HEAD"
      assert_stubbed env, "git", "diff", "-o", "/tmp/hive-output-short-pwn"
      assert_stubbed env, "git", "diff", "-o/tmp/hive-output-glued-pwn"
      assert_stubbed env, "git", "diff", "--ext-diff"
      # `--textconv` runs the repo-local `diff.<driver>.textconv` command — an exec seam. The
      # spelled-out flag must skip, and so must every prefix git accepts as the long option
      # (`--text`, `--textc`, ...), e.g. `git cat-file --text` / `git grep --textc`.
      assert_stubbed env, "git", "diff", "--textconv"
      assert_stubbed env, "git", "cat-file", "--text", "HEAD:README.md"
      assert_stubbed env, "git", "grep", "--textc", "needle"
      # `git cat-file --filters` is an allowlisted read, but `--filters` runs the repo-local
      # `filter.<driver>.smudge` command — an exec seam the diff/log/show `--no-textconv`
      # hardening never covers, so it must skip.
      assert_stubbed env, "git", "cat-file", "--filters", "HEAD:README.md"
      # The read/write boundary for ls-files: `-o` / `--others` is a read (allowed below), but
      # the file-writing `--output` long form must still skip — narrowing the guard must not
      # re-allow the write form.
      assert_stubbed env, "git", "ls-files", "--output", "/tmp/hive-lsfiles-output-pwn"
      # The env-var config path bypasses every argv guard above: GIT_EXEC_PATH redirects git to
      # attacker-controlled helper binaries, GIT_EXTERNAL_DIFF / GIT_SSH_COMMAND name a command
      # git execs directly, and GIT_CONFIG_COUNT + GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n inject the
      # same exec-capable keys as `-c`. An otherwise-allowlisted read like `git diff` must skip,
      # fail-closed, when they are set.
      assert_stubbed env.merge("GIT_EXEC_PATH" => "/tmp/hive-git-exec-path-pwn"), "git", "status"
      assert_stubbed env.merge("GIT_EXTERNAL_DIFF" => "touch /tmp/hive-extdiff-pwn"), "git", "diff"
      assert_stubbed env.merge("GIT_SSH_COMMAND" => "touch /tmp/hive-ssh-pwn"), "git", "ls-files"
      assert_stubbed env.merge(
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "diff.external",
        "GIT_CONFIG_VALUE_0" => "touch /tmp/hive-envconfig-pwn"
      ), "git", "diff"
      # GIT_CONFIG_PARAMETERS is git's older one-shot config channel; it carries the same
      # exec-capable keys (diff.external, core.fsmonitor, …) as `-c`, so it must skip too.
      assert_stubbed env.merge(
        "GIT_CONFIG_PARAMETERS" => "'diff.external=touch /tmp/hive-cfgparams-pwn'"
      ), "git", "diff"
      # GIT_SSH / GIT_PROXY_COMMAND are the older exec-capable siblings of GIT_SSH_COMMAND,
      # and askpass helpers are credential-prompt programs git/ssh can exec during remote reads.
      assert_stubbed env.merge("GIT_SSH" => "touch /tmp/hive-gitssh-pwn"), "git", "remote", "show", "origin"
      assert_stubbed env.merge("GIT_ASKPASS" => "touch /tmp/hive-askpass-pwn"), "git", "remote", "show", "origin"
      assert_stubbed env.merge("SSH_ASKPASS" => "touch /tmp/hive-ssh-askpass-pwn"), "git", "remote", "show", "origin"
      assert_stubbed env.merge("GIT_PROXY_COMMAND" => "touch /tmp/hive-proxy-pwn"), "git", "status"
      # GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM repoint config at an attacker-written file that
      # can re-enable diff.external / core.pager / aliases, so a set value must skip.
      assert_stubbed env.merge("GIT_CONFIG_GLOBAL" => "/tmp/hive-evil.gitconfig"), "git", "status"
      assert_stubbed env.merge("GIT_CONFIG_SYSTEM" => "/tmp/hive-evil-system.gitconfig"), "git", "status"
      # Default-deny on a malformed GIT_CONFIG_COUNT: a non-numeric value (which `.to_i` reads
      # as 0/allowed) must be rejected rather than trusted to git's own parsing.
      assert_stubbed env.merge("GIT_CONFIG_COUNT" => "not-a-number"), "git", "status"
      assert_stubbed env, "git", "unknown-write-command"
      assert_passes env, "git", "-C", dir, "status", "--short"
      assert_passes env, "git", "config", "--get", "remote.origin.url"
      assert_passes env, "git", "config", "--get-all", "remote.origin.fetch"
      assert_passes env, "git", "config", "--list"
      # Reads with a type/format modifier before --get are still read-only;
      # auto_commit runs `git config --bool --get commit.gpgsign`.
      assert_passes env, "git", "config", "--bool", "--get", "commit.gpgsign"
      assert_passes env, "git", "config", "--int", "--get", "core.abbrev"
      assert_passes env, "git", "config", "--path", "--get", "core.excludesfile"
      assert_passes env, "git", "config", "-z", "--get-all", "remote.origin.fetch"
      assert_passes env, "git", "config", "--type=bool", "--get", "commit.gpgsign"
      assert_passes env, "git", "branch"
      assert_passes env, "git", "branch", "--show-current"
      assert_passes env, "git", "branch", "--contains"
      assert_passes env, "git", "branch", "--contains", "HEAD"
      assert_passes env, "git", "branch", "--contains=HEAD"
      assert_passes env, "git", "remote"
      assert_passes env, "git", "remote", "-v"
      assert_passes env, "git", "remote", "show", "-n", "origin"
      assert_passes env, "git", "remote", "get-url", "--push", "origin"
      assert_passes env, "git", "remote", "get-url", "--all", "origin"
      # Read-only subcommand `-p` must pass through; it is not the global `--paginate`.
      assert_passes env, "git", "log", "-p"
      assert_passes env, "git", "show", "-p"
      assert_passes env, "git", "diff", "-p"
      assert_passes env, "git", "grep", "-p", "needle"
      # `git grep -o` / `--only-matching` is a read-only match filter, not a file-write; the
      # output-file guard is scoped past grep so it stays allowed.
      assert_passes env, "git", "grep", "-o", "needle"
      assert_passes env, "git", "grep", "--only-matching", "needle"
      # A value-taking short option consumes the rest of its cluster as the operand, so an
      # uppercase `O` inside that value (here the pattern `TODO`) is not the `-O` pager flag.
      # These read-only searches must reach real git, not be skipped as a false positive.
      assert_passes env, "git", "grep", "-eTODO", "--", "."
      assert_passes env, "git", "grep", "-fNEEDLEFILE.txt"
      # `git ls-files -o` / `--others` lists untracked files — a read; the output-file guard
      # must not over-block it.
      assert_passes env, "git", "ls-files", "-o"
      assert_passes env, "git", "ls-files", "--others"
      # On diff/log/show, `-O<orderfile>` is `--output-ordering` (reads an orderfile), not the
      # grep pager flag — a cross-subcommand read that must pass through (glued and separate).
      assert_passes env, "git", "diff", "-O/tmp/hive-orderfile"
      assert_passes env, "git", "log", "-O", "/tmp/hive-orderfile"
      # After `--`, `-o` is a literal pathspec (a file named `-o`), not the output flag, so
      # the file-write guard must not over-block the read.
      assert_passes env, "git", "log", "--", "-o"
      # Empty / zero env-config vars inject nothing, so the env guard must not over-block the
      # read: GIT_CONFIG_COUNT=0 resolves to no config, and an unset external-diff is harmless.
      assert_passes env.merge("GIT_CONFIG_COUNT" => "0", "GIT_EXTERNAL_DIFF" => ""), "git", "status", "--short"

      skipped = File.read(log_path)
      assert_includes skipped, "gh -R owner/repo pr ready 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr close 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr reopen 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr merge 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr lock 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr unlock 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr edit 42 --add-label ready skipped"
      assert_includes skipped, "gh --repo=owner/repo pr edit 42 --add-assignee @me skipped"
      assert_includes skipped, "gh api -X POST repos/owner/repo/dispatches skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments -f body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments -F body=@comment.md skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --raw-field body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --field body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --input payload.json skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues --input payload.json skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues -F q=@secret skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues -Fq=@secret skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues -F=q=@secret skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues --field=q=@secret skipped"
      assert_includes skipped, "gh api --method GET repos/owner/repo/issues --input=payload.json skipped"
      assert_includes skipped, "gh workflow run release.yml skipped"
      assert_includes skipped, "gh repo view --web skipped"
      assert_includes skipped, "gh pr view 42 --web skipped"
      assert_includes skipped, "gh run view 123 -w skipped"
      assert_includes skipped, "gh auth status --show-token skipped"
      assert_includes skipped, "gh auth status -t skipped"
      assert_includes skipped, "gh auth status -at skipped"
      assert_includes skipped, "gh auth status -ta skipped"
      assert_includes skipped, "gh auth status -ath skipped"
      assert_includes skipped, "gh auth status -h github.com skipped"
      assert_includes skipped, "gh auth status -hgithub.com skipped"
      assert_includes skipped, "gh auth status --hostname example.com skipped"
      assert_includes skipped, "gh auth status --hostname=example.com skipped"
      assert_includes skipped, "gh auth status -ah example.com skipped"
      assert_includes skipped, "gh -R evil.example.com/owner/repo pr view 42 skipped"
      assert_includes skipped, "gh --repo=evil.example.com/owner/repo pr view 42 skipped"
      assert_includes skipped, "gh --repo=https://evil.example.com/owner/repo pr view 42 skipped"
      assert_includes skipped, "gh pr view 42 -R evil.example.com/owner/repo skipped"
      assert_includes skipped, "gh pr view 42 --repo evil.example.com/owner/repo skipped"
      assert_includes skipped, "gh pr view 42 -Revil.example.com/octo/repo skipped"
      assert_includes skipped, "gh pr view 42 -R=evil.example.com/octo/repo skipped"
      assert_includes skipped, "gh pr view 42 -Rhttps://evil.example.com/octo/repo skipped"
      assert_includes skipped, "gh pr view 42 -cRevil.example.com/octo/repo skipped"
      assert_includes skipped, "gh pr view 42 -cR evil.example.com/octo/repo skipped"
      assert_includes skipped, "gh api -ip shadow-cat https://evil.example.com skipped"
      assert_includes skipped, "gh api -iX POST repos/owner/repo/dispatches skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments -if body=hi skipped"
      assert_includes skipped, "gh api rate_limit --hostname evil.example.com skipped"
      assert_includes skipped, "gh api rate_limit --hostname=evil.example.com skipped"
      assert_includes skipped, "gh api https://example.com skipped"
      assert_includes skipped, "gh -R git@evil.example.com:owner/repo pr view 42 skipped"
      assert_includes skipped, "gh repo view evil.example.com/owner/repo skipped"
      assert_includes skipped, "gh repo view https://evil.example.com/owner/repo skipped"
      assert_includes skipped, "gh repo view git@evil.example.com:owner/repo skipped"
      assert_includes skipped, "gh pr view https://evil.example.com/owner/repo/pull/42 skipped"
      assert_includes skipped, "gh pr diff https://evil.example.com/owner/repo/pull/42 skipped"
      assert_includes skipped, "gh pr checks https://evil.example.com/owner/repo/pull/42 skipped"
      assert_includes skipped, "git -C #{dir} push origin HEAD:feature skipped"
      assert_includes skipped, "git commit -m dry run must not commit skipped"
      assert_includes skipped, "git merge feature skipped"
      assert_includes skipped, "git branch --contains HEAD -D feature skipped"
      assert_includes skipped, "git branch -D feature --contains HEAD skipped"
      assert_includes skipped, "git branch --show-current -m old new skipped"
      assert_includes skipped, "git branch --contains=HEAD --set-upstream-to origin/main feature skipped"
      assert_includes skipped, "git config user.name newvalue --get skipped"
      assert_includes skipped, "git config user.email newvalue --get-all skipped"
      assert_includes skipped, "git config commit.gpgsign false --list skipped"
      assert_includes skipped, "git remote set-url origin git@example.com:owner/repo.git skipped"
      assert_includes skipped, "git remote add upstream git@example.com:owner/upstream.git skipped"
      assert_includes skipped, "git remote remove upstream skipped"
      assert_includes skipped, "git -c diff.external=touch /tmp/hive-dryrun-pwn diff skipped"
      assert_includes skipped, "git -c core.fsmonitor=touch /tmp/hive-fsmonitor-pwn status skipped"
      assert_includes skipped, "git --config-env=core.pager=HIVE_TEST_PAGER log --oneline skipped"
      assert_includes skipped, "git --paginate log --oneline skipped"
      assert_includes skipped, "git grep --open-files-in-pager=touch /tmp/hive-pager-pwn needle skipped"
      assert_includes skipped, "git grep -e -- --open-files-in-pager=/tmp/hive-pager-sep-pwn skipped"
      assert_includes skipped, "git grep -e -- --textconv skipped"
      assert_includes skipped, "git remote show origin skipped"

      real_invocations = File.read(File.join(dir, "real.log"))
      assert_includes real_invocations, "real-gh --repo=owner/repo pr view 42"
      assert_includes real_invocations, "real-gh auth status"
      assert_includes real_invocations, "real-gh api repos/owner/repo"
      assert_includes real_invocations, "real-gh api -ip shadow-cat repos/owner/repo"
      assert_includes real_invocations, "real-gh api graphql"
      assert_includes real_invocations, "real-gh repo view owner/repo"
      assert_includes real_invocations, "real-gh pr view 42"
      assert_includes real_invocations, "real-gh pr view feature/topic/branch"
      assert_includes real_invocations, "real-gh api --method GET repos/owner/repo/issues -f state=open"
      assert_includes real_invocations, "real-gh api --method GET repos/owner/repo/issues -F state=open"
      assert_includes real_invocations, expected_real_invocation("git", "-C", dir, "status", "--short")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--get", "remote.origin.url")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--get-all", "remote.origin.fetch")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--list")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--bool", "--get", "commit.gpgsign")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--int", "--get", "core.abbrev")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--path", "--get", "core.excludesfile")
      assert_includes real_invocations, expected_real_invocation("git", "config", "-z", "--get-all", "remote.origin.fetch")
      assert_includes real_invocations, expected_real_invocation("git", "config", "--type=bool", "--get", "commit.gpgsign")
      assert_includes real_invocations, expected_real_invocation("git", "branch")
      assert_includes real_invocations, expected_real_invocation("git", "branch", "--show-current")
      assert_includes real_invocations, expected_real_invocation("git", "branch", "--contains")
      assert_includes real_invocations, expected_real_invocation("git", "branch", "--contains", "HEAD")
      assert_includes real_invocations, expected_real_invocation("git", "branch", "--contains=HEAD")
      assert_includes real_invocations, expected_real_invocation("git", "remote")
      assert_includes real_invocations, expected_real_invocation("git", "remote", "-v")
      assert_includes real_invocations, expected_real_invocation("git", "remote", "show", "-n", "origin")
      assert_includes real_invocations, expected_real_invocation("git", "remote", "get-url", "--push", "origin")
      assert_includes real_invocations, expected_real_invocation("git", "remote", "get-url", "--all", "origin")
      # The PR's headline regression target: `-p` must reach real git as the subcommand flag,
      # not be misclassified as the global `--paginate` and skipped.
      assert_includes real_invocations, expected_real_invocation("git", "log", "-p")
      assert_includes real_invocations, expected_real_invocation("git", "show", "-p")
      assert_includes real_invocations, expected_real_invocation("git", "diff", "-p")
      assert_includes real_invocations, expected_real_invocation("git", "grep", "-p", "needle")
      assert_includes real_invocations, expected_real_invocation("git", "grep", "-o", "needle")
      assert_includes real_invocations, expected_real_invocation("git", "log", "--", "-o")
    end
  end


  def test_gh_stub_scrubs_exec_influencing_environment_before_passthrough
    with_tmp_dir do |dir|
      env_keys = %w[
        GH_PAGER PAGER GH_BROWSER BROWSER GH_EDITOR GIT_EDITOR VISUAL EDITOR GH_FORCE_TTY
        GH_CONFIG_DIR XDG_CONFIG_HOME HOME
        GIT_ASKPASS GIT_EXEC_PATH GIT_EXTERNAL_DIFF GIT_PAGER GIT_PROXY_COMMAND GIT_SSH GIT_SSH_COMMAND
        GIT_SSH_VARIANT SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
        GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TRACE GIT_TRACE_PACKET GIT_TRACE2_EVENT
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
        SSL_CERT_FILE SSL_CERT_DIR ssl_cert_file ssl_cert_dir
      ]
      real_gh = recording_env_binary(dir, "real-gh", env_keys)
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "GH_PAGER" => "touch pager-pwned",
        "PAGER" => "touch pager-pwned",
        "GH_BROWSER" => "touch browser-pwned",
        "BROWSER" => "touch browser-pwned",
        "GH_EDITOR" => "touch editor-pwned",
        "GIT_EDITOR" => "touch editor-pwned",
        "VISUAL" => "touch editor-pwned",
        "EDITOR" => "touch editor-pwned",
        "GH_FORCE_TTY" => "80",
        "GH_CONFIG_DIR" => File.join(dir, "evil-gh-config"),
        "XDG_CONFIG_HOME" => File.join(dir, "evil-xdg-config"),
        "HOME" => File.join(dir, "evil-home"),
        "GIT_ASKPASS" => "touch git-askpass-pwned",
        "GIT_EXEC_PATH" => File.join(dir, "evil-git-exec-path"),
        "GIT_EXTERNAL_DIFF" => "touch git-ext-diff-pwned",
        "GIT_PAGER" => "touch git-pager-pwned",
        "GIT_PROXY_COMMAND" => "touch git-proxy-pwned",
        "GIT_SSH" => "touch git-ssh-pwned",
        "GIT_SSH_COMMAND" => "touch git-ssh-command-pwned",
        "GIT_SSH_VARIANT" => "ssh",
        "SSH_ASKPASS" => "touch ssh-askpass-pwned",
        "GIT_CONFIG_PARAMETERS" => "'diff.external=touch git-config-parameters-pwned'",
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "diff.external",
        "GIT_CONFIG_VALUE_0" => "touch git-env-config-pwned",
        "GIT_CONFIG_GLOBAL" => File.join(dir, "evil-global.gitconfig"),
        "GIT_CONFIG_SYSTEM" => File.join(dir, "evil-system.gitconfig"),
        "GIT_TRACE" => File.join(dir, "git-trace.log"),
        "GIT_TRACE_PACKET" => File.join(dir, "git-trace-packet.log"),
        "GIT_TRACE2_EVENT" => File.join(dir, "git-trace2-event.log"),
        "HTTP_PROXY" => "http://127.0.0.1:8080",
        "HTTPS_PROXY" => "http://127.0.0.1:8443",
        "ALL_PROXY" => "socks5://127.0.0.1:1080",
        "NO_PROXY" => "",
        "http_proxy" => "http://127.0.0.1:8081",
        "https_proxy" => "http://127.0.0.1:8444",
        "all_proxy" => "socks5://127.0.0.1:1081",
        "no_proxy" => "",
        "SSL_CERT_FILE" => File.join(dir, "agent-ca.pem"),
        "SSL_CERT_DIR" => File.join(dir, "agent-ca-dir"),
        "ssl_cert_file" => File.join(dir, "agent-ca-lower.pem"),
        "ssl_cert_dir" => File.join(dir, "agent-ca-dir-lower")
      }

      _out, err, status = Open3.capture3(env, stub_path("gh"), "repo", "view", "owner/repo")

      assert status.success?, err
      recorded = File.read(File.join(dir, "env.log")).lines.map(&:chomp).to_h do |line|
        line.split("=", 2)
      end

      (env_keys - %w[HOME GH_CONFIG_DIR]).each do |key|
        assert_equal "<unset>", recorded.fetch(key), "#{key} should be scrubbed before gh passthrough"
      end

      # gh has no GIT_CONFIG_GLOBAL=/dev/null-style "no config" sentinel: HOME=/dev/null leaves it
      # resolving /dev/null/.config/gh (ENOTDIR). The stub instead points HOME and GH_CONFIG_DIR at
      # a fresh, empty, writable directory so gh reads no attacker config yet can still write state.
      home = recorded.fetch("HOME")
      config_dir = recorded.fetch("GH_CONFIG_DIR")
      refute_equal File::NULL, home, "HOME must not be /dev/null -- gh cannot resolve a config dir under it"
      refute_equal File.join(dir, "evil-home"), home, "caller-supplied HOME must not survive passthrough"
      refute_equal File.join(dir, "evil-gh-config"), config_dir,
                   "caller-supplied GH_CONFIG_DIR must not survive passthrough"
      assert File.directory?(home), "HOME should point at a real directory gh can use"
      assert File.directory?(config_dir), "GH_CONFIG_DIR should point at a real directory gh can use"
      assert_empty Dir.children(config_dir),
                   "gh's config dir should start empty so no attacker-controlled config is honored"
    end
  end

  def test_stubs_scrub_all_dynamic_loader_environment_before_passthrough
    with_tmp_dir do |dir|
      loader_env = {
        "LD_AUDIT" => "",
        "LD_LIBRARY_PATH" => dir,
        "LD_PRELOAD" => "",
        "LD_HIVE_TEST" => "agent-ld",
        "DYLD_INSERT_LIBRARIES" => "",
        "DYLD_LIBRARY_PATH" => dir,
        "DYLD_HIVE_TEST" => "agent-dyld"
      }

      {
        "git" => [ "status", "--short" ],
        "gh" => [ "repo", "view", "owner/repo" ]
      }.each do |binary, args|
        FileUtils.rm_f(File.join(dir, "env.log"))
        real = recording_env_binary(dir, "real-#{binary}", loader_env.keys)
        env = loader_env.merge(
          "HIVE_BABYSITTER_REAL_#{binary.upcase}" => real,
          "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log")
        )

        _out, err, status = Open3.capture3(env, stub_path(binary), *args)

        assert status.success?, err
        expected = loader_env.keys.map { |key| "#{key}=<unset>\n" }.join
        assert_equal expected, File.read(File.join(dir, "env.log"))
      end
    end
  end

  def test_gh_stub_scrubs_git_trace_env_before_allowlisted_pr_view_passthrough
    with_tmp_git_repo do |dir|
      trace_path = File.join(dir, "gh-git-trace.log")
      marker_path = File.join(dir, "real-gh-ran")
      real_gh = File.join(dir, "real-gh")
      File.write(real_gh, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{marker_path.dump}, ARGV.join(" "))
        ok = system("git", "-C", #{dir.dump}, "status", "--short", out: File::NULL, err: File::NULL)
        exit(ok ? 0 : 1)
      RUBY
      FileUtils.chmod("+x", real_gh)

      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "GIT_TRACE" => trace_path
      }

      _out, err, status = Open3.capture3(env, stub_path("gh"), "pr", "view", "42")

      assert status.success?, err
      assert_equal "pr view 42", File.read(marker_path)
      refute_path_exists File.join(dir, "skipped.log")
      refute_path_exists trace_path
    end
  end

  def test_gh_stub_scrubs_host_repo_and_enterprise_token_environment_before_passthrough
    with_tmp_dir do |dir|
      # The argv gate inspects argv only; gh also reads the target host/repo and enterprise
      # credentials from the environment, so an agent could set GH_HOST=evil (with a matching
      # GH_ENTERPRISE_TOKEN) to redirect an otherwise-allowlisted read. The stub must scrub
      # these before exec so the real gh sees them unset.
      env_keys = %w[GH_HOST GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN]
      real_gh = recording_env_binary(dir, "real-gh", env_keys)
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "GH_HOST" => "evil.example.com",
        "GH_REPO" => "evil.example.com/owner/repo",
        "GH_ENTERPRISE_TOKEN" => "enterprise-secret",
        "GITHUB_ENTERPRISE_TOKEN" => "github-enterprise-secret"
      }

      _out, err, status = Open3.capture3(env, stub_path("gh"), "api", "rate_limit")

      assert status.success?, err
      assert_equal env_keys.map { |key| "#{key}=<unset>" }.join("\n") + "\n", File.read(File.join(dir, "env.log"))
    end
  end

  def test_gh_api_cache_flags_are_skipped_without_writing_cache
    with_tmp_dir do |dir|
      cache_dir = File.join(dir, "cache")
      log_path = File.join(dir, "skipped.log")
      real_gh = cache_writing_gh_binary(dir, "real-gh")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path,
        "XDG_CACHE_HOME" => cache_dir
      }

      assert_stubbed env, "gh", "api", "--method", "GET", "--cache", "1h", "rate_limit"
      assert_stubbed env, "gh", "api", "--method=GET", "--cache=1h", "rate_limit"

      refute_path_exists File.join(cache_dir, "gh")
      skipped = File.read(log_path)
      assert_includes skipped, "gh api --method GET --cache 1h rate_limit skipped"
      assert_includes skipped, "gh api --method=GET --cache=1h rate_limit skipped"
    end
  end

  def test_gh_stub_skips_browser_launch_flags
    with_tmp_dir do |dir|
      real_gh = recording_binary(dir, "real-gh")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "GH_BROWSER" => "touch browser-pwned",
        "BROWSER" => "touch browser-pwned"
      }

      assert_stubbed env, "gh", "repo", "view", "owner/repo", "--web"
      assert_stubbed env, "gh", "repo", "view", "owner/repo", "--web=true"
      assert_stubbed env, "gh", "pr", "view", "42", "--web"
      assert_stubbed env, "gh", "pr", "checks", "42", "-w"
      assert_stubbed env, "gh", "pr", "diff", "42", "-w"
      assert_stubbed env, "gh", "pr", "list", "-w"
      assert_stubbed env, "gh", "repo", "view", "owner/repo", "-w"
      assert_stubbed env, "gh", "pr", "checks", "42", "-w"
      assert_stubbed env, "gh", "pr", "diff", "42", "-w"
      assert_stubbed env, "gh", "pr", "list", "-w"
      assert_stubbed env, "gh", "pr", "view", "42", "-cw"

      refute File.exist?(File.join(dir, "real.log"))
    end
  end

  def test_gh_stub_skips_leading_hostname_overrides
    with_tmp_dir do |dir|
      real_gh = recording_binary(dir, "real-gh")
      log_path = File.join(dir, "skipped.log")
      @real_log = File.join(dir, "real.log")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path
      }

      assert_stubbed env, "gh", "--hostname", "example.com", "api", "rate_limit"
      assert_stubbed env, "gh", "--hostname=example.com", "api", "rate_limit"
      assert_stubbed env, "gh", "--hostname", "example.com", "auth", "status"
      assert_stubbed env, "gh", "--hostname=example.com", "auth", "status"

      skipped = File.read(log_path)
      assert_includes skipped, "gh --hostname example.com api rate_limit skipped"
      assert_includes skipped, "gh --hostname=example.com api rate_limit skipped"
      assert_includes skipped, "gh --hostname example.com auth status skipped"
      assert_includes skipped, "gh --hostname=example.com auth status skipped"
    end
  end

  def test_gh_stub_allows_w_inside_value_taking_read_options
    with_tmp_dir do |dir|
      real_gh = recording_binary(dir, "real-gh")
      @real_log = File.join(dir, "real.log")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log")
      }

      assert_passes env, "gh", "pr", "diff", "42", "-eworkflow.yml"
      assert_passes env, "gh", "pr", "diff", "42", "-e", "workflow.yml"
      assert_passes env, "gh", "pr", "list", "-lwip"
      assert_passes env, "gh", "pr", "list", "-l", "wip"
      assert_passes env, "gh", "pr", "view", "42", "-qweb"
      assert_passes env, "gh", "pr", "view", "42", "-q", "web"
      assert_passes env, "gh", "pr", "list", "--search", "-wip"
      assert_passes env, "gh", "pr", "list", "--search=-wip"
    end
  end

  def test_gh_api_cache_option_is_skipped_to_avoid_local_cache_writes
    with_tmp_dir do |dir|
      cache_home = File.join(dir, "cache")
      real_gh = cache_writing_gh_binary(dir, "real-gh")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "XDG_CACHE_HOME" => cache_home
      }

      [
        [ "--cache", "1h" ],
        [ "--cache=1h" ]
      ].each do |cache_args|
        FileUtils.rm_rf(cache_home)

        _out, err, status = Open3.capture3(
          env,
          stub_path("gh"),
          "api",
          "--method",
          "GET",
          *cache_args,
          "rate_limit"
        )

        assert status.success?, err
        refute_path_exists File.join(cache_home, "gh")
        assert_includes err, "[dry-run] gh api --method GET #{cache_args.join(' ')} rate_limit skipped"
      end
    end
  end

  def test_git_stub_scrubs_trace_env_before_read_only_passthrough
    with_tmp_git_repo do |dir|
      trace_path = File.join(dir, "trace.log")
      env = {
        "HIVE_BABYSITTER_REAL_GIT" => real_git_binary,
        "GIT_TRACE" => trace_path
      }

      out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, "status", "--short")

      assert status.success?, err
      assert_empty out
      refute_path_exists trace_path
    end
  end

  def test_git_stub_disables_optional_locks_before_read_only_passthrough
    with_tmp_dir do |dir|
      # `git status` (and other reads) otherwise take the optional index/refs locks and
      # rewrite `.git/index` to refresh stat data; the stub sets GIT_OPTIONAL_LOCKS=0 to keep
      # a dry-run read side-effect-free. Record the env the real binary actually receives so
      # deleting that guard (stub: `ENV["GIT_OPTIONAL_LOCKS"] = "0"`) turns this test red.
      real_git = recording_env_binary(dir, "real-git", %w[GIT_OPTIONAL_LOCKS GIT_PAGER PAGER])
      env = {
        "HIVE_BABYSITTER_REAL_GIT" => real_git,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log"),
        "GIT_PAGER" => "touch git-pager-pwned",
        "PAGER" => "touch pager-pwned"
      }

      _out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, "status", "--short")

      assert status.success?, err
      assert_equal "GIT_OPTIONAL_LOCKS=0\nGIT_PAGER=<unset>\nPAGER=<unset>\n", File.read(File.join(dir, "env.log"))
    end
  end

  def test_git_stub_disables_lazy_fetch_before_read_only_passthrough
    with_tmp_dir do |dir|
      source = File.join(dir, "source")
      clone = File.join(dir, "clone")
      run!("git", "init", "-b", "master", "--quiet", source)
      run!("git", "-C", source, "config", "user.email", "test@example.com")
      run!("git", "-C", source, "config", "user.name", "Test")
      run!("git", "-C", source, "config", "uploadpack.allowFilter", "true")
      File.write(File.join(source, "payload.txt"), "payload\n")
      run!("git", "-C", source, "add", "payload.txt")
      run!("git", "-C", source, "commit", "-m", "initial", "--quiet")
      blob = run!("git", "-C", source, "rev-parse", "HEAD:payload.txt").strip
      run!(
        "git",
        "-c",
        "protocol.file.allow=always",
        "clone",
        "--filter=blob:none",
        "--no-checkout",
        "--quiet",
        "file://#{source}",
        clone
      )

      _out, _err, before_status = Open3.capture3(
        { "GIT_NO_LAZY_FETCH" => "1" },
        "git",
        "-C",
        clone,
        "cat-file",
        "-e",
        blob
      )
      skip "local git did not leave the partial-clone blob missing" if before_status.success?

      out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", clone, "show", "HEAD:payload.txt")

      refute status.success?, "allowlisted git show unexpectedly succeeded: stdout=#{out.inspect} stderr=#{err.inspect}"
      _out, _err, after_status = Open3.capture3(
        { "GIT_NO_LAZY_FETCH" => "1" },
        "git",
        "-C",
        clone,
        "cat-file",
        "-e",
        blob
      )
      refute after_status.success?, "allowlisted git show lazy-fetched the missing blob"
    end
  end

  def test_git_stub_forces_no_pager_for_tty_passthrough
    with_tmp_git_repo do |dir|
      marker = File.join(dir, "pager-ran")
      pager = executable_touch_binary(
        dir,
        "pager",
        marker,
        "STDIN.each_line { |line| STDOUT.write(line) }"
      )
      run!("git", "-C", dir, "config", "core.pager", pager)

      env = real_git_env(dir).merge(
        "GIT_PAGER" => pager,
        "PAGER" => pager
      )

      out, status = capture_pty_stub(env, "git", "-C", dir, "log", "--oneline")

      assert status.success?, out
      assert_includes out, "initial"
      refute_path_exists marker, "git pager executed during dry-run passthrough"
    end
  end

  def test_git_stub_skips_exec_path_remote_helpers
    with_tmp_git_repo do |dir|
      helper_dir = File.join(dir, "helpers")
      FileUtils.mkdir_p(helper_dir)
      pwn_path = File.join(dir, "remote-helper-ran")
      helper = executable_touch_binary(helper_dir, "git-remote-https", pwn_path)
      run!("git", "-C", dir, "remote", "add", "origin", "https://example.invalid/owner/repo.git")

      env = real_git_env(dir).merge("GIT_EXEC_PATH" => helper_dir)
      _out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, "remote", "show", "origin")

      assert status.success?, err
      assert_includes err, "[dry-run] git -C #{dir} remote show origin skipped"
      refute_path_exists pwn_path, "#{helper} executed during dry-run passthrough"
    end
  end

  def test_git_stub_ignores_user_config_sources_before_read_only_passthrough
    with_tmp_git_repo do |dir|
      home = File.join(dir, "home")
      xdg = File.join(dir, "xdg")
      empty_xdg = File.join(dir, "empty-xdg")
      FileUtils.mkdir_p([ home, File.join(xdg, "git"), empty_xdg ])

      home_pwn = File.join(dir, "home-extdiff-ran")
      xdg_pwn = File.join(dir, "xdg-extdiff-ran")
      home_extdiff = executable_touch_binary(dir, "home-extdiff", home_pwn)
      xdg_extdiff = executable_touch_binary(dir, "xdg-extdiff", xdg_pwn)
      File.write(File.join(home, ".gitconfig"), <<~CONFIG)
        [diff]
          external = #{home_extdiff}
      CONFIG
      File.write(File.join(xdg, "git", "config"), <<~CONFIG)
        [diff]
          external = #{xdg_extdiff}
      CONFIG
      File.write(File.join(dir, "README.md"), "changed\n")

      base_env = {
        "HIVE_BABYSITTER_REAL_GIT" => real_git_binary,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log")
      }

      [
        [ "HOME", base_env.merge("HOME" => home, "XDG_CONFIG_HOME" => empty_xdg), home_extdiff, home_pwn ],
        [ "XDG_CONFIG_HOME", base_env.merge("HOME" => File.join(dir, "empty-home"), "XDG_CONFIG_HOME" => xdg), xdg_extdiff, xdg_pwn ]
      ].each do |source, env, configured_extdiff, pwn_path|
        out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, "config", "--list")

        assert status.success?, err
        refute_includes out, configured_extdiff, "#{source} git config reached real git"

        out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, "diff")

        assert status.success?, err
        assert_includes out, "README.md"
        refute_path_exists pwn_path, "#{source} diff.external executed during dry-run passthrough"
      end
    end
  end

  def test_git_stub_disables_local_exec_config_before_read_only_passthrough
    with_tmp_git_repo do |dir|
      pwn_path = File.join(dir, "local-extdiff-ran")
      extdiff = executable_touch_binary(dir, "local-extdiff", pwn_path)
      run!("git", "-C", dir, "config", "diff.external", extdiff)
      File.write(File.join(dir, "README.md"), "changed\n")

      out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", dir, "diff")

      assert status.success?, err
      assert_includes out, "README.md"
      refute_path_exists pwn_path
    end

    with_tmp_git_repo do |dir|
      pwn_path = File.join(dir, "textconv-ran")
      textconv = executable_touch_binary(
        dir,
        "textconv",
        pwn_path,
        "print File.read(ARGV.first) if ARGV.first && File.file?(ARGV.first)"
      )
      File.write(File.join(dir, ".gitattributes"), "README.md diff=hivepwn\n")
      run!("git", "-C", dir, "config", "diff.hivepwn.textconv", textconv)
      run!("git", "-C", dir, "add", ".gitattributes")
      run!("git", "-C", dir, "commit", "-m", "attrs", "--quiet")
      File.write(File.join(dir, "README.md"), "changed\n")

      out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", dir, "diff")

      assert status.success?, err
      assert_includes out, "README.md"
      refute_path_exists pwn_path
    end

    with_tmp_git_repo do |dir|
      pwn_path = File.join(dir, "fsmonitor-ran")
      fsmonitor = executable_touch_binary(dir, "fsmonitor", pwn_path)
      run!("git", "-C", dir, "config", "core.fsmonitor", fsmonitor)

      _out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", dir, "status", "--short")

      assert status.success?, err
      refute_path_exists pwn_path
    end
  end

  def test_git_stub_skips_signature_verification_options_without_running_gpg
    with_tmp_signed_git_repo do |dir, marker_path|
      env = real_git_env(dir)
      cases = [
        [ "log", "--show-signature", "-1" ],
        [ "show", "--show-signature", "HEAD" ],
        [ "log", "--format=%G?", "-1" ],
        [ "log", "--format", "%G?", "-1" ],
        [ "show", "--pretty=format:%G?", "HEAD" ],
        [ "rev-list", "--format=%G?", "HEAD", "-1" ]
      ]

      cases.each do |args|
        FileUtils.rm_f(marker_path)

        _out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, *args)

        assert status.success?, err
        assert_includes err, "[dry-run] git -C #{dir} #{args.join(' ')} skipped"
        refute_path_exists marker_path
      end
    end
  end

  def test_git_stub_disables_configured_signature_verification_before_passthrough
    with_tmp_signed_git_repo(log_show_signature: true) do |dir, marker_path|
      out, err, status = Open3.capture3(
        real_git_env(dir),
        stub_path("git"),
        "-C",
        dir,
        "log",
        "-1",
        "--format=%H"
      )

      assert status.success?, err
      assert_match(/\A[0-9a-f]{40}\n\z/, out)
      refute_path_exists marker_path
    end
  end

  def test_git_stub_disables_config_resolved_signature_format_before_passthrough
    with_tmp_signed_git_repo do |dir, marker_path|
      # The argv scan only sees literal `%G` in argv. A worktree-local pretty alias selected as
      # the default format resolves to a `%G?` signature placeholder even for a bare `git log`,
      # so the gate lets the read through. The passthrough must still neutralize the gpg exec
      # seam (`-c gpg.program=false` and friends) so the configured gpg.program helper cannot
      # run — `log.showSignature=false` does not suppress `%G*` placeholders.
      run!("git", "-C", dir, "config", "pretty.pwn", "format:%G?")
      run!("git", "-C", dir, "config", "format.pretty", "pwn")

      [
        [ "log", "-1" ],
        [ "log", "--pretty=pwn", "-1" ],
        [ "show", "--pretty=pwn", "HEAD" ]
      ].each do |args|
        FileUtils.rm_f(marker_path)

        _out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", dir, *args)

        assert status.success?, err
        refute_path_exists marker_path,
                           "config-resolved %G format ran gpg.program during #{args.join(' ')} passthrough"
      end
    end
  end

  def test_git_stub_pins_path_so_gpg_no_op_cannot_be_hijacked
    with_tmp_signed_git_repo do |dir, _marker_path|
      # The `-c gpg.program=false` no-op the stub installs neutralizes `%G*` signature
      # verification only if git resolves `false` from a trusted location — git looks `false`
      # up on PATH, and the inherited PATH is agent-controlled. An agent that prepends a
      # directory holding its own `false` would turn the supposed no-op back into an exec seam.
      # Drive verification through a config-resolved `%G` format (which passes the argv gate the
      # way a bare `git log` does) and confirm the poisoned `false` never runs because the stub
      # pins PATH to root-owned system dirs before handing off to real git.
      run!("git", "-C", dir, "config", "pretty.pwn", "format:%G?")
      run!("git", "-C", dir, "config", "format.pretty", "pwn")

      poison_dir = File.join(dir, "poison-bin")
      FileUtils.mkdir_p(poison_dir)
      poison_marker = File.join(dir, "poison-false-ran")
      executable_touch_binary(poison_dir, "false", poison_marker)

      env = real_git_env(dir).merge(
        "PATH" => [ poison_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      )

      [
        [ "log", "-1" ],
        [ "show", "--pretty=pwn", "HEAD" ]
      ].each do |args|
        FileUtils.rm_f(poison_marker)

        _out, err, status = Open3.capture3(env, stub_path("git"), "-C", dir, *args)

        assert status.success?, err
        refute_path_exists poison_marker,
                           "PATH-resolved gpg no-op ran the poisoned `false` during #{args.join(' ')} passthrough"
      end
    end
  end

  def test_git_stub_skips_remote_show_without_no_query_flag
    with_tmp_git_repo do |dir|
      pwn_path = File.join(dir, "remote-show-ran")
      helper = executable_touch_binary(dir, "remote-helper", pwn_path)
      run!("git", "-C", dir, "config", "protocol.ext.allow", "always")
      run!("git", "-C", dir, "config", "remote.origin.url", "ext::#{helper}")

      _out, err, status = Open3.capture3(real_git_env(dir), stub_path("git"), "-C", dir, "remote", "show", "origin")

      assert status.success?, err
      assert_includes err, "[dry-run] git -C #{dir} remote show origin skipped"
      refute_path_exists pwn_path
    end
  end

  private

  STUB_HANG_TIMEOUT_SEC = 10

  def capture_stub_with_timeout(env, binary, *args)
    Open3.popen3(env, stub_path(binary), *args) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      status = Timeout.timeout(STUB_HANG_TIMEOUT_SEC) { wait_thread.value }
      [ out_reader.value, err_reader.value, status ]
    rescue Timeout::Error
      Process.kill("TERM", wait_thread.pid)
      Process.wait(wait_thread.pid)
      raise
    rescue Errno::ESRCH, Errno::ECHILD
      raise Timeout::Error, "#{binary} stub did not exit"
    end
  end

  def assert_stubbed(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
    assert_includes err, "[dry-run] #{binary} #{args.join(' ')} skipped"
    # Load-bearing: prove the command did not also fall through to the real binary. A
    # regression that logs the skip *and then* still exec's real git/gh would pass the
    # stderr check above; the absence from real.log is what actually verifies no passthrough.
    real_log = @real_log && File.exist?(@real_log) ? File.read(@real_log) : ""
    [ "real-#{binary} #{args.join(' ')}", expected_real_invocation(binary, *args) ].uniq.each do |invocation|
      refute_includes real_log, invocation,
                      "#{binary} #{args.join(' ')} was skipped but still reached real #{binary}"
    end
  end

  def assert_passes(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
    # Load-bearing, mirroring assert_stubbed's refute: exit 0 alone does not prove passthrough
    # — a "skipped-but-exit-0" regression would also exit 0. Confirm the invocation actually
    # reached the real binary by finding it in real.log.
    real_log = @real_log && File.exist?(@real_log) ? File.read(@real_log) : ""
    assert_includes real_log, expected_real_invocation(binary, *args),
                    "#{binary} #{args.join(' ')} passed (exit 0) but never reached real #{binary}"
  end

  def expected_real_invocation(binary, *args)
    return "real-#{binary} #{args.join(' ')}" unless binary == "git"

    passthrough = args.dup
    index = git_subcommand_index(passthrough)
    if %w[diff log show].include?(passthrough[index].to_s)
      passthrough.insert(index + 1, "--no-ext-diff", "--no-textconv")
    end

    "real-git #{([
      "-c", "core.fsmonitor=false",
      "-c", "core.askPass=",
      "-c", "log.showSignature=false",
      "-c", "gpg.program=false",
      "-c", "gpg.openpgp.program=false",
      "-c", "gpg.x509.program=false",
      "-c", "gpg.ssh.program=false",
      "--no-pager"
    ] + passthrough).join(' ')}"
  end

  def git_subcommand_index(args)
    index = 0
    loop do
      case args[index]
      when "-C", "--git-dir", "--work-tree"
        index += 2
      when /\A--git-dir=/, /\A--work-tree=/
        index += 1
      else
        return index
      end
    end
  end

  def recording_binary(dir, name)
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(#{File.join(dir, "real.log").dump}, "a") do |file|
        file.puts(([File.basename($PROGRAM_NAME)] + ARGV).join(" "))
      end
    RUBY
    FileUtils.chmod("+x", path)
    path
  end

  def capture_pty_stub(env, binary, *args)
    output = +""
    status = nil

    PTY.spawn(env, stub_path(binary), *args) do |reader, writer, pid|
      writer.close
      output = Timeout.timeout(STUB_HANG_TIMEOUT_SEC) do
        buffer = +""
        begin
          loop { buffer << reader.readpartial(4096) }
        rescue EOFError, Errno::EIO
          # PTY EOF on Linux commonly surfaces as EIO after the child closes the slave.
        end
        _pid, status = Process.waitpid2(pid)
        buffer
      end
    rescue Timeout::Error
      Process.kill("TERM", pid)
      Process.wait(pid)
      raise
    end

    [ output, status ]
  end

  def cache_writing_gh_binary(dir, name)
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      cache_path = File.join(ENV.fetch("XDG_CACHE_HOME"), "gh")
      FileUtils.mkdir_p(cache_path)
      File.write(File.join(cache_path, "api-cache"), ARGV.join(" "))
    RUBY
    FileUtils.chmod("+x", path)
    path
  end

  def stub_path(binary)
    File.expand_path("../../../bin/hive-babysitter-stub-#{binary}", __dir__)
  end

  def recording_env_binary(dir, name, keys)
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      keys = #{keys.inspect}
      File.open(#{File.join(dir, "env.log").dump}, "a") do |file|
        keys.each do |key|
          value = ENV.key?(key) ? ENV.fetch(key) : "<unset>"
          file.puts("\#{key}=\#{value}")
        end
      end
    RUBY
    FileUtils.chmod("+x", path)
    path
  end

  def real_git_env(dir)
    {
      "HIVE_BABYSITTER_REAL_GIT" => real_git_binary,
      "HIVE_BABYSITTER_DRY_RUN_LOG" => File.join(dir, "skipped.log")
    }
  end

  def real_git_binary
    Hive::Babysitter::DryRunEnv.which("git") || raise("git binary not found on PATH")
  end

  def with_tmp_signed_git_repo(log_show_signature: false)
    with_tmp_dir do |dir|
      marker_path = File.join(dir, "gpg-ran")
      gpg = executable_touch_binary(dir, "fake-gpg", marker_path, "exit 1")
      run!("git", "-C", dir, "init", "-b", "master", "--quiet")
      run!("git", "-C", dir, "config", "user.email", "test@example.com")
      run!("git", "-C", dir, "config", "user.name", "Test")
      run!("git", "-C", dir, "config", "gpg.program", gpg)
      run!("git", "-C", dir, "config", "log.showSignature", "true") if log_show_signature
      File.write(File.join(dir, "README.md"), "test\n")
      run!("git", "-C", dir, "add", ".")

      tree = run!("git", "-C", dir, "write-tree").strip
      now = Time.now.to_i
      commit = [
        "tree #{tree}",
        "author Test <test@example.com> #{now} +0000",
        "committer Test <test@example.com> #{now} +0000",
        "gpgsig -----BEGIN PGP SIGNATURE-----",
        " ",
        " fake",
        " -----END PGP SIGNATURE-----",
        "",
        "synthetic signed commit"
      ].join("\n")
      commit << "\n"
      oid, status = Open3.capture2("git", "-C", dir, "hash-object", "-t", "commit", "-w", "--stdin", stdin_data: commit)
      raise "failed to create signed commit object" unless status.success?

      run!("git", "-C", dir, "update-ref", "refs/heads/master", oid.strip)
      yield dir, marker_path
    end
  end

  def executable_touch_binary(dir, name, pwn_path, after_touch = "")
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(#{pwn_path.dump}, "ran")
      #{after_touch}
    RUBY
    FileUtils.chmod("+x", path)
    path
  end
end
