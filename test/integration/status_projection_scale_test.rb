require "test_helper"
require "hive/commands/status"
require "support/status_projection_scale_fixture"

class StatusProjectionScaleTest < Minitest::Test
  include HiveTestHelper

  Fixture = HiveStatusProjectionScaleFixture

  def test_routine_status_work_is_independent_of_permanent_proof_cardinality
    with_tmp_global_config do |home|
      fixture = Fixture.build(root: File.join(home, "projects"))

      empty = scan(fixture, logical_proof_count: 0)
      full = scan(fixture, logical_proof_count: Fixture::LOGICAL_PROOF_COUNT)

      assert_equal Fixture::TASK_COUNT, empty.fetch(:rows).length
      assert_equal Fixture::TASK_COUNT, full.fetch(:rows).length
      assert_equal Fixture::LOGICAL_PROOF_COUNT,
                   full.fetch(:attempt_store).logical_proof_count
      assert_equal 0, empty.fetch(:attempt_store).proof_directory_enumerations
      assert_equal 0, full.fetch(:attempt_store).proof_directory_enumerations
      assert_equal 0, empty.dig(:counters, :full_journal_reads)
      assert_equal 0, full.dig(:counters, :full_journal_reads)
      assert_operator empty.dig(:counters, :journal_suffix_bytes), :>, 0
      assert_operator full.dig(:counters, :journal_suffix_bytes), :>, 0
      assert_equal empty.fetch(:counters), full.fetch(:counters)
      assert_equal Fixture::TASK_COUNT, full.dig(:counters, :stores)
      assert_equal empty.fetch(:attempt_store).point_fetches,
                   full.fetch(:attempt_store).point_fetches
      assert_equal Fixture::TASK_COUNT - 1,
                   full.fetch(:attempt_store).point_fetches
      assert_equal 1,
                   full.fetch(:attempt_store).fetches_by_id.fetch(
                     attempt_id_for(fixture.deep_slug)
                   ),
                   "deep pre-checkpoint history must still require one exact attempt binding"
    end
  end

  def test_one_invalid_task_is_row_local_and_patrol_fix_remains_ready
    with_tmp_global_config do |home|
      fixture = Fixture.build(root: File.join(home, "projects"))
      result = scan(fixture, logical_proof_count: Fixture::LOGICAL_PROOF_COUNT)
      rows = result.fetch(:rows)

      invalid = rows.find { |row| row.fetch("slug") == fixture.invalid_slug }
      patrol = rows.find { |row| row.fetch("slug") == fixture.patrol_slug }
      refute_nil invalid
      refute_nil patrol
      assert_equal "error", invalid.fetch("action")
      assert_equal Hive::TaskProjection::REPAIR_REQUIRED_REASON,
                   invalid.fetch("attrs").fetch("reason")
      assert_equal "checkpoint_invalid",
                   invalid.fetch("attrs").fetch("projection_reason")
      assert_equal "ready_to_run", patrol.fetch("action")
      assert_equal "patrol-fix", patrol.fetch("workflow")
      assert_equal "2-fix", patrol.fetch("stage")
      assert_equal Fixture::TASK_COUNT - 2,
                   rows.count { |row| row.fetch("slug").start_with?("scale-task-") && row != invalid }
    end
  end

  private

  def scan(fixture, logical_proof_count:)
    counters = Fixture.counters
    attempt_store = Fixture::AttemptProjectionFacade.new(
      attempts: fixture.attempts,
      logical_proof_count: logical_proof_count
    )
    command = Hive::Commands::Status.new
    command.instance_variable_set(:@status_attempt_store, attempt_store)
    factory = lambda do |**options|
      Fixture::InstrumentedStore.allocate.tap do |store|
        store.send(:initialize, counters: counters, **options)
      end
    end
    payload = nil
    with_replaced_singleton_method(Hive::TaskProjection::Store, :new, factory) do
      payload = command.project_payload(
        fixture.project,
        project_count: 1,
        now: Time.utc(2026, 8, 29, 12, 0, 0)
      )
    end
    {
      rows: payload.fetch("tasks"),
      counters: counters,
      attempt_store: attempt_store
    }
  end

  def attempt_id_for(slug)
    index = Integer(slug.split("-").last)
    "scale-attempt-#{index}"
  end
end
