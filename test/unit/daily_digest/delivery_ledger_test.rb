require "test_helper"
require "hive/daily_digest/delivery_ledger"

class DailyDigestDeliveryLedgerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.iso8601("2026-08-31T09:00:00Z")

  def test_records_send_lifecycle_and_deduplicates_success
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      prepared = ledger.prepare(**identity, now: NOW)

      assert_equal :send, prepared.action
      assert_equal "prepared", prepared.receipt.fetch("outcome")
      sending = ledger.mark_sending(DATE, attempt: 1, now: NOW + 1)
      assert_equal "sending", sending.fetch("outcome")
      sent = ledger.mark_sent(DATE, attempt: 1, now: NOW + 2)
      assert_equal "sent", sent.fetch("outcome")

      duplicate = ledger.prepare(**identity, now: NOW + 3)
      assert_equal :duplicate, duplicate.action
      assert_equal 1, duplicate.receipt.fetch("attempt")
      assert_equal 0o600, File.stat(File.join(dir, "deliveries", "#{DATE}.json")).mode & 0o777
      assert_equal 0o700, File.stat(File.join(dir, "deliveries")).mode & 0o777
      refute_includes File.read(File.join(dir, "deliveries", "#{DATE}.json")), "message body"
    end
  end

  def test_interrupted_send_becomes_unknown_and_only_explicit_retry_rearms_it
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(
        root: File.join(dir, "deliveries"), process_alive: ->(_pid, _start) { false }
      )
      ledger.prepare(**identity, now: NOW)
      ledger.mark_sending(DATE, attempt: 1, now: NOW + 1)

      recovered = ledger.prepare(**identity, now: NOW + 2)
      assert_equal :unknown, recovered.action
      assert_equal "interrupted_send", recovered.receipt.fetch("reason_code")

      retrying = ledger.prepare(**identity, now: NOW + 3, retry_requested: true)
      assert_equal :send, retrying.action
      assert_equal 2, retrying.receipt.fetch("attempt")
      assert_equal true, retrying.receipt.fetch("operator_retry")
    end
  end

  def test_live_sender_remains_in_flight_and_can_commit_success
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(
        root: File.join(dir, "deliveries"),
        process_identity: -> { [ 321, "start-321" ] },
        process_alive: ->(pid, start) { pid == 321 && start == "start-321" }
      )
      ledger.prepare(**identity, now: NOW)
      ledger.mark_sending(DATE, attempt: 1, now: NOW + 1)

      concurrent = ledger.prepare(**identity, now: NOW + 2)

      assert_equal :in_flight, concurrent.action
      assert_equal "sending", concurrent.receipt.fetch("outcome")
      assert_equal 321, concurrent.receipt.fetch("sender_pid")
      assert_equal "start-321", concurrent.receipt.fetch("sender_process_start_time")
      assert_equal "sent", ledger.mark_sent(DATE, attempt: 1, now: NOW + 3).fetch("outcome")
    end
  end

  def test_prepared_intent_resumes_the_same_attempt
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      first = ledger.prepare(**identity, now: NOW)
      resumed = ledger.prepare(**identity, now: NOW + 1)

      assert_equal :send, resumed.action
      assert_equal first.receipt.fetch("receipt_id"), resumed.receipt.fetch("receipt_id")
      assert_equal 1, resumed.receipt.fetch("attempt")
      assert_equal 1, resumed.receipt.fetch("history").length
    end
  end

  def test_definite_failures_retry_to_a_bound_then_require_operator_intent
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      3.times do |index|
        preparation = ledger.prepare(**identity, now: NOW + (index * 3))
        assert_equal :send, preparation.action
        attempt = preparation.receipt.fetch("attempt")
        ledger.mark_sending(DATE, attempt: attempt, now: NOW + (index * 3) + 1)
        ledger.mark_failed(
          DATE, attempt: attempt, now: NOW + (index * 3) + 2,
          reason_code: "telegram_rejected"
        )
      end

      exhausted = ledger.prepare(**identity, now: NOW + 10)
      assert_equal :failed, exhausted.action
      assert_equal 3, exhausted.receipt.fetch("attempt")
      assert_equal :send,
                   ledger.prepare(**identity, now: NOW + 11, retry_requested: true).action
    end
  end

  def test_suppression_is_terminal_and_identity_conflicts_fail_loudly
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      prepared = ledger.prepare(**identity, now: NOW)
      suppressed = ledger.mark_suppressed(DATE, attempt: prepared.receipt.fetch("attempt"), now: NOW + 1)
      assert_equal "suppressed_empty", suppressed.fetch("outcome")
      assert_equal :duplicate, ledger.prepare(**identity, now: NOW + 2).action

      error = assert_raises(Hive::DailyDigest::DeliveryLedger::Conflict) do
        ledger.prepare(**identity.merge(record_id: "f" * 64), now: NOW + 3)
      end
      assert_match(/identity changed/, error.message)
    end
  end

  def test_rejects_stale_transitions_and_corrupt_receipts
    with_tmp_dir do |dir|
      root = File.join(dir, "deliveries")
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: root)
      prepared = ledger.prepare(**identity, now: NOW)
      assert_raises(Hive::DailyDigest::DeliveryLedger::InvalidTransition) do
        ledger.mark_sent(DATE, attempt: prepared.receipt.fetch("attempt"), now: NOW + 1)
      end

      File.write(File.join(root, "#{DATE}.json"), "{bad")
      assert_raises(Hive::DailyDigest::DeliveryLedger::Error) { ledger.read(DATE) }
    end
  end

  def test_transition_validation_rejects_unknown_outcomes_and_attempt_types
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      receipt = ledger.prepare(**identity, now: NOW).receipt
      assert_raises(Hive::DailyDigest::DeliveryLedger::InvalidTransition) do
        ledger.send(
          :transition_unlocked, receipt, attempt: 1, from: [ "prepared" ],
          to: "impossible", now: NOW
        )
      end
      assert_raises(Hive::DailyDigest::DeliveryLedger::InvalidTransition) do
        ledger.send(
          :transition_unlocked, receipt, attempt: Object.new, from: [ "prepared" ],
          to: "sending", now: NOW
        )
      end
    end
  end

  def test_invalid_receipt_shape_and_scalar_inputs_are_typed
    with_tmp_dir do |dir|
      root = File.join(dir, "deliveries")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "#{DATE}.json"), JSON.generate("not-an-object"))
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: root)
      assert_raises(Hive::DailyDigest::DeliveryLedger::Error) { ledger.read(DATE) }

      assert_raises(Hive::DailyDigest::DeliveryLedger::Error) { ledger.read("bad-date") }
      assert_raises(Hive::DailyDigest::DeliveryLedger::Error) do
        ledger.send(:normalize_time, "bad-time")
      end
      [ 0, "bad" ].each do |chat_id|
        assert_raises(Hive::DailyDigest::DeliveryLedger::Error) do
          ledger.send(:normalize_chat_id, chat_id)
        end
      end
    end
  end

  def test_symlinked_ledger_lock_is_rejected
    with_tmp_dir do |dir|
      root = File.join(dir, "deliveries")
      FileUtils.mkdir_p(root)
      target = File.join(dir, "lock-target")
      File.write(target, "")
      File.symlink(target, File.join(root, ".ledger.lock"))
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: root)

      assert_raises(Hive::DailyDigest::DeliveryLedger::Error) { ledger.read(DATE) }
    end
  end

  private

  DATE = "2026-08-30".freeze

  def identity
    {
      local_date: DATE, record_id: "a" * 64,
      amendment_frontier: "b" * 64, payload_hash: "c" * 64,
      destination_chat_id: 12_345
    }
  end
end
