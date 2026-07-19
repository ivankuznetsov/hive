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
      payload = {
        "schema" => name, "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(name), "ok" => false,
        "error_class" => "RegistryError", "error_kind" => "registry",
        "exit_code" => 69, "message" => "unavailable"
      }
      assert schemer(name).valid?(payload), "#{name} must accept the shared error envelope"
    end
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
        "configuration_digest" => "d" * 64, "mappings" => [ mapping ], "optional_inputs" => []
      },
      "hive-workflow-remove" => {
        "schema" => "hive-workflow-remove", "schema_version" => 1, "ok" => true,
        "status" => "dry_run", "name" => "demo", "source_commit" => "a" * 40,
        "manifest_digest" => "c" * 64, "retained_commits" => [],
        "deletable_commits" => [ "a" * 40 ]
      },
      "hive-workflow-publish" => {
        "schema" => "hive-workflow-publish", "schema_version" => 1, "ok" => true,
        "status" => "pending_review", "name" => "demo", "version" => "1.0.0",
        "manifest_digest" => "c" * 64, "warnings" => [],
        "pr_url" => "https://example.test/pull/1", "listed" => false
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
end
