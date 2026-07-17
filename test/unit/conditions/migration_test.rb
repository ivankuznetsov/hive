require "test_helper"
require "hive/conditions/migration"
require "hive/config"
require "hive/markers"

class ConditionsMigrationTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:id, :slug, keyword_init: true)

  def test_mode_selection_is_explicit_stage_scoped_and_handoff_gated
    config = {
      "conditions" => {
        "authority" => "shadow",
        "stages" => { "4-execute" => "conditions" }
      }
    }
    legacy = { "identity" => { "attempt_id" => nil } }
    supervised = { "identity" => { "attempt_id" => "attempt-1" } }

    assert_equal "markers", Hive::Conditions::Migration.configured_mode(config, "3-plan")
    before = Hive::Conditions::Migration.selection(
      config: config, stage: "4-execute", projection: legacy
    )
    assert_equal "conditions", before.configured
    assert_equal "markers", before.effective
    refute before.handoff_complete

    after = Hive::Conditions::Migration.selection(
      config: config, stage: "4-execute", projection: supervised
    )
    assert_equal "conditions", after.effective
    assert after.handoff_complete

    rolled_back = Hive::Conditions::Migration.selection(
      config: { "conditions" => { "authority" => "markers", "stages" => {} } },
      stage: "4-execute", projection: supervised
    )
    assert_equal "markers", rolled_back.effective
    assert_equal "attempt-1", supervised.dig("identity", "attempt_id")
  end

  def test_non_execute_condition_authority_and_invalid_modes_are_rejected
    assert_raises(Hive::Conditions::InvalidMigrationMode) do
      Hive::Conditions::Migration.validate_mode!("conditions", "5-open-pr")
    end
    assert_raises(Hive::Conditions::InvalidMigrationMode) do
      Hive::Conditions::Migration.validate_mode!("automatic", "4-execute")
    end
  end

  def test_legacy_baseline_is_written_once_only_at_explicit_mutating_boundary
    with_tmp_dir do |dir|
      task = TaskStub.new(id: 42, slug: "legacy-task")
      marker = Hive::Markers::State.new(
        name: :execute_waiting, attrs: { "reason" => "no_worktree_changes" }, raw: nil
      )
      writer = Hive::TaskJournal::Writer.new(task_folder: dir)

      first = Hive::Conditions::Migration.ensure_legacy_baseline!(
        task: task, writer: writer, marker: marker,
        head_sha: "a" * 40, branch: "feature"
      )
      second = Hive::Conditions::Migration.ensure_legacy_baseline!(
        task: task, writer: writer, marker: marker,
        head_sha: "a" * 40, branch: "feature"
      )

      records = Hive::TaskProjection.read_journal(writer.path)
      assert_instance_of Hive::TaskJournal::AppendResult, first
      assert_equal "legacy_baseline", second.fetch("event_type")
      assert_equal 1, records.count { |record| record["event_type"] == "legacy_baseline" }
      baseline = records.first
      assert_equal 0, baseline.fetch("task_generation")
      assert_equal "legacy", baseline.fetch("attempt_id")
      assert_equal "execute_waiting", baseline.dig("payload", "legacy_marker", "name")
    end
  end

  def test_config_validation_defaults_to_markers_and_rejects_bad_overrides
    defaults = Hive::Config::DEFAULTS
    assert_equal "markers", defaults.dig("conditions", "authority")
    Hive::Config.validate_conditions!(defaults, "/tmp/config.yml")

    invalid = Marshal.load(Marshal.dump(defaults))
    invalid["conditions"] = { "authority" => "markers", "stages" => { "5-open-pr" => "conditions" } }
    assert_raises(Hive::ConfigError) do
      Hive::Config.validate_conditions!(invalid, "/tmp/config.yml")
    end

    invalid_settings = [
      { "authority" => "markers", "unknown" => true },
      { "authority" => "automatic" },
      { "authority" => "markers", "stages" => [] },
      { "authority" => "markers", "stages" => { "99-unknown" => "markers" } }
    ]
    invalid_settings.each do |settings|
      candidate = Marshal.load(Marshal.dump(defaults))
      candidate["conditions"] = settings
      assert_raises(Hive::ConfigError) do
        Hive::Config.validate_conditions!(candidate, "/tmp/config.yml")
      end
    end
  end
end
