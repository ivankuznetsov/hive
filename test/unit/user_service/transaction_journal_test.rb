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

  def test_activation_recorded_only_after_the_activation_boundary
    journal = fake_journal(writer: ->(*) { nil })
    prepared = prepared_document(journal)

    refute journal.activation_recorded?(prepared)
    assert journal.activation_recorded?(prepared.merge("phase" => "activated"))
    refute journal.activation_recorded?(prepared.merge("direction" => "rollback"))
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

    malformed = fake_journal(
      reader: -> { { bytes: "{not-json", mode: 0o600 } },
      unlinker: ->(*) { flunk "malformed evidence must be preserved" }
    )
    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) { malformed.delete }
    assert_match(/invalid user-service transition journal/, error.message)
  end

  def test_prepare_rejects_an_unknown_operation_before_publication
    journal = fake_journal(writer: ->(*) { flunk "invalid operation must not be written" })

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.prepare(
        operation: :bogus,
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
    end

    assert_match(/operation is invalid/, error.message)
  end

  def test_prior_state_process_and_timestamp_validation_is_exhaustive
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    prior = "legacy\n"
    prior_digest = Digest::SHA256.hexdigest(prior)
    invalid = [
      [ base.merge("prior_content" => "not-hex"), /prior content is invalid/ ],
      [ base.merge("prior_content" => prior.unpack1("H*")), /content and digest disagree/ ],
      [ base.merge("prior_digest" => prior_digest), /content and digest disagree/ ],
      [ base.merge("prior_process_start" => 123), /process start is invalid/ ],
      [ base.merge("created_at" => "not-a-time"), /created_at is invalid/ ]
    ]

    invalid.each do |document, message|
      error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        readable_journal(document).read
      end
      assert_match message, error.message
    end

    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      fake_journal.send(:validate_operation!, base.merge("operation" => "bogus"))
    end
    assert_match(/operation is invalid/, error.message)
  end

  def test_operation_specific_invalid_endpoint_shapes_are_rejected
    base = prepared_document(fake_journal(writer: ->(*) { nil }))
    prior = "legacy\n"
    prior_digest = Digest::SHA256.hexdigest(prior)
    prior_fields = {
      "prior_content" => prior.unpack1("H*"),
      "prior_digest" => prior_digest
    }
    remove = base.merge(
      "operation" => "remove",
      "direction" => "forward",
      "phase" => "removal_prepared",
      "desired_digest" => nil,
      "backup_path" => nil,
      "manager_intent" => "disable",
      "result_kind" => "removed",
      "autostart" => true
    )
    lifecycle = base.merge(
      "operation" => "lifecycle",
      "direction" => "forward",
      "phase" => "lifecycle_prepared",
      "desired_digest" => "not-a-digest",
      "backup_path" => nil,
      "manager_intent" => "restart",
      "result_kind" => "unchanged",
      "autostart" => true
    )
    invalid = [
      base.merge("autostart" => false, "manager_intent" => "enable"),
      base.merge("phase" => "manager_reloaded", "manager_intent" => nil),
      base.merge("backup_path" => "#{definition.target_path}.bak-20260830T120000Z"),
      base.merge(prior_fields).merge("result_kind" => "written"),
      base.merge("result_kind" => "unchanged"),
      remove,
      remove.merge(prior_fields).merge("result_kind" => "absent"),
      lifecycle
    ]

    invalid.each do |document|
      assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        readable_journal(document).read
      end
    end

    refute fake_journal.send(:valid_backup_path?, "\0")
  end

  def test_target_observation_rejects_unknown_unsafe_changing_and_unreadable_targets
    journal = fake_journal
    error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
      journal.send(
        :validate_target_observation!,
        "operation" => "bogus", "direction" => "forward"
      )
    end
    assert_match(/conflicts with phase/, error.message)

    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      Dir.mkdir(target)
      local_definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: target,
        content: "desired\n"
      )
      local = Hive::UserService::TransactionJournal.new(
        directory: FakeDirectory.new(dir, nil, nil, nil),
        name: "journal.json",
        definition: local_definition
      )
      error = assert_raises(Hive::UserService::TransactionJournal::Invalid) do
        local.send(:observed_target_digest)
      end
      assert_match(/target is unsafe/, error.message)

      FileUtils.rm_rf(target)
      File.write(target, "desired\n")
      first = File.stat(target)
      changed = first.dup
      changed.define_singleton_method(:size) { first.size + 1 }
      fake_file = Object.new
      observations = [ first, changed ]
      fake_file.define_singleton_method(:stat) { observations.shift || changed }
      fake_file.define_singleton_method(:read) { |_size| "desired\n" }
      original = File.method(:open)
      error = with_replaced_singleton_method(
        File,
        :open,
        lambda do |path, *args, &block|
          if path == target
            block.call(fake_file)
          else
            original.call(path, *args, &block)
          end
        end
      ) do
        assert_raises(Hive::UserService::TransactionJournal::Invalid) do
          local.send(:observed_target_digest)
        end
      end
      assert_match(/changed during observation/, error.message)

      error = with_replaced_singleton_method(
        File,
        :open,
        ->(path, *) { (path == target) ? (raise Errno::EACCES) : original.call(path) }
      ) do
        assert_raises(Hive::UserService::TransactionJournal::Invalid) do
          local.send(:observed_target_digest)
        end
      end
      assert_match(/target is unsafe/, error.message)
    end
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
