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
end
