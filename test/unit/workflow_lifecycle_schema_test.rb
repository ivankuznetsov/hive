require "test_helper"
require "json_schemer"

class WorkflowLifecycleSchemaTest < Minitest::Test
  SCHEMAS = %w[
    hive-workflow-install hive-workflow-list hive-workflow-update
    hive-workflow-remove hive-workflow-publish
  ].freeze

  def test_lifecycle_schemas_accept_complete_success_and_error_arms
    success_payloads.each do |name, payload|
      assert schemer(name).valid?(payload), "#{name} must accept its complete success payload"
    end

    SCHEMAS.each do |name|
      payload = if name == "hive-workflow-publish"
        {
          "schema" => name, "schema_version" => 2, "ok" => false,
          "error_class" => "PublishOfflineError", "error_kind" => "offline",
          "exit_code" => 69, "message" => "unavailable", "retryable" => true,
          "package_digest" => "a" * 64, "release_digest" => "b" * 64,
          "last_completed_step" => "validated"
        }
      else
        {
        "schema" => name, "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(name), "ok" => false,
        "error_class" => "RegistryError", "error_kind" => "registry",
        "exit_code" => 69, "message" => "unavailable"
        }
      end
      assert schemer(name).valid?(payload), "#{name} must accept the shared error envelope"
    end
  end

  def test_publish_error_arms_bind_kind_exit_code_retryability_and_recovery_fields
    valid = [
      [ "validation", 64, false, {} ],
      [ "authentication", 78, false, {} ],
      [ "configuration", 78, false, {} ],
      [ "offline", 69, true, recovery_identity ],
      [ "immutable_conflict", 1, false, {} ],
      [ "remote_ambiguous", 75, true, recovery_identity ],
      [ "internal", 70, false, {} ]
    ]

    valid.each do |kind, exit_code, retryable, extras|
      payload = publish_error(kind, exit_code, retryable).merge(extras)
      assert schemer("hive-workflow-publish").valid?(payload), "#{kind} must validate"

      refute schemer("hive-workflow-publish").valid?(payload.merge("exit_code" => 1_000)),
             "#{kind} must bind its process exit code"
      refute schemer("hive-workflow-publish").valid?(payload.merge("retryable" => !retryable)),
             "#{kind} must bind retryability"
    end
  end

  def test_publish_schema_rejects_invalid_semver_and_accepts_structured_lint_evidence
    payload = Marshal.load(Marshal.dump(success_payloads.fetch("hive-workflow-publish")))
    payload["version"] = "01.0.0"
    refute schemer("hive-workflow-publish").valid?(payload)

    payload["version"] = "1.0.0"
    payload["warnings"] = [ {
      "rule_id" => "permission.broad-declaration",
      "severity" => "warning", "path" => "manifest.yml",
      "line" => 1, "column" => 1, "message" => "review required",
      "review_required" => true, "suppression_allowed" => true,
      "fingerprint" => "f" * 64, "suppression_requested" => false
    } ]
    assert schemer("hive-workflow-publish").valid?(payload)
  end

  def test_lifecycle_schemas_reject_incomplete_and_open_envelopes
    SCHEMAS.each do |name|
      version = Hive::Schemas::SCHEMA_VERSIONS.fetch(name)
      minimal = { "schema" => name, "schema_version" => version, "ok" => true }
      refute schemer(name).valid?(minimal), "#{name} must reject incomplete successes"

      error = {
        "schema" => name, "schema_version" => version, "ok" => false,
        "error_class" => "Error", "error_kind" => "error", "exit_code" => 1,
        "message" => "failed", "unexpected" => true
      }
      refute schemer(name).valid?(error), "#{name} must reject undeclared error fields"
    end
  end

  def test_install_and_update_share_configuration_object_contracts
    install = schema_document("hive-workflow-install").fetch("$defs")
    update = schema_document("hive-workflow-update").fetch("$defs")

    %w[Mapping OptionalInput].each do |definition|
      assert_equal install.fetch(definition), update.fetch(definition),
                   "install and update must share the #{definition} contract"
    end
  end

  def test_install_and_update_reject_empty_mapping_identity_fields
    %w[hive-workflow-install hive-workflow-update].each do |name|
      %w[mapping_contract agent].each do |field|
        payload = Marshal.load(Marshal.dump(success_payloads.fetch(name)))
        payload.fetch("mappings").first[field] = ""

        refute schemer(name).valid?(payload), "#{name} must reject an empty #{field}"
      end
    end
  end

  def test_workflow_list_rejects_raw_optional_input_values_and_incomplete_selected_configuration
    payload = Marshal.load(Marshal.dump(success_payloads.fetch("hive-workflow-list")))
    payload.fetch("workflows").last.fetch("optional_inputs").first["value"] = "secret"
    refute schemer("hive-workflow-list").valid?(payload),
           "workflow list must not admit raw optional-input values"

    payload = Marshal.load(Marshal.dump(success_payloads.fetch("hive-workflow-list")))
    payload.fetch("workflows").last.delete("configuration_digest")
    refute schemer("hive-workflow-list").valid?(payload),
           "a verified selected row must carry its active configuration identity"
  end

  private

  def schemer(name)
    @schemers ||= {}
    @schemers[name] ||= JSONSchemer.schema(schema_document(name))
  end

  def schema_document(name)
    @schema_documents ||= {}
    @schema_documents[name] ||= JSON.parse(File.read(Hive::Schemas.schema_path(name)))
  end

  def success_payloads
    permissions = { "tools" => [ "Read" ] }
    {
      "hive-workflow-install" => {
        "schema" => "hive-workflow-install", "schema_version" => 2, "ok" => true,
        "status" => "dry_run", "name" => "demo", "version" => "1.0.0",
        "catalog_commit" => "b" * 40, "source_commit" => "a" * 40,
        "manifest_digest" => "c" * 64, "permissions" => permissions,
        "configuration_digest" => "d" * 64, "mappings" => [ mapping ], "optional_inputs" => []
      },
      "hive-workflow-list" => {
        "schema" => "hive-workflow-list", "schema_version" => 2, "ok" => true,
        "workflows" => [
          {
            "name" => "authored", "origin" => "authored", "selection" => nil,
            "integrity" => nil, "catalog_visibility" => nil, "version" => nil,
            "source_commit" => nil, "manifest_digest" => nil
          },
          {
            "name" => "demo", "origin" => "managed", "selection" => "retained",
            "integrity" => "verified", "catalog_visibility" => "unknown_offline", "version" => nil,
            "source_commit" => "a" * 40, "manifest_digest" => "c" * 64,
            "configuration_digest" => "1" * 64
          },
          {
            "name" => "demo", "origin" => "managed", "selection" => "selected",
            "integrity" => "verified", "catalog_visibility" => "unknown_offline", "version" => "1.0.0",
            "source_commit" => "a" * 40, "manifest_digest" => "c" * 64,
            "configuration_digest" => "d" * 64, "mappings" => [ mapping ],
            "optional_inputs" => [ {
              "name" => "GSC_TOKEN", "authorized_slots" => [ "stages.work" ],
              "binding" => "PRODUCTION_GSC_TOKEN", "available" => true
            } ]
          }
        ]
      },
      "hive-workflow-update" => {
        "schema" => "hive-workflow-update", "schema_version" => 2, "ok" => true,
        "status" => "already_current", "name" => "demo", "from_commit" => "a" * 40,
        "to_commit" => "a" * 40, "manifest_digest" => "c" * 64, "diff" => nil,
        "configuration_digest" => "d" * 64, "mappings" => [ mapping ], "optional_inputs" => [],
        "warnings" => [ "cleanup failed after selection changed" ]
      },
      "hive-workflow-remove" => {
        "schema" => "hive-workflow-remove", "schema_version" => 1, "ok" => true,
        "status" => "dry_run", "name" => "demo", "source_commit" => "a" * 40,
        "manifest_digest" => "c" * 64, "configuration_digest" => "d" * 64,
        "retained_commits" => [],
        "deletable_commits" => [ "a" * 40 ],
        "warnings" => [ "cleanup failed after selection changed" ]
      },
      "hive-workflow-publish" => {
        "schema" => "hive-workflow-publish", "schema_version" => 2, "ok" => true,
        "state" => "pending_review", "freshness" => "current",
        "name" => "demo", "version" => "1.0.0",
        "package_digest" => "b" * 64, "release_digest" => "c" * 64, "warnings" => [],
        "observed_at" => "2026-07-21T12:00:00Z", "pr_url" => "https://example.test/pull/1"
      }
    }
  end

  def mapping
    {
      "slot" => "stages.work", "mapping_role" => "development", "mapping_contract" => "v1",
      "agent" => "claude", "model" => nil, "effort" => nil,
      "profile_fingerprint" => "e" * 64, "policy_fingerprint" => "f" * 64
    }
  end

  def publish_error(kind, exit_code, retryable)
    {
      "schema" => "hive-workflow-publish", "schema_version" => 2, "ok" => false,
      "error_class" => "PublishError", "error_kind" => kind,
      "exit_code" => exit_code, "message" => "failed", "retryable" => retryable
    }
  end

  def digest_identity
    { "package_digest" => "a" * 64, "release_digest" => "b" * 64 }
  end

  def recovery_identity
    digest_identity.merge("last_completed_step" => "validated")
  end
end
