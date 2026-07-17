require "test_helper"
require "hive/attempts/store"
require "hive/daemon/retry_coordinator"
require "hive/terminal_error_registry"
require_relative "../support/retry_coordinator_helpers"

class RetryErrorFamilyMatrixTest < Minitest::Test
  include HiveTestHelper
  include RetryCoordinatorTestHelpers

  NOW = Time.utc(2026, 7, 17, 10, 0, 0)
  FAMILIES = %w[
    agent_died timeout codex_auth review_failed pr_open_failed
    pr_rebase_failed pr_push_failed finalize_failed unknown
  ].freeze

  def test_every_terminal_family_uses_one_error_agnostic_ladder
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      current_time = NOW
      coordinator = Hive::Daemon::RetryCoordinator.new(
        task_folder: dir, attempt_store: store,
        clock: -> { current_time }, id_generator: -> { SecureRandom.uuid }
      )

      records = FAMILIES.each_with_index.map do |code, index|
        attempt = create_failed_retry_attempt(store, id: "family-#{index}", now: current_time)
        diagnosis = Hive::TerminalErrorRegistry.diagnose(
          code: code,
          payload: { "provider" => "codex", "message" => "#{code} failed API_TOKEN=secret" }
        )
        record = coordinator.report_failure(
          **retry_failure_args(
            attempt, code: diagnosis.fetch("code"), terminal_event_id: "terminal-#{index}",
            evidence: diagnosis.fetch("evidence")
          )
        )
        current_time += 10_000
        record
      end

      assert_equal (1..FAMILIES.length).to_a, records.map(&:retry_count)
      assert_equal [ 60, 60, 60, 300, 600, 3600, 3600, 3600, 3600 ], records.map { |record|
        Time.iso8601(record.to_h.fetch("retry_after")) -
          Time.iso8601(record.to_h.fetch("last_failure_at"))
      }
      assert_equal FAMILIES, records.map(&:failure_code)
      refute_includes File.read(File.join(dir, "events.jsonl")), "API_TOKEN=secret"
    end
  end

  def test_same_error_on_another_task_has_an_independent_key
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      first_dir = File.join(dir, "first")
      second_dir = File.join(dir, "second")
      FileUtils.mkdir_p([ first_dir, second_dir ])
      first = Hive::Daemon::RetryCoordinator.new(task_folder: first_dir, attempt_store: store)
      second = Hive::Daemon::RetryCoordinator.new(task_folder: second_dir, attempt_store: store)

      a = create_failed_retry_attempt(store, id: "a", now: NOW, slug: "task-a")
      b = create_failed_retry_attempt(store, id: "b", now: NOW, slug: "task-b")
      first_record = first.report_failure(
        **retry_failure_args(a, code: "agent_died", terminal_event_id: "terminal-a")
      )
      second_record = second.report_failure(
        **retry_failure_args(b, code: "agent_died", terminal_event_id: "terminal-b")
      )

      assert_equal 1, first_record.retry_count
      assert_equal 1, second_record.retry_count
      refute_equal first_record.key.fetch("task"), second_record.key.fetch("task")
    end
  end
end
