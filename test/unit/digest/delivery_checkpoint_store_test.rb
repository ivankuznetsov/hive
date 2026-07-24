require "test_helper"
require "digest"
require "fileutils"
require "json"
require "hive/digest/delivery_checkpoint_store"

class HiveDigestDeliveryCheckpointStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 24, 12, 0, 0)

  def test_rejects_noncanonical_date_before_creating_state
    with_tmp_dir do |dir|
      [ "2026-7-23", "20260723" ].each do |value|
        error = assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
          store(dir).synchronize(value) { flunk "must not yield" }
        end

        assert_match(/must be YYYY-MM-DD/, error.message)
      end

      assert_empty Dir.children(dir)
    end
  end

  def test_lock_setup_failure_is_typed
    with_tmp_dir do |dir|
      root = File.join(dir, "not-a-directory")
      File.write(root, "occupied")

      error = assert_raises(Hive::Digest::DeliveryCheckpointError) do
        store(root).synchronize("2026-07-23") { flunk "must not yield" }
      end

      assert_match(/cannot lock delivery checkpoint/, error.message)
    end
  end

  def test_malformed_and_wrong_identity_checkpoints_fail_closed
    with_tmp_dir do |dir|
      File.write(File.join(dir, "2026-07-23.json"), "{broken")
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end

      File.write(File.join(dir, "2026-07-23.json"), JSON.generate({}))
      error = assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end
      assert_match(/invalid delivery checkpoint identity/, error.message)
    end
  end

  def test_corrupt_payload_progress_and_permanent_failure_are_rejected
    with_tmp_dir do |dir|
      path = File.join(dir, "2026-07-23.json")
      checkpoint = valid_checkpoint
      checkpoint["payload_sha256"] = "wrong"
      File.write(path, JSON.generate(checkpoint))
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end

      checkpoint = valid_checkpoint.merge(
        "permanent_failure" => { "error_class" => "", "message" => "" }
      )
      File.write(path, JSON.generate(checkpoint))
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end
    end
  end

  def test_create_and_private_write_wrap_invalid_state
    with_tmp_dir do |dir|
      checkpoint_store = store(dir)
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        checkpoint_store.create(
          key: "2026-07-23", chat_id: 123, payload: "body", chunks: []
        )
      end

      error = assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        checkpoint_store.send(:write, {})
      end
      assert_match(/cannot persist valid delivery checkpoint/, error.message)
    end
  end

  def test_attempt_fallback_rejection_and_acceptance_are_durable
    with_tmp_dir do |dir|
      checkpoint_store = store(dir)
      checkpoint = checkpoint_store.create(
        key: "2026-07-23",
        chat_id: 123,
        payload: "*body*",
        chunks: [ "*body*" ]
      )
      checkpoint = checkpoint_store.begin_attempt(
        checkpoint,
        chunk_index: 0,
        payload: "*body*",
        parse_mode: :markdown_v2
      )
      assert_equal "markdown_v2", checkpoint.dig("in_flight", "parse_mode")

      checkpoint = checkpoint_store.prepare_fallback(
        checkpoint,
        chunk_index: 0,
        payload: "<b>body</b>"
      )
      refute checkpoint.key?("in_flight")
      assert_equal "html", checkpoint.dig("pending_variant", "parse_mode")

      checkpoint = checkpoint_store.begin_attempt(
        checkpoint,
        chunk_index: 0,
        payload: "<b>body</b>",
        parse_mode: :html
      )
      checkpoint = checkpoint_store.reject_attempt(checkpoint)
      refute checkpoint.key?("in_flight")
      assert_equal "<b>body</b>", checkpoint.dig("pending_variant", "payload")

      checkpoint = checkpoint_store.begin_attempt(
        checkpoint,
        chunk_index: 0,
        payload: "<b>body</b>",
        parse_mode: :html
      )
      checkpoint = checkpoint_store.accept(checkpoint, next_chunk: 1)
      assert_equal 1, checkpoint.fetch("next_chunk")
      refute checkpoint.key?("in_flight")
      refute checkpoint.key?("pending_variant")
      assert checkpoint.key?("completed_at")
    end
  end

  def test_begin_attempt_refuses_to_overwrite_an_in_flight_unit
    with_tmp_dir do |dir|
      checkpoint_store = store(dir)
      checkpoint = checkpoint_store.create(
        key: "2026-07-23",
        chat_id: 123,
        payload: "body",
        chunks: [ "body" ]
      )
      checkpoint = checkpoint_store.begin_attempt(
        checkpoint,
        chunk_index: 0,
        payload: "body",
        parse_mode: :markdown_v2
      )

      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        checkpoint_store.begin_attempt(
          checkpoint,
          chunk_index: 0,
          payload: "body",
          parse_mode: :markdown_v2
        )
      end
    end
  end

  def test_completed_or_non_html_variant_delivery_state_is_rejected
    with_tmp_dir do |dir|
      checkpoint_store = store(dir)
      completed_with_attempt = valid_checkpoint.merge(
        "next_chunk" => 1,
        "in_flight" => delivery_unit("body", "markdown_v2")
      )
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        checkpoint_store.send(
          :validate!, completed_with_attempt, expected_date: "2026-07-23"
        )
      end

      markdown_variant = valid_checkpoint.merge(
        "pending_variant" => delivery_unit("body", "markdown_v2")
      )
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        checkpoint_store.send(
          :validate!, markdown_variant, expected_date: "2026-07-23"
        )
      end
    end
  end

  def test_existing_checkpoint_read_system_failure_is_retryable
    with_tmp_dir do |dir|
      checkpoint_store = store(dir)
      checkpoint_store.create(
        key: "2026-07-23",
        chat_id: 123,
        payload: "body",
        chunks: [ "body" ]
      )

      original_read = File.method(:read)
      File.define_singleton_method(:read) do |*|
        raise Errno::EIO, "simulated read failure"
      end
      error = begin
        assert_raises(Hive::Digest::DeliveryCheckpointError) do
          checkpoint_store.load("2026-07-23")
        end
      ensure
        File.define_singleton_method(:read, original_read)
      end
      assert_match(/unreadable delivery checkpoint/, error.message)
    end
  end

  def test_corrupt_chunk_and_delivery_state_checksums_fail_closed
    with_tmp_dir do |dir|
      path = File.join(dir, "2026-07-23.json")
      checkpoint = valid_checkpoint
      checkpoint["chunks"] = [ "tampered" ]
      File.write(path, JSON.generate(checkpoint))
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end

      checkpoint = valid_checkpoint.merge(
        "in_flight" => {
          "chunk_index" => 0,
          "payload" => "different",
          "payload_sha256" => Digest::SHA256.hexdigest("different"),
          "parse_mode" => "markdown_v2"
        }
      )
      File.write(path, JSON.generate(checkpoint))
      assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
        store(dir).load("2026-07-23")
      end
    end
  end

  def test_pre_send_checkpoint_write_system_failure_is_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "2026-07-23.json"))

      error = assert_raises(Hive::Digest::DeliveryCheckpointError) do
        store(dir).create(
          key: "2026-07-23", chat_id: 123, payload: "body", chunks: [ "body" ]
        )
      end
      assert_match(/cannot persist delivery checkpoint/, error.message)
    end
  end

  private

  def store(root)
    Hive::Digest::DeliveryCheckpointStore.new(root: root, clock: -> { NOW })
  end

  def valid_checkpoint
    {
      "schema" => Hive::Digest::DeliveryCheckpointStore::SCHEMA,
      "schema_version" => Hive::Digest::DeliveryCheckpointStore::SCHEMA_VERSION,
      "digest_date" => "2026-07-23",
      "chat_id" => 123,
      "payload" => "body",
      "payload_sha256" => Digest::SHA256.hexdigest("body"),
      "chunks" => [ "body" ],
      "chunks_sha256" => Digest::SHA256.hexdigest(JSON.generate([ "body" ])),
      "next_chunk" => 0,
      "total_chunks" => 1,
      "created_at" => NOW.iso8601,
      "updated_at" => NOW.iso8601
    }
  end

  def delivery_unit(payload, parse_mode)
    {
      "chunk_index" => 0,
      "payload" => payload,
      "payload_sha256" => Digest::SHA256.hexdigest(payload),
      "parse_mode" => parse_mode
    }
  end
end
