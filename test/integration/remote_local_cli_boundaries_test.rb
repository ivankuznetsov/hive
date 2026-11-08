# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "hive/cli"
require "hive/connection_contexts"
require "hive/remote/token_store"

class RemoteLocalCliBoundariesTest < Minitest::Test
  include HiveTestHelper

  BIN = File.expand_path("../../bin/hive", __dir__)

  def test_public_token_administration_requires_local_override_and_reveals_the_bearer_once
    with_tmp_global_config do
      config = YAML.safe_load_file(Hive::Config.global_config_path)
      config["web"] = { "local_loopback" => false, "github" => { "owner" => "operator" } }
      File.write(Hive::Config.global_config_path, config.to_yaml)
      contexts = Hive::ConnectionContexts.new(verifier: ->(_context, _token) { metadata })
      contexts.add("elsewhere", url: "https://remote.invalid", token: "unused-fixture-bearer")
      contexts.use("elsewhere")

      stdout, stderr, status = cli("token", "list", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal false, JSON.parse(stdout).fetch("ok")
      assert_includes stderr, "specify --context local"

      stdout, stderr, status = cli("token", "create", "--context", "local", "--name", "local operator",
        "--scopes", "read,answer", "--all-projects", "--json")
      assert status.success?, stderr
      issued = JSON.parse(stdout)
      assert_equal "hive-token", issued.fetch("schema")
      assert_equal [ "read", "answer" ], issued.dig("token", "scopes")
      bearer = issued.dig("token", "token")
      public_id = issued.dig("token", "id")
      assert bearer
      assert_includes stderr, "target=local-server-token-registry"
      refute_includes stderr, bearer

      stdout, stderr, status = cli("token", "list", "--context", "local", "--json")
      assert status.success?, stderr
      assert_equal [ public_id ], JSON.parse(stdout).fetch("tokens").map { |token| token.fetch("id") }
      refute_includes stdout, bearer
      assert Hive::Remote::TokenStore.new.authenticate(bearer)

      stdout, stderr, status = cli("token", "revoke", public_id, "--context", "local", "--json")
      assert status.success?, stderr
      assert JSON.parse(stdout).dig("token", "revoked")
      refute_includes stdout, bearer
      assert_nil Hive::Remote::TokenStore.new.authenticate(bearer)
      assert_equal "elsewhere", contexts.resolve.fetch("name")
    end
  end

  def test_programmatic_cli_context_dispatch_needs_no_local_runtime
    with_tmp_global_config(runtime: false) do
      refute File.exist?(Hive::Paths.runtime_control_plane_path)
      stdout, stderr = capture_io { Hive::CLI.start(%w[context list --json]) }
      assert_equal "local", JSON.parse(stdout).fetch("data").first.fetch("name")
      assert_empty stderr
      stdout, stderr = capture_io { Hive::CLI.start(%w[context use local --json]) }
      assert JSON.parse(stdout).fetch("ok")
      assert_includes stderr, "target=local-client-configuration"
      refute File.exist?(Hive::Paths.runtime_control_plane_path)
      assert_nil Hive::Remote::CommandPolicy.current_invocation
      stdout, = capture_io { Hive::CLI.start(%w[version --json]) }
      assert_equal "hive-version", JSON.parse(stdout).fetch("schema")
      assert_nil Hive::Remote::CommandPolicy.current_invocation
    end
  end

  private

  def cli(*arguments)
    Open3.capture3(RbConfig.ruby, BIN, *arguments)
  end

  def metadata
    { "instance_id" => "fixture-server", "api_version" => "v1",
      "token" => { "id" => "fixture-public-id", "scopes" => [ "read" ], "projects" => [ "demo" ],
                   "all_projects" => false, "expires_at" => nil } }
  end
end
