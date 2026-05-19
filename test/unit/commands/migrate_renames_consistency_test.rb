require "test_helper"
require "hive/commands/migrate"
require "hive/stages"

# Guards the invariant that connects two files: any future stage rename in
# `lib/hive/stages.rb` must also be reflected in `Migrate::STAGE_RENAMES`.
# These checks would have caught the off-by-one mistake of mapping
# `6-pr → 5-open-pr` (which lost task state because `5-open-pr` is the
# pre-PR stage, not the post-PR stage) when the PR-first pipeline shipped.
class MigrateRenamesConsistencyTest < Minitest::Test
  def test_every_rename_target_is_a_current_stage_directory
    renames = Hive::Commands::Migrate::STAGE_RENAMES
    unknown = renames.values.uniq - Hive::Stages::DIRS
    assert_empty unknown,
                 "Migrate::STAGE_RENAMES has targets that are not in Hive::Stages::DIRS " \
                 "(#{unknown.inspect}); update lib/hive/commands/migrate.rb when stage names change"
  end

  def test_no_rename_key_is_also_a_current_stage_directory
    renames = Hive::Commands::Migrate::STAGE_RENAMES
    overlap = renames.keys & Hive::Stages::DIRS
    assert_empty overlap,
                 "Migrate::STAGE_RENAMES has keys that are still canonical stage names " \
                 "(#{overlap.inspect}); a legacy key cannot be both legacy and current"
  end

  def test_no_rename_key_is_also_a_rename_target
    renames = Hive::Commands::Migrate::STAGE_RENAMES
    chain = renames.keys & renames.values
    assert_empty chain,
                 "Migrate::STAGE_RENAMES has keys that are also values (#{chain.inspect}); " \
                 "chained renames would migrate twice or land on a legacy name"
  end
end
