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

  def test_human_create_list_and_revoke_reveal_bearer_once_and_show_actual_grants
    Dir.mktmpdir do |root|
      project = { "name" => "server-project", "registration_id" => "project-1", "path" => root,
                  "hive_state_path" => root, "repository_identity" => "repo" }
      store = Hive::Remote::TokenStore.new(root: root, owner: -> { "operator" }, projects: -> { [ project ] })
      created = nil
      out, = capture_io do
        created = Hive::Commands::Token.new("create", name: "named", scopes: "read,answer",
                                            projects: "server-project", store: store).call
      end
      bearer = created.fetch("token").fetch("token")
      public_id = created.fetch("token").fetch("id")
      assert_equal 1, out.lines.count { |line| line.chomp == bearer }
      assert_includes out, "API: #{created.dig('interlock', 'code') || 'available'}"
      assert_includes out, "#{public_id} named scopes=read,answer projects=server-project revoked=false"

      out, = capture_io { Hive::Commands::Token.new("create", name: "fleet", scopes: [ "act" ], all_projects: true, store: store).call }
      assert_includes out, "fleet scopes=act projects=all projects revoked=false"
      out, = capture_io { Hive::Commands::Token.new("list", store: store).call }
      assert_includes out, "#{public_id} named scopes=read,answer projects=server-project revoked=false"
      refute_includes out, bearer
      out, = capture_io { Hive::Commands::Token.new("revoke", public_id, store: store).call }
      assert_includes out, "#{public_id} named scopes=read,answer projects=server-project revoked=true"
      refute_includes out, bearer
      assert_nil store.authenticate(bearer)
    end
  end

  def test_unknown_operation_cannot_issue_or_revoke_tokens
    Dir.mktmpdir do |root|
      store = Hive::Remote::TokenStore.new(root: root, owner: -> { "operator" })
      out, = capture_io do
        error = assert_raises(Hive::UsageError) do
          Hive::Commands::Token.new("delete", json: true, store: store).call
        end
        assert_match(/create, list, or revoke/, error.message)
      end
      assert_equal "usage", JSON.parse(out).fetch("error_kind")
      assert_empty store.list
      refute_path_exists store.path
    end
  end
end
