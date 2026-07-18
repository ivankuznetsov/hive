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
        "schema" => name, "schema_version" => 1, "ok" => false,
        "error_class" => "RegistryError", "error_kind" => "registry",
        "exit_code" => 69, "message" => "unavailable"
      }
      assert schemer(name).valid?(payload), "#{name} must accept the shared error envelope"
    end
  end

  def test_lifecycle_schemas_reject_incomplete_and_open_envelopes
    SCHEMAS.each do |name|
      minimal = { "schema" => name, "schema_version" => 1, "ok" => true }
      refute schemer(name).valid?(minimal), "#{name} must reject incomplete successes"

      error = {
        "schema" => name, "schema_version" => 1, "ok" => false,
        "error_class" => "Error", "error_kind" => "error", "exit_code" => 1,
        "message" => "failed", "unexpected" => true
      }
      refute schemer(name).valid?(error), "#{name} must reject undeclared error fields"
    end
  end

  private

  def schemer(name)
    @schemers ||= {}
    @schemers[name] ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
  end

  def success_payloads
    permissions = { "tools" => [ "Read" ] }
    {
      "hive-workflow-install" => {
        "schema" => "hive-workflow-install", "schema_version" => 1, "ok" => true,
        "status" => "dry_run", "name" => "demo", "version" => "1.0.0",
        "catalog_commit" => "b" * 40, "source_commit" => "a" * 40,
        "manifest_digest" => "c" * 64, "permissions" => permissions
      },
      "hive-workflow-list" => {
        "schema" => "hive-workflow-list", "schema_version" => 1, "ok" => true,
        "workflows" => []
      },
      "hive-workflow-update" => {
        "schema" => "hive-workflow-update", "schema_version" => 1, "ok" => true,
        "status" => "already_current", "name" => "demo", "from_commit" => "a" * 40,
        "to_commit" => "a" * 40, "manifest_digest" => "c" * 64, "diff" => nil
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
end
