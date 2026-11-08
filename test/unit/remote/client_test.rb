# frozen_string_literal: true

require "test_helper"
require "hive/remote/client"
require_relative "../../support/remote_tls_server"

class RemoteClientTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hive-client-tls")
    @servers = []
  end

  def teardown
    @servers.each(&:close)
    FileUtils.remove_entry(@root)
  end

  def test_verified_tls_and_additive_v1_fields
    server = server { [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata.merge("future" => true), future: true) ] }
    metadata = client(server).context
    assert_equal "v1", metadata.fetch("api_version")
    assert_equal [ "read", "create", "act", "answer" ], metadata.dig("token", "scopes")
    assert_equal "/api/v1/context", server.requests.first.fetch(:path)
    assert_equal "Bearer secret-bearer", server.requests.first.dig(:headers, "authorization")
    error = assert_raises(Hive::Remote::Client::Failure) { client(server, ca_file: nil).context }
    assert_match(/TLS|connect/, error.message)
    refute_includes error.message, "secret-bearer"
  end

  def test_redirects_are_never_followed_or_forwarded
    destination = server { flunk "redirect forwarded credentials" }
    origin = server { [ 302, { "Location" => "#{destination.url}/token=secret-bearer" }, "secret-bearer" ] }
    error = assert_raises(Hive::Remote::Client::Failure) { client(origin).context }
    assert_match(/redirect/, error.message)
    assert_empty destination.requests
    refute_includes error.message, "secret-bearer"
  end

  def test_every_mutation_refreshes_identity_and_announces_before_post
    output = StringIO.new
    observed = []
    server = server do |request|
      if request.fetch(:method) == "GET"
        [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata(scopes: [ "create" ])) ]
      else
        observed << output.string.dup
        [ 201, {}, RemoteTlsServer.envelope({ "operation_id" => "op-1" }) ]
      end
    end
    transport = client(server)
    2.times do
      transport.mutate("/projects/demo/tasks", { "text" => "literal request" },
        key: "stable-key", target: "demo:new", stderr: output)
    end
    assert_equal %w[GET POST GET POST], server.requests.map { |request| request.fetch(:method) }
    observed.each do |announcement|
      assert_match(/context=nas.*#{Regexp.escape(server.url)}.*server-1/, announcement)
      assert_match(/scopes=create.*projects=demo.*target=demo:new.*idempotency_key=stable-key/, announcement)
    end
    posts = server.requests.select { |request| request.fetch(:method) == "POST" }
    assert_equal posts.first.fetch(:body), posts.last.fetch(:body)
    assert_equal "stable-key", posts.first.dig(:headers, "idempotency-key")
  end

  def test_identity_and_api_mismatch_prevent_submission
    [ RemoteTlsServer.metadata(instance: "replaced"), RemoteTlsServer.metadata(version: "v2") ].each do |metadata|
      server = server { [ 200, {}, RemoteTlsServer.envelope(metadata, instance: metadata.fetch("instance_id")) ] }
      error = assert_raises(Hive::Remote::Client::Failure) do
        client(server).mutate("/projects/demo/tasks", { "text" => "request" },
          key: "key", target: "demo:new", stderr: StringIO.new)
      end
      assert_match(/identity|version/, error.message)
      assert_equal [ "GET" ], server.requests.map { |request| request.fetch(:method) }
    end
  end

  def test_retired_version_guidance_uses_only_validated_served_base_paths
    server = server do
      [ 404, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false, "instance_id" => nil,
        "error" => { "code" => "unsupported_version", "message" => "secret-bearer",
                     "served_base_paths" => [ "/api/v2", "/secret-bearer", "/api/v3\nsecret-bearer" ] } } ]
    end
    error = assert_raises(Hive::Remote::Client::UnsupportedVersion) { client(server).context }
    assert_match(%r{/api/v2}, error.message)
    assert_match(/upgrade|compatible/, error.message)
    refute_includes error.message, "secret-bearer"
  end

  def test_revocation_malformed_and_oversized_responses_have_fixed_safe_diagnostics
    responses = [
      [ 401, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false,
        "instance_id" => "server-1", "error" => { "code" => "invalid_token", "message" => "secret-bearer" } } ],
      [ 200, {}, "{malformed secret-bearer" ],
      [ 200, {}, "secret-bearer" * 200 ],
      [ 200, { "Content-Length" => nil, "Transfer-Encoding" => "chunked" }, "secret-bearer" * 200 ]
    ]
    responses.each do |response|
      server = server { response }
      error = assert_raises(Hive::Remote::Client::Failure) { client(server, max_response_bytes: 1024).context }
      refute_includes error.message, "secret-bearer"
    end
  end

  def test_disconnect_and_timeout_report_unknown_outcome_without_retrying_post
    [ :disconnect, :timeout ].each do |fault|
      server = server do |request|
        if request.fetch(:method) == "GET"
          [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata) ]
        else
          sleep 0.1 if fault == :timeout
          :disconnect
        end
      end
      error = assert_raises(Hive::Remote::Client::UnknownSubmission) do
        client(server, read_timeout: 0.04).mutate("/projects/demo/tasks", { "text" => "request" },
          key: "same-key", target: "demo:new", stderr: StringIO.new)
      end
      assert_match(/UNKNOWN SUBMISSION OUTCOME/, error.message)
      assert_match(/same-key.*demo:new|demo:new.*same-key/, error.message)
      assert_equal [ "GET", "POST" ], server.requests.map { |request| request.fetch(:method) }
    end
  end

  def test_invalid_transport_configuration_and_inputs_fail_before_a_request
    [ "http://secret-bearer.example", "https://user:secret-bearer@example.invalid" ].each do |url|
      error = assert_raises(Hive::UsageError) { Hive::Remote::Client.new(context: { "url" => url }, bearer: "secret-bearer") }
      refute_includes error.message, "secret-bearer"
    end
    assert_raises(Hive::ConfigError) { Hive::Remote::Client.new(context: {}, bearer: "secret-bearer") }
    assert_raises(Hive::ConfigError) do
      Hive::Remote::Client.new(context: { "url" => "https://example.invalid" }, bearer: "secret-bearer\n")
    end
    peer = server { flunk "invalid mutation reached the server" }
    transport = client(peer)
    assert_raises(Hive::UsageError) do
      transport.mutate("/projects/demo/tasks", {}, key: "secret-bearer\n", target: "demo:new")
    end
    assert_raises(Hive::UsageError) do
      transport.mutate("/projects/demo/tasks", { "text" => "x" * (256 * 1024) }, key: "key", target: "demo:new")
    end
    assert_empty peer.requests
  end

  def test_content_types_protocol_envelopes_and_known_post_rejections_fail_without_reflection
    responses = [
      [ 200, { "Content-Type" => "text/html" }, "secret-bearer" ],
      [ 200, {}, { "ok" => true, "data" => "secret-bearer" } ],
      [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata.merge("token" => { "id" => "secret-bearer\n" })) ]
    ]
    responses.each do |response|
      peer = server { response }
      error = assert_raises(Hive::Remote::Client::Failure) { client(peer).context }
      refute_includes error.message, "secret-bearer"
    end
    peer = server do |request|
      if request.fetch(:method) == "GET"
        [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata) ]
      else
        [ 409, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false,
          "instance_id" => "server-1", "error" => { "code" => "conflict", "message" => "secret-bearer" } } ]
      end
    end
    error = assert_raises(Hive::Remote::Client::Failure) do
      client(peer).mutate("/projects/demo/tasks", {}, key: "key", target: "demo:new", stderr: StringIO.new)
    end
    assert_equal "conflict", error.code
    refute_kind_of Hive::Remote::Client::UnknownSubmission, error
    refute_includes error.message, "secret-bearer"
  end

  def test_disabled_dispatch_preserves_code_and_reconstructs_exact_local_guidance_without_reflecting_server_text
    peer = server do |request|
      if request.fetch(:method) == "GET"
        [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata) ]
      else
        [ 503, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false,
          "instance_id" => "server-1", "error" => { "code" => "dispatcher_unavailable", "message" => "secret-bearer\nmalicious command" } } ]
      end
    end
    error = assert_raises(Hive::Remote::Client::Failure) do
      client(peer).mutate("/projects/demo/tasks/task/actions",
        { "action_id" => "workflow.retry", "observation" => "a" * 64 },
        key: "key", target: "demo:task", stderr: StringIO.new)
    end
    assert_equal "dispatcher_unavailable", error.code
    assert_equal 503, error.status
    assert_includes error.message, "Run locally: hive act workflow.retry demo:task --observation #{'a' * 64} --project demo --json"
    refute_includes error.message, "secret-bearer"
    refute_includes error.message, "malicious"
    transport = client(peer)
    [ "demo:task;bad", "demo\n:task", "demo:task:other" ].each do |target|
      assert_nil transport.send(:local_retry_command, target, { "action_id" => "workflow.retry", "observation" => "a" * 64 })
    end
    assert_nil transport.send(:local_retry_command, "demo:task", { "action_id" => "workflow.retry", "observation" => "a" * 64 + "\nbad" })
  end

  def test_disabled_dispatch_for_a_numeric_id_uses_only_validated_canonical_slug_guidance
    command = "hive act workflow.retry demo:canonical-task --observation #{'a' * 64} --project demo --json"
    peer = server do |request|
      if request.fetch(:method) == "GET"
        [ 200, {}, RemoteTlsServer.envelope(RemoteTlsServer.metadata) ]
      else
        [ 503, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false,
          "instance_id" => "server-1", "error" => { "code" => "dispatcher_unavailable", "message" => "secret-bearer. Run locally: #{command}" } } ]
      end
    end
    transport = client(peer)
    payload = { "action_id" => "workflow.retry", "observation" => "a" * 64 }
    error = assert_raises(Hive::Remote::Client::Failure) do
      transport.mutate("/projects/demo/tasks/817/actions", payload,
        key: "key", target: "demo:817", stderr: StringIO.new)
    end
    assert_includes error.message, command
    refute_includes error.message, "secret-bearer"
    refute_includes error.message, "demo:817"
    assert_nil transport.send(:local_retry_command, "other:817", payload, binding: error.retry_binding)
    assert_nil transport.send(:local_retry_command, "demo:817", payload.merge("observation" => "b" * 64), binding: error.retry_binding)
    [ "#{command}; bad", "#{command}\nbad", command.sub("canonical-task", "$(bad)"), command.sub("--project demo", "--project other") ].each do |unsafe|
      assert_nil transport.send(:local_retry_binding, { "code" => "dispatcher_unavailable", "message" => "Run locally: #{unsafe}" })
    end
  end

  private

  def server(&block)
    RemoteTlsServer.new(root: @root, &block).tap { |value| @servers << value }
  end

  def client(server, **options)
    Hive::Remote::Client.new(context: { "name" => "nas", "url" => server.url, "instance_id" => "server-1" },
      bearer: "secret-bearer", ca_file: server.certificate_path, **options)
  end
end
