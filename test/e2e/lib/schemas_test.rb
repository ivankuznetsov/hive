require_relative "../../test_helper"
require "json_schemer"
require_relative "schemas"
require_relative "paths"

# Schema-name drift guard: every "schema" => "hive-e2e-..." literal that
# appears in an e2e producer (runner.rb, artifact_capture.rb, bin/hive-e2e)
# must be registered in Hive::E2E::Schemas::VERSIONS. Without this, a
# typo in a producer (`hive-e2e-mainfest` instead of `hive-e2e-manifest`)
# would slip through into agent-readable output silently.
class E2ESchemasTest < Minitest::Test
  REPLAY_REASONS = %w[
    descriptor_exec_failed
    descriptor_exec_unavailable
    replay_busy
    replay_lock_unavailable
    replay_supervision_failed
    repro_changed
    repro_missing
    repro_unreadable
    repro_unusable
    run_changed
    run_missing
    run_unusable
    runs_root_changed
    runs_root_missing
    runs_root_symlink
    runs_root_unusable
    scenario_changed
    scenario_missing
    scenario_unusable
    scenarios_changed
    scenarios_missing
    scenarios_unusable
  ].freeze

  REPLAY_KIND_REASONS = {
    "missing_repro" => %w[
      repro_missing run_missing runs_root_missing scenario_missing scenarios_missing
    ],
    "unusable_repro" => %w[
      repro_changed repro_unreadable repro_unusable run_changed run_unusable
      runs_root_changed runs_root_missing runs_root_symlink runs_root_unusable
      scenario_changed scenario_unusable scenarios_changed scenarios_unusable
    ],
    "replay_busy" => %w[replay_busy],
    "preflight" => %w[
      descriptor_exec_failed descriptor_exec_unavailable replay_lock_unavailable
    ],
    "error" => %w[replay_supervision_failed]
  }.freeze

  PRODUCER_FILES = [
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e"),
    File.join(Hive::E2E::Paths.e2e_root, "lib", "coverage_catalog.rb"),
    File.join(Hive::E2E::Paths.e2e_root, "lib", "runner.rb"),
    File.join(Hive::E2E::Paths.e2e_root, "lib", "artifact_capture.rb")
  ].freeze

  def test_versions_registry_is_frozen
    assert_predicate Hive::E2E::Schemas::VERSIONS, :frozen?,
                     "VERSIONS must be frozen so producers cannot mutate it at load time"
  end

  def test_version_for_raises_on_unknown_schema
    assert_raises(KeyError) { Hive::E2E::Schemas.version_for("hive-e2e-not-a-real-schema") }
  end

  def test_every_emitted_schema_name_is_registered
    emitted = PRODUCER_FILES.flat_map do |path|
      File.read(path).scan(/"schema"\s*=>\s*"(hive-e2e-[a-z0-9-]+)"/).flatten
    end.uniq.sort

    refute_empty emitted, "expected to find at least one hive-e2e-* schema literal in the producers"

    registered = Hive::E2E::Schemas::VERSIONS.keys.sort
    unregistered = emitted - registered
    assert_empty unregistered,
                 "the following hive-e2e-* schema names are emitted by producers but not registered in " \
                 "test/e2e/lib/schemas.rb: #{unregistered.inspect}"
  end

  def test_no_registered_schema_is_unused
    emitted = PRODUCER_FILES.flat_map do |path|
      File.read(path).scan(/"schema"\s*=>\s*"(hive-e2e-[a-z0-9-]+)"/).flatten
    end.uniq

    unused = Hive::E2E::Schemas::VERSIONS.keys - emitted
    assert_empty unused,
                 "the following registered schemas have no producer emitting them — either delete them " \
                 "or wire them into a producer: #{unused.inspect}"
  end

  def test_versions_are_positive_integers
    Hive::E2E::Schemas::VERSIONS.each do |name, version|
      assert_kind_of Integer, version, "#{name.inspect} version must be an Integer"
      assert_operator version, :>=, 1, "#{name.inspect} version must be >= 1"
    end
  end

  def test_every_registered_schema_has_a_published_file
    Hive::E2E::Schemas::VERSIONS.each_key do |name|
      path = Hive::E2E::Schemas.schema_path(name)
      assert File.exist?(path), "published schema file missing: #{path}"
    end
  end

  def test_error_schema_pins_replay_kinds_and_reasons
    schema = error_schema_document

    assert_equal %w[
      error missing_repro no_scenarios preflight replay_busy run_failed
      unusable_repro usage
    ], schema.dig("properties", "error_kind", "enum").sort
    assert_equal [ nil, *REPLAY_REASONS ],
                 schema.dig("properties", "reason", "enum")
  end

  def test_error_schema_accepts_only_the_declared_replay_kind_reason_pairs
    schemer = JSONSchemer.schema(error_schema_document)

    valid_pairs = REPLAY_KIND_REASONS.flat_map do |kind, reasons|
      reasons.map { |reason| [ kind, reason ] }
    end
    valid_pairs << [ "usage", nil ]
    valid_pairs.each do |kind, reason|
      payload = error_payload(command: "replay", error_kind: kind, reason: reason)
      assert_empty schemer.validate(payload).to_a,
                   "expected replay pair #{[ kind, reason ].inspect} to validate"
    end

    replay_kinds = [ "usage", *REPLAY_KIND_REASONS.keys ]
    replay_kinds.product([ nil, *REPLAY_REASONS ]).each do |kind, reason|
      next if valid_pairs.include?([ kind, reason ])

      payload = error_payload(command: "replay", error_kind: kind, reason: reason)
      refute_empty schemer.validate(payload).to_a,
                   "expected replay pair #{[ kind, reason ].inspect} to be rejected"
    end
  end

  def test_error_schema_requires_replay_reason_and_forbids_non_replay_reason
    schemer = JSONSchemer.schema(error_schema_document)
    replay_without_reason = error_payload(command: "replay", error_kind: "usage")
    non_replay = error_payload(command: "run", error_kind: "usage")

    refute_empty schemer.validate(replay_without_reason).to_a
    assert_empty schemer.validate(non_replay).to_a
    refute_empty schemer.validate(non_replay.merge("reason" => nil)).to_a
    refute_empty schemer.validate(non_replay.merge("reason" => "repro_missing")).to_a
  end

  def test_error_schema_rejects_unknown_replay_reason
    schemer = JSONSchemer.schema(error_schema_document)
    payload = error_payload(
      command: "replay",
      error_kind: "unusable_repro",
      reason: "platform_errno_13"
    )

    refute_empty schemer.validate(payload).to_a
  end

  private

  def error_schema_document
    JSON.parse(File.read(Hive::E2E::Schemas.schema_path("hive-e2e-error")))
  end

  def error_payload(command:, error_kind:, reason: :omitted)
    payload = {
      "schema" => "hive-e2e-error",
      "schema_version" => 1,
      "ok" => false,
      "error_kind" => error_kind,
      "message" => "failure",
      "exit_code" => 78,
      "command" => command
    }
    payload["reason"] = reason unless reason == :omitted
    payload
  end
end
