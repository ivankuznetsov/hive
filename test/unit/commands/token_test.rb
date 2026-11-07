# frozen_string_literal: true

require "test_helper"
require "json_schemer"
require "hive/commands/token"

class TokenCommandTest < Minitest::Test
  def test_issue_list_revoke_keep_secret_once_and_match_json_contract
    Dir.mktmpdir do |root|
      store = Hive::Remote::TokenStore.new(root: root, owner: -> { "operator" })
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-token"))))
      out, = capture_io { Hive::Commands::Token.new("create", scopes: "read,answer", all_projects: true, json: true, store: store).call }
      created = JSON.parse(out)
      assert_empty schema.validate(created).to_a
      secret = created.fetch("token").fetch("token")
      public_id = created.fetch("token").fetch("id")
      out, = capture_io { Hive::Commands::Token.new("list", json: true, store: store).call }
      assert_empty schema.validate(JSON.parse(out)).to_a
      refute_includes out, secret
      out, = capture_io { Hive::Commands::Token.new("revoke", public_id, json: true, store: store).call }
      assert_empty schema.validate(JSON.parse(out)).to_a
      refute_includes out, secret
      assert_nil store.authenticate(secret)
    end
  end

  def test_usage_contract_is_registered_before_dispatch
    contract = Hive::CliUsageContracts.contract(%w[token create --json --unknown])
    assert_equal "hive-token", contract.fetch(:schema)
    payload = Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("bad invocation"))
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-token"))))
    assert_empty schema.validate(payload).to_a
  end
end
