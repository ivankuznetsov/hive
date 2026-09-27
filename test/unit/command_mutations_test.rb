# frozen_string_literal: true

require "test_helper"
require "hive/command_mutations"

class CommandMutationsTest < Minitest::Test
  include HiveTestHelper

  def test_catalog_freezes_supported_mutation_boundaries
    assert_equal(
      %w[act answer approve archive new receipt stage_action],
      Hive::CommandMutations::CATALOG.keys.sort
    )
    assert_equal %w[brainstorm plan develop open-pr review artifacts finalize archive],
                 Hive::CommandMutations::STAGE_VERBS
  end

  def test_answer_inventory_and_archive_listing_are_read_only
    refute Hive::CommandMutations.supported?(command: "answer", target: "task", options: {})
    assert Hive::CommandMutations.supported?(
      command: "answer", target: "task", options: { binding: "binding" }
    )
    refute Hive::CommandMutations.supported?(command: "archive", target: nil, options: {})
    assert Hive::CommandMutations.supported?(command: "archive", target: "task", options: {})
  end

  def test_only_prune_accepts_a_key_among_receipt_maintenance_modes
    assert_equal :optional,
                 Hive::CommandMutations.key_policy(command: "receipt", mode: "prune")
    %w[retire release-pin abandon-batch enroll].each do |mode|
      assert_equal :forbidden,
                   Hive::CommandMutations.key_policy(command: "receipt", mode: mode)
    end
  end

  def test_key_validation_uses_nonempty_utf8_and_a_512_byte_limit
    assert_equal "stable-key", Hive::CommandMutations.normalize_key("stable-key")

    [ "", "x" * 513, "\xFF".b ].each do |key|
      assert_raises(Hive::UsageError) { Hive::CommandMutations.normalize_key(key) }
    end
  end

  def test_display_only_options_do_not_change_request_fingerprint
    common = {
      command: "approve", namespace_id: "namespace", target: "task",
      principal: "local:1000", options: { from: "3-plan", force: false }
    }
    first = Hive::CommandMutations.fingerprint(**common.merge(display: { json: true, quiet: false }))
    second = Hive::CommandMutations.fingerprint(**common.merge(display: { json: false, quiet: true }))

    assert_equal first, second
    refute_equal first, Hive::CommandMutations.fingerprint(
      **common.merge(options: { from: "4-execute", force: false })
    )
  end

  def test_unknown_modes_cannot_claim_keyed_protection
    error = assert_raises(Hive::UsageError) do
      Hive::CommandMutations.descriptor(command: "receipt", mode: "redrive")
    end
    assert_includes error.message, "unsupported keyed mutation"
  end

  def test_keyed_validation_rejects_unsupported_and_forbidden_mutations
    assert_raises(Hive::UsageError) do
      Hive::CommandMutations.validate_keyed!(
        command: "archive", mode: nil, target: nil, options: {}
      )
    end
    assert_raises(Hive::UsageError) do
      Hive::CommandMutations.validate_keyed!(
        command: "receipt", mode: "retire", target: "receipt-1", options: {}
      )
    end

    descriptor = Hive::CommandMutations::Descriptor.new(
      command: "receipt", mode: "prune", key_policy: :optional, mutating: true,
      semantic_options: []
    )
    with_replaced_singleton_method(Hive::CommandMutations, :supported?, ->(**) { true }) do
      with_replaced_singleton_method(Hive::CommandMutations, :descriptor, ->(**) { descriptor }) do
        assert_raises(Hive::UsageError) do
          Hive::CommandMutations.validate_keyed!(
            command: "receipt", mode: "retire", target: "receipt-1", options: {}
          )
        end
      end
    end
  end
end
