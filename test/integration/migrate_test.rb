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
        assert File.directory?(File.join(stages, "7-finalize", "old-pr-260513-abcd"))
        assert File.directory?(File.join(stages, "8-done", "old-done-260513-abcd"))
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
end
