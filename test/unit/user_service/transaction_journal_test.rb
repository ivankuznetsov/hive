require "test_helper"
require "hive/user_service/definition"
require "hive/user_service/transaction_journal"

class UserServiceTransactionJournalTest < Minitest::Test
  include HiveTestHelper

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

  def test_read_and_delete_translate_unsafe_storage
    journal = fake_journal(
      reader: -> { raise Hive::ManagedDirectory::UnsafeError, "unsafe" },
      unlinker: ->(*) { raise Hive::ManagedDirectory::UnsafeError, "unsafe" }
    )

    read_error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.read }
    delete_error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.delete }

    assert_match(/unsafe user-service transition journal/, read_error.message)
    assert_match(/unsafe user-service transition journal/, delete_error.message)
  end

  def test_advance_rejects_a_non_forward_transition
    journal = fake_journal(writer: ->(*) { nil })
    document = prepared_document(journal)

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.advance(document, phase: :committed)
    end

    assert_match(/invalid user-service transition/, error.message)
  end

  def test_prior_content_translates_a_non_string_payload
    encoded = Object.new
    encoded.define_singleton_method(:match?) { |_pattern| true }
    journal = fake_journal

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.prior_content("prior_content" => encoded)
    end

    assert_match(/invalid user-service transition prior content/, error.message)
  end

  def test_read_rejects_invalid_boolean_optional_and_manager_intent_fields
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    mutations = [
      [ "prior_enabled", "yes", /booleans are invalid/ ],
      [ "prior_digest", 123, /prior_digest is invalid/ ],
      [ "manager_intent", "reload", /manager intent is invalid/ ]
    ]

    mutations.each do |field, value, message|
      document = base.merge(field => value)
      journal = fake_journal(
        reader: -> { { bytes: JSON.generate(document), mode: 0o600 } }
      )

      error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.read }
      assert_match message, error.message
    end
  end

  def test_read_rejects_prior_content_that_does_not_match_its_digest
    document = prepared_document(fake_journal(writer: ->(*) { nil })).merge(
      "prior_content" => "legacy\n".unpack1("H*"),
      "prior_digest" => "b" * 64
    )
    journal = readable_journal(document)

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.read }

    assert_match(/prior content does not match digest/, error.message)
  end

  def test_read_rejects_apply_desired_digest_that_does_not_match_definition
    document = prepared_document(fake_journal(writer: ->(*) { nil })).merge(
      "desired_digest" => "b" * 64
    )
    journal = readable_journal(document)

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.read }

    assert_match(/desired digest does not match/, error.message)
  end

  def test_read_rejects_foreign_backup_path_and_invalid_result_kind
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    prior = "legacy\n"
    upgraded = base.merge(
      "prior_content" => prior.unpack1("H*"),
      "prior_digest" => Digest::SHA256.hexdigest(prior),
      "result_kind" => "upgraded"
    )
    mutations = [
      [ upgraded.merge("backup_path" => "/tmp/other.service.bak-20260830T120000Z"), /backup path is invalid/ ],
      [ base.merge("result_kind" => "removed"), /result kind is invalid/ ]
    ]

    mutations.each do |document, message|
      error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        readable_journal(document).read
      end
      assert_match message, error.message
    end
  end

  def test_fixed_clock_backup_disambiguators_remain_bound_to_the_target
    prior = "legacy\n"
    journal = fake_journal(writer: ->(*) { nil })
    document = journal.prepare(
      operation: :apply,
      prior_content: prior,
      prior_digest: Digest::SHA256.hexdigest(prior),
      prior_enabled: true,
      prior_running: true,
      desired_digest: Digest::SHA256.hexdigest(definition.content),
      backup_path: "#{definition.target_path}.bak-20260830T120000Z-10",
      manager_intent: :restart,
      result_kind: :upgraded,
      autostart: true
    )

    assert_equal "#{definition.target_path}.bak-20260830T120000Z-10", document.fetch("backup_path")
  end

  def test_read_rejects_operation_specific_manager_intent_and_phase_combinations
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    invalid = [
      base.merge("manager_intent" => "disable"),
      base.merge("phase" => "takeover_completed", "manager_intent" => "enable"),
      base.merge("operation" => "remove", "phase" => "removal_prepared",
                 "desired_digest" => nil, "manager_intent" => "enable",
                 "result_kind" => "removed")
    ]

    invalid.each do |document|
      assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        readable_journal(document).read
      end
    end
  end

  def test_lifecycle_document_carries_process_identity_and_has_a_strict_phase_ladder
    journal = fake_journal(writer: ->(*) { nil })
    digest = Digest::SHA256.hexdigest("desired\n")
    document = journal.prepare(
      operation: :lifecycle,
      prior_content: nil,
      prior_digest: digest,
      prior_enabled: true,
      prior_running: true,
      desired_digest: digest,
      backup_path: nil,
      manager_intent: :restart,
      result_kind: :unchanged,
      autostart: true,
      prior_main_pid: 123,
      prior_process_start: "456"
    )

    assert_equal 123, document.fetch("prior_main_pid")
    assert_equal "456", document.fetch("prior_process_start")
    assert_equal "lifecycle_prepared", document.fetch("phase")
    document = journal.advance(document, phase: :lifecycle_acted)
    document = journal.advance(document, phase: :lifecycle_verified)
    document = journal.advance(document, phase: :lifecycle_committed)
    assert_equal "lifecycle_committed", document.fetch("phase")
    assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.advance(document, phase: :lifecycle_acted)
    end
  end

  def test_remove_accepts_absent_file_and_conclusively_absent_manager_evidence
    journal = fake_journal(writer: ->(*) { nil })
    document = journal.prepare(
      operation: :remove,
      prior_content: nil,
      prior_digest: nil,
      prior_enabled: false,
      prior_running: false,
      desired_digest: nil,
      backup_path: nil,
      manager_intent: nil,
      result_kind: :absent,
      autostart: true
    )

    assert_equal "removal_prepared", document.fetch("phase")
  end

  def test_process_identity_fields_must_be_coherent
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    invalid = [
      base.merge("prior_main_pid" => -1),
      base.merge("prior_main_pid" => 0, "prior_process_start" => "123"),
      base.merge("prior_main_pid" => 123, "prior_process_start" => nil)
    ]

    invalid.each do |document|
      assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        readable_journal(document).read
      end
    end
  end

  def test_read_rejects_a_committed_apply_whose_target_is_still_prior
    document = prepared_document(fake_journal(writer: ->(*) { nil })).merge(
      "phase" => "committed"
    )

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      readable_journal(document).read
    end

    assert_match(/target observation conflicts with phase/, error.message)
  end

  def test_delete_preserves_invalid_journal_evidence
    unlinked = false
    document = prepared_document(fake_journal(writer: ->(*) { nil })).merge(
      "phase" => "committed"
    )
    journal = fake_journal(
      reader: -> { { bytes: JSON.generate(document), mode: 0o600 } },
      unlinker: ->(*) { unlinked = true }
    )

    assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.delete }
    refute unlinked
  end

  def test_prepare_does_not_overwrite_existing_transition_evidence
    existing = prepared_document(fake_journal(writer: ->(*) { nil }))
    journal = fake_journal(
      reader: -> { { bytes: JSON.generate(existing), mode: 0o600 } },
      writer: ->(*) { flunk "existing transition must not be overwritten" }
    )

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      prepared_document(journal)
    end

    assert_match(/already exists/, error.message)
  end

  def test_advance_translates_storage_binding_failures
    journal = fake_journal(
      writer: ->(*) { raise Hive::ManagedDirectory::UnsafeError, "changed" }
    )
    document = prepared_document(fake_journal(writer: ->(*) { nil }))

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.advance(document, phase: :backup_stored)
    end

    assert_match(/unsafe user-service transition journal/, error.message)
  end

  def test_read_rejects_a_pathname_swap_after_the_target_descriptor_is_opened
    with_tmp_dir do |dir|
      target = File.join(dir, "hive-test.service")
      File.write(target, "desired\n")
      local_definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: target,
        content: "desired\n"
      )
      document = nil
      writer = lambda do |_name, bytes, **_kwargs|
        document = JSON.parse(bytes)
      end
      directory = FakeDirectory.new(dir, nil, writer, nil)
      journal = Hive::UserService::TransactionJournal.new(
        directory: directory,
        name: "journal.json",
        definition: local_definition,
        clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
      )
      journal.prepare(
        operation: :apply,
        prior_content: nil,
        prior_digest: nil,
        prior_enabled: false,
        prior_running: false,
        desired_digest: Digest::SHA256.hexdigest("desired\n"),
        backup_path: nil,
        manager_intent: :enable,
        result_kind: :written,
        autostart: true
      )
      directory.reader = -> { { bytes: JSON.generate(document), mode: 0o600 } }

      original = File.method(:lstat)
      swapped = false
      error = with_replaced_singleton_method(
        File,
        :lstat,
        lambda do |path|
          if path == target && !swapped
            swapped = true
            File.rename(target, "#{target}.opened")
            File.write(target, "alien\n")
          end
          original.call(path)
        end
      ) do
        assert_raises(Hive::UserService::TransactionJournal::Invalid) { journal.read }
      end

      assert_match(/pathname changed/, error.message)
      assert_equal "alien\n", File.read(target)
    end
  end

  private

  def prepared_document(journal)
    journal.prepare(
      operation: :apply,
      prior_content: nil,
      prior_digest: nil,
      prior_enabled: false,
      prior_running: false,
      desired_digest: Digest::SHA256.hexdigest(definition.content),
      backup_path: nil,
      manager_intent: :enable,
      result_kind: :written,
      autostart: true
    )
  end

  def readable_journal(document)
    fake_journal(reader: -> { { bytes: JSON.generate(document), mode: 0o600 } })
  end

  def fake_journal(reader: nil, writer: nil, unlinker: nil)
    directory = FakeDirectory.new("/tmp/user-service-journal", reader, writer, unlinker)
    Hive::UserService::TransactionJournal.new(
      directory: directory,
      name: "journal.json",
      definition: definition,
      clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    )
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
