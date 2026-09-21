require "test_helper"
require "hive/user_service/definition"
require "hive/user_service/applied_receipt"

class UserServiceAppliedReceiptTest < Minitest::Test
  FakeDirectory = Struct.new(:root, :reader, :writer, :unlinker) do
    def read_with_metadata(*, **)
      reader&.call
    end

    def atomic_write(*args, **kwargs)
      writer&.call(*args, **kwargs)
    end

    def unlink(*args, **kwargs)
      unlinker&.call(*args, **kwargs)
    end
  end

  def test_read_translates_malformed_and_unsafe_storage
    malformed = fake_receipt(
      reader: -> { { bytes: "{not-json", mode: 0o600 } }
    )
    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) { malformed.read }
    assert_match(/invalid user-service receipt/, error.message)

    unsafe = fake_receipt(
      reader: -> { raise Hive::ManagedDirectory::UnsafeError, "unsafe" }
    )
    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) { unsafe.read }
    assert_match(/unsafe user-service receipt/, error.message)
  end

  def test_delete_translates_unsafe_storage
    receipt = fake_receipt(
      unlinker: ->(*) { raise Hive::ManagedDirectory::UnsafeError, "unsafe" }
    )

    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) { receipt.delete }

    assert_match(/unsafe user-service receipt/, error.message)
  end

  def test_write_rejects_an_invalid_digest
    receipt = fake_receipt(writer: ->(*) { flunk "invalid receipt must not be published" })

    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) do
      receipt.write(digest: "not-a-digest", mode: :managed, manager_intent: :enable)
    end

    assert_match(/receipt digest is invalid/, error.message)
  end

  def test_write_rejects_digest_that_does_not_match_the_definition
    receipt = fake_receipt(writer: ->(*) { flunk "foreign receipt must not be published" })

    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) do
      receipt.write(digest: "b" * 64, mode: :managed, manager_intent: :enable)
    end

    assert_match(/receipt digest does not match/, error.message)
  end

  def test_write_translates_malformed_existing_and_unsafe_publication
    malformed = fake_receipt(
      reader: -> { { bytes: "{not-json", mode: 0o600 } },
      writer: ->(*) { flunk "malformed evidence must not be overwritten" }
    )
    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) do
      malformed.write(
        digest: Digest::SHA256.hexdigest(definition.content),
        mode: :managed,
        manager_intent: :enable
      )
    end
    assert_match(/invalid user-service receipt/, error.message)

    unsafe = fake_receipt(
      writer: ->(*) { raise Hive::ManagedDirectory::UnsafeError, "changed" }
    )
    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) do
      unsafe.write(
        digest: Digest::SHA256.hexdigest(definition.content),
        mode: :managed,
        manager_intent: :enable
      )
    end
    assert_match(/unsafe user-service receipt/, error.message)
  end

  def test_read_accepts_a_valid_receipt_for_a_prior_definition
    document = valid_document.merge("desired_digest" => "b" * 64)
    receipt = fake_receipt(reader: -> { { bytes: JSON.generate(document), mode: 0o600 } })

    assert_equal "b" * 64, receipt.read.fetch("desired_digest")
  end

  def test_read_rejects_mode_specific_manager_intent_and_invalid_timestamp
    invalid = [
      valid_document.merge("mode" => "managed", "manager_intent" => nil),
      valid_document.merge("mode" => "no_autostart", "manager_intent" => "enable"),
      valid_document.merge("mode" => "unsupported_autostart", "manager_intent" => "restart"),
      valid_document.merge("verified_at" => "not-a-time")
    ]

    invalid.each do |document|
      receipt = fake_receipt(reader: -> { { bytes: JSON.generate(document), mode: 0o600 } })
      assert_raises(Hive::UserService::AppliedReceipt::Invalid) { receipt.read }
    end
  end

  def test_delete_preserves_invalid_receipt_evidence
    unlinked = false
    document = valid_document.merge("verified_at" => "not-a-time")
    receipt = fake_receipt(
      reader: -> { { bytes: JSON.generate(document), mode: 0o600 } },
      unlinker: ->(*) { unlinked = true }
    )

    assert_raises(Hive::UserService::AppliedReceipt::Invalid) { receipt.delete }
    refute unlinked
  end

  def test_delete_compare_binds_valid_evidence_and_translates_malformed_json
    deleted = nil
    bytes = JSON.generate(valid_document)
    receipt = fake_receipt(
      reader: -> { { bytes: bytes, mode: 0o600 } },
      unlinker: ->(*args, **kwargs) { deleted = [ args, kwargs ]; true }
    )

    assert receipt.delete
    assert_equal [ "receipt.json" ], deleted.first
    assert_equal Digest::SHA256.hexdigest(bytes), deleted.last.fetch(:expected_digest)

    malformed = fake_receipt(
      reader: -> { { bytes: "{not-json", mode: 0o600 } },
      unlinker: ->(*) { flunk "malformed evidence must be preserved" }
    )
    error = assert_raises(Hive::UserService::AppliedReceipt::Invalid) { malformed.delete }
    assert_match(/invalid user-service receipt/, error.message)
  end

  private

  def fake_receipt(reader: nil, writer: nil, unlinker: nil)
    directory = FakeDirectory.new("/tmp/user-service-receipt", reader, writer, unlinker)
    Hive::UserService::AppliedReceipt.new(
      directory: directory,
      name: "receipt.json",
      definition: definition,
      clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    )
  end

  def valid_document
    {
      "schema" => Hive::UserService::AppliedReceipt::SCHEMA,
      "schema_version" => Hive::UserService::AppliedReceipt::VERSION,
      "service_name" => definition.service_name,
      "platform" => definition.platform.to_s,
      "target_path" => definition.target_path,
      "desired_digest" => Digest::SHA256.hexdigest(definition.content),
      "mode" => "managed",
      "manager_intent" => "enable",
      "verified_at" => "2026-08-30T12:00:00.000000Z"
    }
  end

  def definition
    Hive::UserService::Definition.new(
      platform: :linux,
      service_name: "hive-test",
      target_path: "/tmp/hive-test.service",
      content: "desired\n"
    )
  end
end
