require "test_helper"
require "json_schemer"
require "hive/commands/workflow/publish"
require "hive/workflow_package/publisher"

class WorkflowPublishCommandTest < Minitest::Test
  Package = Hive::WorkflowPackage::Publisher::Package
  Result = Data.define(:state, :freshness, :observed_at, :pr_url, :warnings)
  Receipt = Data.define(:last_completed_step, :observation, :data)

  def test_dry_run_returns_validated_v2_payload_without_publication
    publisher, calls = publisher_double
    stdout = StringIO.new
    payload = command(publisher, stdout: stdout, dry_run: true).call!

    assert_equal "validated", payload.fetch("state")
    assert_equal "not_checked", payload.fetch("freshness")
    assert_equal "a" * 64, payload.fetch("package_digest")
    assert_equal "b" * 64, payload.fetch("release_digest")
    assert_equal [ :package ], calls
    assert_equal payload, JSON.parse(stdout.string)
  end

  def test_real_publish_requires_and_accepts_exact_dry_run_digest
    publisher, calls = publisher_double
    payload = command(
      publisher, expected_release_digest: "b" * 64, stdout: StringIO.new
    ).call!

    assert_equal "pending_review", payload.fetch("state")
    assert_equal "current", payload.fetch("freshness")
    assert_equal "https://github.com/ivankuznetsov/honeycomb/pull/42", payload.fetch("pr_url")
    assert_equal %i[prepare publish], calls
  end

  def test_expected_digest_mismatch_stops_before_publish
    publisher, calls = publisher_double
    assert_raises(Hive::Commands::Workflow::Publish::ValidationError) do
      command(publisher, expected_release_digest: "c" * 64).call!
    end
    assert_equal [ :prepare ], calls
  end

  def test_validation_error_is_closed_retry_safe_schema_payload
    publisher = Object.new
    publisher.define_singleton_method(:package) { |destination:| raise Hive::ConfigError, "bad authored metadata" }
    stdout = StringIO.new
    error = assert_raises(SystemExit) { command(publisher, stdout: stdout, dry_run: true).call }
    payload = JSON.parse(stdout.string)

    assert_equal Hive::ExitCodes::USAGE, error.status
    assert_equal "validation", payload.fetch("error_kind")
    assert_equal false, payload.fetch("retryable")
    assert_equal error.status, payload.fetch("exit_code")
  end

  def test_remote_and_internal_errors_emit_their_exact_schema_arms
    cases = [
      [ Hive::WorkflowPackage::PublishAuthenticationError.new("auth"), "authentication", 78, false ],
      [ Hive::WorkflowPackage::PublishOfflineError.new("offline"), "offline", 69, true ],
      [ Hive::WorkflowPackage::PublishConflict.new("conflict"), "immutable_conflict", 1, false ],
      [ Hive::WorkflowPackage::PublishAmbiguousError.new("ambiguous"), "remote_ambiguous", 75, true ],
      [ Hive::WorkflowPackage::PublishPolicyBlocked.new("policy"), "validation", 64, false ],
      [ RuntimeError.new("raw internal detail"), "internal", 70, false ]
    ]

    cases.each do |raised, kind, exit_code, retryable|
      stdout = StringIO.new
      error = assert_raises(SystemExit) do
        command(erroring_publisher(raised), stdout: stdout).call
      end
      payload = JSON.parse(stdout.string)

      assert_equal exit_code, error.status
      assert_equal kind, payload.fetch("error_kind")
      assert_equal retryable, payload.fetch("retryable")
      assert publish_schemer.valid?(payload), "#{kind} producer payload must validate"
    end
  end

  def test_invalid_registry_configuration_remains_configuration_not_authoring_validation
    publisher = Object.new
    publisher.define_singleton_method(:prepare) do |destination:|
      raise Hive::WorkflowPackage::PublishConfigurationError, "invalid registry"
    end
    stdout = StringIO.new

    error = assert_raises(SystemExit) { command(publisher, stdout: stdout).call }
    payload = JSON.parse(stdout.string)

    assert_equal 78, error.status
    assert_equal "configuration", payload.fetch("error_kind")
    assert publish_schemer.valid?(payload)
  end

  private

  def command(publisher, stdout: StringIO.new, dry_run: false, expected_release_digest: nil)
    Hive::Commands::Workflow::Publish.new(
      "demo", project_root: Dir.pwd, version: "1.2.3", json: true,
      dry_run: dry_run, expected_release_digest: expected_release_digest,
      stdout: stdout, publisher: publisher,
      clock: -> { Time.iso8601("2026-07-21T12:00:00Z") }
    )
  end

  def publisher_double
    calls = []
    package = Package.new(
      name: "demo", version: "1.2.3", root: Dir.pwd,
      package_digest: "a" * 64, release_digest: "b" * 64,
      warnings: [], findings: [], lint_contract: nil
    )
    publisher = Object.new
    publisher.define_singleton_method(:package) { |destination:| calls << :package; package }
    publisher.define_singleton_method(:prepare) { |destination:| calls << :prepare; package }
    publisher.define_singleton_method(:publish) do |_package|
      calls << :publish
      Result.new(
        state: "pending_review", freshness: "current", observed_at: "2026-07-21T12:00:00Z",
        pr_url: "https://github.com/ivankuznetsov/honeycomb/pull/42", warnings: []
      )
    end
    [ publisher, calls ]
  end

  def erroring_publisher(error)
    package = Package.new(
      name: "demo", version: "1.2.3", root: Dir.pwd,
      package_digest: "a" * 64, release_digest: "b" * 64,
      warnings: [], findings: [], lint_contract: nil
    )
    receipt = Receipt.new(
      last_completed_step: "validated", observation: nil, data: {}
    )
    Object.new.tap do |publisher|
      publisher.define_singleton_method(:prepare) { |destination:| package }
      publisher.define_singleton_method(:publish) { |_package| raise error }
      publisher.define_singleton_method(:receipt_for) { |_package| receipt }
    end
  end

  def publish_schemer
    @publish_schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-publish")))
    )
  end
end
