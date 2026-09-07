require "test_helper"
require "hive/daily_digest/hold_observer"

class DailyDigestHoldObserverTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:folder, :stage, :marker_attrs, :provider, keyword_init: true)

  def test_records_changed_provider_capacity_and_authority_holds_with_exits
    with_tmp_dir do |root|
      records = []
      activity = Object.new
      activity.define_singleton_method(:record) { |**values| records << values }
      observer = Hive::DailyDigest::HoldObserver.new(activity_factory: ->(_task) { activity })

      %w[provider capacity authority].each_with_index do |kind, index|
        folder = File.join(root, ".hive-state", "stages", "4-execute", "task-#{index}")
        FileUtils.mkdir_p(folder)
        row = Row.new(folder: folder, stage: "4-execute", marker_attrs: {})
        decision, owner = case kind
        when "provider"
          row.marker_attrs = { "reason" => "limits_reached", "provider" => "codex" }
          [ :cooldown, "scheduler" ]
        when "capacity" then [ :global_cap, "scheduler" ]
        else [ :quarantined, "operator" ]
        end

        observer.record(row, decision: decision, owner: owner, reason: "held")
        observer.record(row, decision: decision, owner: owner, reason: "held")
        row.marker_attrs = {}
        observer.record(row, decision: :idle, owner: "scheduler", reason: "available")
      end

      assert_equal %w[active cleared active cleared active cleared],
                   records.map { |record| record.dig(:payload, "state") }
      assert_equal %w[provider provider capacity capacity authority authority],
                   records.map { |record| record.dig(:payload, "hold_kind") }
      assert records.all? { |record| record.fetch(:kind) == "hold_recorded" }
    end
  end

  def test_seeded_hold_state_uses_the_bounded_journal_tail
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(folder)
      journal = File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME)
      padding = JSON.generate("padding" => "x" * Hive::DailyDigest::HoldObserver::MAX_SEED_BYTES)
      active = JSON.generate(
        "event_type" => "activity_recorded",
        "payload" => {
          "activity_kind" => "hold_recorded", "state" => "active",
          "hold_kind" => "provider"
        }
      )
      File.write(journal, "#{padding}\n{malformed\n#{active}\n")
      records = []
      activity = Object.new
      activity.define_singleton_method(:record) { |**values| records << values }
      observer = Hive::DailyDigest::HoldObserver.new(activity_factory: ->(_task) { activity })
      row = Row.new(
        folder: folder, stage: "4-execute",
        marker_attrs: { "reason" => "limits_reached", "provider" => "codex" }
      )

      observer.record(row, decision: :provider_hold, owner: "scheduler", reason: "held")
      row.marker_attrs = {}
      observer.record(row, decision: :idle, owner: "scheduler", reason: "available")

      assert_equal [ "cleared" ], records.map { |record| record.dig(:payload, "state") }
      assert_nil observer.send(:value, Object.new, :missing)
    end
  end
end
