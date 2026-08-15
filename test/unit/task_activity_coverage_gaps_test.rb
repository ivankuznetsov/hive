require "test_helper"
require "hive/task_activity"

class TaskActivityCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 12, 12)

  class Writer
    attr_reader :attempt_store

    def initialize(attempt_store = nil)
      @attempt_store = attempt_store
    end

    def append_idempotent(*)
      Struct.new(:event_id).new("event")
    end
  end

  class FakeActivity
    attr_reader :task_folder

    def initialize(task_folder)
      @task_folder = task_folder
    end

    def binding
      {
        "task" => { "id" => "1", "slug" => "task" }, "workflow" => "coding",
        "stage" => "4-execute", "attempt_id" => "attempt", "task_generation" => 1,
        "ownership_generation" => nil, "commit_generation" => nil
      }
    end

    def relocated(task_folder:)
      self.class.new(task_folder)
    end

    def activity_for_operation_receipt(*) = self
    def operation_time = NOW
  end

  class ReconcileOperation
    attr_reader :bytes, :receipt, :actions

    def initialize(status:, bytes: 10, terminal: false)
      @status = status
      @bytes = bytes
      @terminal = terminal
      @actions = []
      @receipt = { "status" => status }
    end

    def terminal? = @terminal
    def committed? = @status == :already_committed
    def replay! = @actions << :replayed
    def complete!(result:) = @actions << [ :complete, result ]
    def abort!(reason:) = @actions << [ :abort, reason ]
    def gap!(reason:) = @actions << [ :gap, reason ]
  end

  def test_for_task_context_constructor_and_relocation_edges
    with_tmp_dir do |root|
      attempt = { "intended_stage" => "4-execute" }
      attempt.define_singleton_method(:ownership_generation) { "owner" }
      store = Object.new
      store.define_singleton_method(:fetch) { |_| attempt }
      projection = Object.new
      projection.define_singleton_method(:read) do
        Struct.new(:to_h).new(
          { "identity" => { "attempt_id" => "attempt", "task_generation" => 1 } }
        )
      end
      workflow = Struct.new(:id).new("custom")
      task = Struct.new(:folder, :workflow, :id, :slug).new(root, workflow, 1, "task")
      with_replaced_singleton_method(Hive::TaskProjection::Store, :new, ->(**) { projection }) do
        activity = Hive::TaskActivity.for_task(task, attempt_store: store)
        assert_equal "custom", activity.binding.fetch("workflow")
      end

      with_replaced_singleton_method(
        Hive::TaskProjection::Store, :new, ->(**) { raise Hive::Error, "bad projection" }
      ) do
        assert_nil Hive::TaskActivity.for_task(task, attempt_store: store)
      end

      context = Struct.new(
        :attempt_id, :task_generation, :ownership_generation, :intended_stage
      ).new("attempt", 1, nil, "4-execute")
      activity = Hive::TaskActivity.for_context(task, context: context, attempt_store: store)
      assert_kind_of Time, activity.operation_time
      relocated = activity.relocated(task_folder: File.join(root, "moved"))
      assert_equal File.join(root, "moved"), relocated.task_folder

      assert_raises(Hive::TaskActivity::InvalidActivity) do
        Hive::TaskActivity.new(
          task_folder: root, task: { slug: "task" }, workflow: "coding",
          stage: "4-execute", attempt_id: "attempt", task_generation: 1,
          commit_generation: -1, writer: Writer.new
        )
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        Hive::TaskActivity.new(
          task_folder: root, task: { slug: "task" }, workflow: "coding",
          stage: "4-execute", attempt_id: "attempt", task_generation: Object.new,
          writer: Writer.new
        )
      end

      default_clock = Hive::TaskActivity.new(
        task_folder: root, task: { slug: "task" }, workflow: "coding",
        stage: "4-execute", attempt_id: "attempt", task_generation: 1,
        writer: Writer.new
      )
      assert_kind_of Time, default_clock.operation_time
    end
  end

  def test_operation_receipt_activity_binding_and_value_guards
    with_tmp_dir do |root|
      activity = build_activity(root, writer: Writer.new)
      receipt = valid_receipt
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.activity_for_operation_receipt(receipt.merge("workflow" => "other"))
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.activity_for_operation_receipt(receipt)
      end

      assert_equal [ "committed", "value" ], activity.send(
        :reconciliation_verdict, status: :committed, result: "value"
      )
      assert_equal [ "committed", "fingerprint" ], activity.send(
        :reconciliation_verdict, status: :committed, result_fingerprint: "fingerprint"
      )
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.send(:normalize_task, "slug" => "task", "id" => "bad/id")
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.send(:normalize_time, "bad", "occurred_at")
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.send(:sanitize_evidence, [ "not an object" ])
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) { activity.send(:sanitize, Object.new) }
      assert_equal 1, activity.send(:sanitize, 1)
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.send(:enforce_size!, { "value" => "x" * 70_000 }, [])
      end

      bad_hash = Object.new
      bad_hash.define_singleton_method(:to_h) { "not a hash" }
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.record(
          kind: "answer_recorded", operation_id: "answer:bad-payload",
          reason: "bad payload", source: "command_service", payload: bad_hash
        )
      end
      type_error_payload = Object.new
      type_error_payload.define_singleton_method(:to_h) { raise TypeError, "not coercible" }
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.record(
          kind: "answer_recorded", operation_id: "answer:type-error",
          reason: "bad payload", source: "command_service", payload: type_error_payload
        )
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.record(
          kind: "answer_recorded", operation_id: "bad id",
          reason: "bad operation", source: "command_service"
        )
      end
    end
  end

  def test_reconciliation_caps_and_all_resolver_outcomes
    with_tmp_dir do |root|
      activity = build_activity(root)
      directory = File.join(root, Hive::TaskActivity::OPERATION_DIRECTORY)
      FileUtils.mkdir_p(directory)
      names = 5.times.map { |index| "#{index.to_s(16).rjust(64, '0')}.json" }
      names.each { |name| File.write(File.join(directory, name), "{}") }
      operations = [
        ReconcileOperation.new(status: :committed),
        ReconcileOperation.new(status: :not_committed),
        ReconcileOperation.new(status: :ambiguous),
        ReconcileOperation.new(status: :defer),
        ReconcileOperation.new(status: :invalid)
      ]
      index = 0
      replacement = lambda do |**|
        operation = operations.fetch(index)
        index += 1
        operation
      end
      resolver = lambda do |receipt|
        status = receipt.fetch("status")
        status == :committed ? { status: :committed, result: "ok" } : status
      end
      with_replaced_singleton_method(Hive::TaskActivity::Operation, :open!, replacement) do
        result = activity.reconcile_operations!(max_receipts: 10, &resolver)
        assert_equal 5, result.fetch("processed")
        assert_equal 1, result.fetch("completed")
        assert_equal 1, result.fetch("gaps")
        assert_equal "operation_receipt_invalid", result.dig("diagnostics", 0, "reason")
      end

      index = 0
      with_replaced_singleton_method(Hive::TaskActivity::Operation, :open!, replacement) do
        capped = activity.reconcile_operations!(max_receipts: 1) { :defer }
        assert_includes capped.fetch("diagnostics").filter_map { |row| row["cap"] },
                        "operation_receipts"
      end

      huge = ReconcileOperation.new(status: :defer, bytes: 100)
      with_replaced_singleton_method(
        Hive::TaskActivity::Operation, :open!, ->(**) { huge }
      ) do
        capped = activity.reconcile_operations!(max_bytes: 1) { :defer }
        assert_includes capped.fetch("diagnostics").filter_map { |row| row["cap"] },
                        "operation_receipt_bytes"
      end
    end
  end

  def test_operation_conflicts_retry_limits_open_guards_and_validation
    with_tmp_dir do |root|
      activity = FakeActivity.new(root)
      receipt = valid_receipt

      aborted = Object.new
      aborted.define_singleton_method(:receipt) { { "state" => "aborted" } }
      aborted.define_singleton_method(:same_domain_intent?) { |_| false }
      with_operation_existing(aborted) do
        assert_raises(Hive::TaskActivity::Conflict) do
          Hive::TaskActivity::Operation.begin!(activity: activity, receipt: receipt)
        end
      end

      conflicting = Object.new
      conflicting.define_singleton_method(:receipt) { { "state" => "complete" } }
      conflicting.define_singleton_method(:same_intent?) { |_| false }
      with_operation_existing(conflicting) do
        assert_raises(Hive::TaskActivity::Conflict) do
          Hive::TaskActivity::Operation.begin!(activity: activity, receipt: receipt)
        end
      end
      conflicting.define_singleton_method(:same_intent?) { |_| true }
      with_operation_existing(conflicting) do
        assert_same conflicting,
                    Hive::TaskActivity::Operation.begin!(activity: activity, receipt: receipt)
      end

      retry_operation = Object.new
      retry_operation.define_singleton_method(:receipt) { { "state" => "aborted" } }
      retry_operation.define_singleton_method(:same_intent?) { |_| true }
      with_replaced_singleton_method(File, :exist?, ->(*) { true }) do
        with_replaced_singleton_method(
          Hive::TaskActivity::Operation, :open!, ->(**) { retry_operation }
        ) do
          assert_raises(Hive::TaskActivity::Conflict) do
            Hive::TaskActivity::Operation.begin_retry!(activity: activity, receipt: receipt)
          end
        end
      end

      conflicting_retry = Object.new
      conflicting_retry.define_singleton_method(:receipt) { { "state" => "complete" } }
      conflicting_retry.define_singleton_method(:same_intent?) { |_| false }
      with_replaced_singleton_method(File, :exist?, ->(*) { true }) do
        with_replaced_singleton_method(
          Hive::TaskActivity::Operation, :open!, ->(**) { conflicting_retry }
        ) do
          assert_raises(Hive::TaskActivity::Conflict) do
            Hive::TaskActivity::Operation.begin_retry!(activity: activity, receipt: receipt)
          end
        end
      end

      assert_raises(Hive::TaskActivity::InvalidActivity) do
        Hive::TaskActivity::Operation.open!(activity: activity, filename: "bad")
      end
      filename = "#{'a' * 64}.json"
      path = File.join(root, Hive::TaskActivity::OPERATION_DIRECTORY, filename)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(receipt))
      observed = File.lstat(path)
      changed = Struct.new(:file?, :dev, :ino).new(true, observed.dev, observed.ino + 1)
      fake = Object.new
      fake.define_singleton_method(:stat) { changed }
      with_replaced_singleton_method(File, :open, ->(*, &block) { block.call(fake) }) do
        assert_raises(Hive::TaskActivity::InvalidActivity) do
          Hive::TaskActivity::Operation.open!(activity: activity, filename: filename)
        end
      end
      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ELOOP }) do
        assert_raises(Hive::TaskActivity::InvalidActivity) do
          Hive::TaskActivity::Operation.open!(activity: activity, filename: filename)
        end
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        Hive::TaskActivity::Operation.open!(activity: activity, filename: filename)
      end

      operation = Hive::TaskActivity::Operation.new(activity: activity, receipt: receipt)
      refute operation.reconcile!
      operation.receipt["state"] = "committed_pending_activity"
      operation.define_singleton_method(:replay!) { true }
      assert operation.reconcile!
      operation.relocate!(File.join(root, "moved"))
      assert_equal File.join(root, "moved"), operation.instance_variable_get(:@activity).task_folder
      assert_raises(Hive::TaskActivity::InvalidActivity) { operation.send(:normalize_time, "bad") }

      invalid_receipts(receipt).each do |invalid|
        assert_raises(Hive::TaskActivity::InvalidActivity) do
          Hive::TaskActivity::Operation.new(activity: activity, receipt: invalid)
        end
      end
    end
  end

  private

  def build_activity(root, writer: Writer.new(Object.new))
    Hive::TaskActivity.new(
      task_folder: root, task: { id: 1, slug: "task" }, workflow: "coding",
      stage: "4-execute", attempt_id: "attempt", task_generation: 1,
      writer: writer, clock: -> { NOW }
    )
  end

  def valid_receipt
    {
      "schema" => Hive::TaskActivity::OPERATION_SCHEMA,
      "schema_version" => Hive::TaskActivity::OPERATION_SCHEMA_VERSION,
      "operation_id" => "operation", "activity_kind" => "answer_recorded",
      "source" => "command_service", "reason" => "recorded",
      "task" => { "id" => "1", "slug" => "task" }, "workflow" => "coding",
      "stage" => "4-execute", "attempt_id" => "attempt", "task_generation" => 1,
      "ownership_generation" => nil, "commit_generation" => nil,
      "precondition_fingerprint" => "a" * 64,
      "expected_postcondition_fingerprint" => "b" * 64,
      "state" => "pending", "created_at" => NOW.iso8601(6)
    }
  end

  def invalid_receipts(receipt)
    [
      receipt.merge("schema" => "wrong"),
      receipt.merge("operation_id" => "bad id"),
      receipt.merge("record_correlation_id" => "bad id"),
      receipt.merge("activity_kind" => "wrong"),
      receipt.merge("state" => "wrong"),
      receipt.merge("precondition_fingerprint" => "wrong"),
      receipt.merge("stage" => "other")
    ]
  end

  def with_operation_existing(existing)
    with_replaced_singleton_method(File, :exist?, ->(*) { true }) do
      with_replaced_singleton_method(
        Hive::TaskActivity::Operation, :open!, ->(**) { existing }
      ) { yield }
    end
  end
end
