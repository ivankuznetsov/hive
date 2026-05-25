require "test_helper"
require "hive/commands/init"
require "hive/commands/migrate"

class MigrateTest < Minitest::Test
  include HiveTestHelper

  def test_migrates_legacy_stage_directories
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        {
          "5-review" => "old-review-260513-abcd",
          "6-pr" => "old-pr-260513-abcd",
          "7-done" => "old-done-260513-abcd"
        }.each do |stage, slug|
          folder = File.join(stages, stage, slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), "x\n")
        end

        capture_io { Hive::Commands::Migrate.new(dir).call }

        assert File.directory?(File.join(stages, "6-review", "old-review-260513-abcd"))
        assert File.directory?(File.join(stages, "8-finalize", "old-pr-260513-abcd"))
        assert File.directory?(File.join(stages, "9-done", "old-done-260513-abcd"))
      end
    end
  end

  def test_migrates_previous_canonical_finalize_and_done_stage_directories
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        {
          "7-finalize" => "old-finalize-260522-abcd",
          "8-done" => "old-done-260522-abcd"
        }.each do |stage, slug|
          folder = File.join(stages, stage, slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), "x\n")
        end

        capture_io { Hive::Commands::Migrate.new(dir).call }

        assert File.directory?(File.join(stages, "8-finalize", "old-finalize-260522-abcd"))
        assert File.directory?(File.join(stages, "9-done", "old-done-260522-abcd"))
      end
    end
  end

  def test_migrate_refuses_conflicting_slug
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        old = File.join(stages, "5-review", "same-260513-abcd")
        current = File.join(stages, "6-review", "same-260513-abcd")
        FileUtils.mkdir_p(old)
        FileUtils.mkdir_p(current)

        assert_raises(Hive::DestinationCollision) do
          capture_io { Hive::Commands::Migrate.new(dir).call }
        end
        assert File.directory?(old)
        assert File.directory?(current)
      end
    end
  end

  def test_migrate_preflight_catches_plan_internal_duplicate_destination
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        slug = "same-finalize-260525-aaaa"
        FileUtils.mkdir_p(File.join(stages, "6-pr", slug))
        FileUtils.mkdir_p(File.join(stages, "7-finalize", slug))

        err = assert_raises(Hive::DestinationCollision) do
          capture_io { Hive::Commands::Migrate.new(dir).call }
        end

        assert_match(/multiple legacy stages target the same destination/, err.message)
        assert File.directory?(File.join(stages, "6-pr", slug))
        assert File.directory?(File.join(stages, "7-finalize", slug))
        refute File.directory?(File.join(stages, "8-finalize", slug)),
               "plan-internal duplicate destinations must abort before any mv"
      end
    end
  end

  # Mid-loop atomicity (round-1 finding): pre-flight collision check
  # must catch a SECOND-iteration collision BEFORE the first-iteration
  # rename runs. Without this, a successful 5-review→6-review followed
  # by a 6-pr→8-finalize collision would leave the filesystem partially
  # renamed with no rollback.
  def test_migrate_preflight_catches_later_collision_before_first_mv
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        review_slug = "review-260513-aaaa"
        pr_slug = "pr-260513-bbbb"
        # Set up a clean 5-review→6-review path (would succeed alone)
        FileUtils.mkdir_p(File.join(stages, "5-review", review_slug))
        # And a 6-pr→8-finalize collision (destination exists).
        FileUtils.mkdir_p(File.join(stages, "6-pr", pr_slug))
        FileUtils.mkdir_p(File.join(stages, "8-finalize", pr_slug))

        assert_raises(Hive::DestinationCollision) do
          capture_io { Hive::Commands::Migrate.new(dir).call }
        end

        # CRITICAL: the first-iteration rename must NOT have run.
        # If pre-flight is broken, 5-review/review-... would be gone.
        assert File.directory?(File.join(stages, "5-review", review_slug)),
               "pre-flight must catch later-iteration collisions BEFORE issuing any mv"
        refute File.directory?(File.join(stages, "6-review", review_slug)),
               "first-iteration destination must NOT exist after pre-flight failure"
      end
    end
  end

  # Skip non-slug entries (round-1 finding): only task-folder slugs
  # should migrate. `.DS_Store`, stray `.lock`, etc. must stay put.
  def test_migrate_skips_non_slug_entries
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        FileUtils.mkdir_p(File.join(stages, "5-review", ".DS_Store"))
        FileUtils.mkdir_p(File.join(stages, "5-review", "real-260513-aaaa"))

        capture_io { Hive::Commands::Migrate.new(dir).call }

        assert File.directory?(File.join(stages, "5-review", ".DS_Store")),
               "non-slug `.DS_Store` directory must stay in the legacy stage dir"
        assert File.directory?(File.join(stages, "6-review", "real-260513-aaaa")),
               "task slug must migrate normally"
      end
    end
  end

  def test_migrate_reports_already_migrated_noop
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        out, _err = capture_io { Hive::Commands::Migrate.new(dir).call }

        assert_includes out, "target stage directories look already-migrated"
      end
    end
  end

  def test_migrate_reports_plain_noop_when_legacy_dirs_only_have_non_slug_entries
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        ignored = File.join(stages, "5-review", ".DS_Store")
        FileUtils.mkdir_p(ignored)

        out, _err = capture_io { Hive::Commands::Migrate.new(dir).call }

        assert_includes out, "hive: migrate found nothing to move"
        refute_includes out, "already-migrated"
        assert File.directory?(ignored), "non-slug entry must remain in the legacy stage directory"
      end
    end
  end

  # Commit-message assertion (round-1 finding): regression that drops
  # the commit (or changes the message) would otherwise be invisible.
  def test_migrate_writes_a_commit_with_descriptive_message
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        FileUtils.mkdir_p(File.join(stages, "5-review", "demo-260513-aaaa"))
        File.write(File.join(stages, "5-review", "demo-260513-aaaa", "task.md"), "x\n")

        capture_io { Hive::Commands::Migrate.new(dir).call }

        log = `git -C #{hive_state.shellescape} log --oneline -5`
        assert $CHILD_STATUS.success?, "git log must succeed"
        assert_match(/hive: migrate stage directories \(1 task\)/, log,
                     "commit message must name the migrated task count")
      end
    end
  end

  # Config-key rewrite (round-1 finding + the transition-shim removal
  # path): `budget_usd.pr` / `timeout_sec.pr` get rewritten onto
  # `.finalize` so Stages::Finalize's read-through fallback has
  # somewhere to go.
  def test_migrate_rewrites_legacy_config_keys
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        # Set ONLY the legacy keys (delete the canonical to prove the
        # rewrite happens). When both keys exist post-rewrite, the
        # canonical wins by design (the user tuned post-migration).
        cfg["budget_usd"] ||= {}
        cfg["budget_usd"].delete("finalize")
        cfg["budget_usd"]["pr"] = 77
        cfg["timeout_sec"] ||= {}
        cfg["timeout_sec"].delete("finalize")
        cfg["timeout_sec"]["pr"] = 1234
        File.write(cfg_path, cfg.to_yaml)

        capture_io { Hive::Commands::Migrate.new(dir).call }

        cfg_after = YAML.safe_load(File.read(cfg_path))
        refute cfg_after["budget_usd"].key?("pr"),
               "legacy `budget_usd.pr` key must be removed"
        assert_equal 77, cfg_after.dig("budget_usd", "finalize"),
                     "legacy value must propagate onto canonical `finalize` key"
        refute cfg_after["timeout_sec"].key?("pr")
        assert_equal 1234, cfg_after.dig("timeout_sec", "finalize")
      end
    end
  end

  # Idempotent rerun: when both legacy and canonical keys exist, the
  # canonical value wins (user-tuned post-migration).
  def test_migrate_preserves_canonical_on_collision_with_legacy
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        cfg["budget_usd"] ||= {}
        cfg["budget_usd"]["finalize"] = 99
        cfg["budget_usd"]["pr"] = 77
        File.write(cfg_path, cfg.to_yaml)

        capture_io { Hive::Commands::Migrate.new(dir).call }

        cfg_after = YAML.safe_load(File.read(cfg_path))
        assert_equal 99, cfg_after.dig("budget_usd", "finalize"),
                     "canonical value must win on collision (user-tuned wins over legacy)"
        refute cfg_after["budget_usd"].key?("pr"),
               "legacy key must still be removed even when canonical wins"
      end
    end
  end
  def test_migrate_warns_with_recovery_command_when_git_commit_fails
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) do |*_args|
      raise Hive::GitError, "permission denied"
    end
    migrate = Hive::Commands::Migrate.new("/tmp/project")

    with_replaced_singleton_method(Hive::GitOps, :new, lambda { |_project_path| fake_ops }) do
      _out, err = capture_io do
        migrate.send(:commit_migration, "/tmp/project/.hive-state", [ [ "5-review", "6-review", "demo-260525-aaaa" ] ])
      end

      assert_includes err, "could not commit them to the hive-state git history"
      assert_includes err, "git -C /tmp/project/.hive-state add -A"
      assert_includes err, "hive: migrate stage directories (1 task)"
    end
  end

  def test_restart_daemon_uses_systemctl_when_available
    migrate = Hive::Commands::Migrate.new("/tmp/project")
    calls = []
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { true }
    migrate.define_singleton_method(:system) do |*args, **kwargs|
      calls << [ args, kwargs ]
      true
    end

    out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_equal [ [ [ "systemctl", "--user", "restart", "hive-daemon" ], { out: File::NULL, err: File::NULL } ] ], calls
    assert_includes out, "restarted hive-daemon (pid 1234)"
    assert_empty err
  end

  def test_restart_daemon_warns_when_systemctl_restart_fails
    migrate = Hive::Commands::Migrate.new("/tmp/project")
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { true }
    migrate.define_singleton_method(:system) { |*_args, **_kwargs| false }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "systemctl --user restart hive-daemon` failed"
  end

  def test_restart_daemon_warns_when_systemctl_is_unavailable
    migrate = Hive::Commands::Migrate.new("/tmp/project")
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { false }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "restart it manually so its in-memory stage layout refreshes"
  end

  def test_read_daemon_pid_accepts_hash_payload
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".daemon.pid"), { "pid" => 4321 }.to_yaml)
      with_env("HIVE_HOME" => dir) do
        assert_equal 4321, Hive::Commands::Migrate.new("/tmp/project").send(:read_daemon_pid)
      end
    end
  end

  def test_read_daemon_pid_returns_nil_when_pid_file_cannot_be_read
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      File.write(pid_file, { "pid" => 4321 }.to_yaml)
      original = File.method(:read)
      with_env("HIVE_HOME" => dir) do
        with_replaced_singleton_method(File, :read, lambda { |path, *args, **kwargs|
          raise Errno::EACCES if path == pid_file

          original.call(path, *args, **kwargs)
        }) do
          assert_nil Hive::Commands::Migrate.new("/tmp/project").send(:read_daemon_pid)
        end
      end
    end
  end

  def test_read_daemon_pid_returns_nil_when_pid_file_stat_fails
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      File.write(pid_file, { "pid" => 4321 }.to_yaml)
      original = File.method(:exist?)
      with_env("HIVE_HOME" => dir) do
        with_replaced_singleton_method(File, :exist?, lambda { |path|
          raise Errno::EACCES if path == pid_file

          original.call(path)
        }) do
          assert_nil Hive::Commands::Migrate.new("/tmp/project").send(:read_daemon_pid)
        end
      end
    end
  end

  def test_daemon_alive_classifies_signal_results
    migrate = Hive::Commands::Migrate.new("/tmp/project")

    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| 1 }) do
      assert migrate.send(:daemon_alive?, 1234)
    end
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::ESRCH }) do
      refute migrate.send(:daemon_alive?, 1234)
    end
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
      assert migrate.send(:daemon_alive?, 1234)
    end
  end

  def test_systemctl_available_returns_false_when_system_call_cannot_spawn
    migrate = Hive::Commands::Migrate.new("/tmp/project")
    migrate.define_singleton_method(:system) { |*_args, **_kwargs| raise Errno::ENOENT }

    refute migrate.send(:systemctl_available?)
  end
end
