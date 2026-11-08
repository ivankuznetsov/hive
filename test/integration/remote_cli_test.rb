# frozen_string_literal: true

require "test_helper"
require "open3"
require "json_schemer"
require "hive/connection_contexts"
require_relative "../support/remote_tls_server"

class RemoteCliTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  HIVE = File.join(ROOT, "bin/hive")
  OPERATION = "12345678-1234-1234-1234-123456789abc"

  def setup
    @root = Dir.mktmpdir("hive-native-remote")
    @home = File.join(@root, "client")
    @checkout = File.join(@root, "unrelated", "demo")
    FileUtils.mkdir_p(@checkout)
    File.write(File.join(@checkout, "sentinel"), "untouched")
    @server = RemoteTlsServer.new(root: @root) do |request|
      @handler ? @handler.call(request) : response_for(request)
    end
    @additional_servers = []
    @metadata = RemoteTlsServer.metadata
    @contexts = Hive::ConnectionContexts.new(root: File.join(@home, "connections"),
      verifier: ->(*) { RemoteTlsServer.metadata })
  end

  def teardown
    @server.close
    @additional_servers.each(&:close)
    FileUtils.remove_entry(@root)
  end

  def test_context_commands_work_without_a_local_runtime_and_show_verified_authority
    out, err, status = hive("context", "add", "nas", "--url", @server.url, "--token-stdin", "--json", stdin: "secret-bearer\n")
    assert status.success?, err
    assert_equal "local", @contexts.resolve.fetch("name")
    assert_equal [ "demo" ], JSON.parse(out).dig("data", "authority", "projects")
    out, err, status = hive("context", "use", "nas", "--json")
    assert status.success?, err
    assert_equal %w[read create act answer], JSON.parse(out).dig("data", "authority", "scopes")
    assert_match(/context=local.*local-client-configuration/, err)
    refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
    refute_includes out + err, "secret-bearer"
  end

  def test_remote_status_cursor_is_forwarded_and_operational_is_rejected
    select_remote
    out, err, status = hive("status", "--project", "demo", "--cursor", "opaque-cursor", "--json")
    assert status.success?, err
    assert_includes @server.requests.last.fetch(:path), "cursor=opaque-cursor"
    @server.requests.clear
    out, err, status = hive("status", "--operational", "--json")
    assert_equal 64, status.exitstatus
    assert_match(/does not support --operational/, err)
    assert_empty @server.requests
  end

  def test_approval_lost_response_can_replay_printed_inputs_after_advancement
    select_remote
    submitted = nil
    advanced = false
    @handler = lambda do |request|
      if request.fetch(:method) == "POST"
        input = JSON.parse(request.fetch(:body))
        identity = [ input, request.fetch(:headers).fetch("idempotency-key") ]
        if submitted
          assert_equal submitted, identity
          [ 202, {}, RemoteTlsServer.envelope({ "operation_id" => OPERATION, "state" => "queued" }) ]
        else
          submitted = identity
          advanced = true
          :disconnect
        end
      elsif advanced && !request.fetch(:path).end_with?("/context")
        [ 200, {}, RemoteTlsServer.envelope({ "task" => { "stage" => "3-plan" }, "approval_generation" => "b" * 64 }) ]
      else
        response_for(request)
      end
    end
    out, err, status = hive("approve", "demo:task-1", "--json")
    assert_equal 75, status.exitstatus
    replay = err.match(/approval replay --from (\S+) --generation (\S+) --idempotency-key (\S+)/)
    refute_nil replay
    out, err, status = hive("approve", "demo:task-1", "--from", replay[1], "--generation", replay[2],
      "--idempotency-key", replay[3], "--json")
    assert status.success?, err
    assert_equal OPERATION, JSON.parse(out).dig("data", "operation_id")
  end

  def test_remote_task_selectors_and_explicit_outputs
    select_remote
    { "--log" => "/logs", "--diff" => "/diff", "--artifacts" => "/artifacts",
      "--artifact=opaque-artifact" => "/artifacts/opaque-artifact" }.each do |flag, suffix|
      out, err, status = hive("task", "demo:task-1", flag, "--json")
      assert status.success?, err
      assert_equal "hive-remote", JSON.parse(out).fetch("schema")
      assert_equal "/api/v1/projects/demo/tasks/task-1#{suffix}", @server.requests.last.fetch(:path)
    end
    destination = File.join(@root, "artifact.txt")
    out, err, status = hive("task", "task-1", "--project", "demo", "--artifact", "opaque-artifact", "--output", destination, "--json")
    assert status.success?, err
    assert_equal "artifact content", File.read(destination)
    assert_equal true, JSON.parse(out).fetch("ok")
    out, err, status = hive("task", "demo:task-1", "--diff")
    assert status.success?, err
    assert_equal "diff content\n", out
    assert_equal [ "sentinel" ], Dir.children(@checkout)
  end

  def test_new_public_command_help_works_on_a_fresh_client_without_runtime_startup
    %w[context token operation].each do |command|
      out, err, status = hive(command, "--help")
      assert status.success?, err
      assert_includes out, "hive #{command}"
      refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
    end
    assert_empty @server.requests
  end

  def test_new_remote_only_selectors_reject_default_and_explicit_local_before_runtime
    [ [], [ "--context", "local" ] ].each do |prefix|
      [ [ "--diff" ], [ "--artifacts" ], [ "--artifact", "opaque" ] ].each do |selector|
        out, err, status = hive(*prefix, "task", "task-1", *selector, "--json")
        assert_equal 64, status.exitstatus
        assert_match(/hive task.*--json/, err)
        assert_match(/--context.*remote/, err)
        assert_equal false, JSON.parse(out).fetch("ok")
        refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
      end
    end
    assert_empty @server.requests
  end

  def test_native_mutation_flushes_target_and_authority_before_the_server_observes_post
    select_remote
    FileUtils.mkdir_p(File.join(@checkout, ".hive-state"))
    File.write(File.join(@checkout, ".hive-state", "same-named-project"), "local task state")
    File.write(File.join(@home, "config.yml"), { "registered_projects" => [ { "name" => "demo", "path" => @checkout } ] }.to_yaml)
    before = checkout_snapshot
    diagnostics = +""
    observed_before_post = nil
    error_pipe = nil
    @handler = lambda do |request|
      if request.fetch(:method) == "POST"
        available = error_pipe.read_nonblock(64 * 1024, exception: false)
        diagnostics << available if available.is_a?(String)
        observed_before_post = diagnostics.dup
      end
      response_for(request)
    end
    Open3.popen3(environment, RbConfig.ruby, HIVE, "new", "demo", "literal --unknown request",
      "--idempotency-key", "fixed-key", "--json", chdir: @checkout) do |input, output, errors, process|
      error_pipe = errors
      input.close
      document = JSON.parse(output.read)
      diagnostics << errors.read
      assert process.value.success?, diagnostics
      assert_equal "hive-remote", document.fetch("schema")
      assert_equal OPERATION, document.dig("data", "operation_id")
    end
    assert_match(/context=nas.*#{Regexp.escape(@server.url)}.*server-1.*scopes=read,create,act,answer/, observed_before_post)
    assert_match(/projects=demo.*target=demo:new.*idempotency_key=fixed-key/, observed_before_post)
    assert_equal before, checkout_snapshot
    assert_equal "literal --unknown request", JSON.parse(@server.requests.last.fetch(:body)).fetch("text")
    refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
  end

  def test_context_option_lifting_literal_terminator_and_hv_use_the_same_remote_route
    @contexts.add("nas", url: @server.url, token: "secret-bearer")
    out, err, status = hive("new", "demo", "--context", "nas", "--workflow", "content",
      "--depends-on", "first", "--depends-on", "other:second", "--json", "--", "literal", "--context", "word")
    assert status.success?, err
    assert JSON.parse(out).fetch("ok")
    body = JSON.parse(@server.requests.last.fetch(:body))
    assert_equal "literal --context word", body.fetch("text")
    assert_equal [ "first", "other:second" ], body.fetch("depends_on")
    assert_equal "content", body.fetch("workflow")
    [ %w[--context nas], %w[--context=nas] ].each do |override|
      out, err, status = hive("new", "demo", "trailing context request", *override,
        "--idempotency-key", "trailing-key", "--json")
      assert status.success?, err
      assert_equal "hive-remote", JSON.parse(out).fetch("schema")
      body = JSON.parse(@server.requests.last.fetch(:body))
      assert_equal "trailing context request", body.fetch("text")
      assert_equal "trailing-key", @server.requests.last.dig(:headers, "idempotency-key")
    end
    out, err, status = Open3.capture3(environment.merge("HIVE_BIN_OVERRIDE" => HIVE), File.join(ROOT, "bin/hv"),
      "new", "demo", "hv request", "--context=nas", "--json", chdir: @checkout)
    assert status.success?, err
    assert_equal "hive-remote", JSON.parse(out).fetch("schema")
    assert_equal "hv request", JSON.parse(@server.requests.last.fetch(:body)).fetch("text")
  end

  def test_remote_local_only_denial_loads_no_task_adapter_and_explicit_local_makes_no_http_request
    select_remote
    loaded = File.join(@root, "loaded.json")
    guard = File.join(@root, "load-guard.rb")
    File.write(guard, "require 'json'\nat_exit { File.write(ENV.fetch('HIVE_LOADED_TEST'), JSON.generate($LOADED_FEATURES)) }\n")
    out, err, status = Open3.capture3(environment.merge("RUBYOPT" => "-r#{guard}", "HIVE_LOADED_TEST" => loaded),
      RbConfig.ruby, HIVE, "init", ".", "--json", chdir: @checkout)
    assert_equal 64, status.exitstatus
    assert_match(/--context local/, err)
    assert_equal false, JSON.parse(out).fetch("ok")
    refute JSON.parse(File.read(loaded)).any? { |path| path.match?(%r{/hive/commands/(?:init|task|new)\.rb\z}) }
    out, err, status = hive("--context", "local", "version", "--json")
    assert status.success?, err
    assert_equal "hive-version", JSON.parse(out).fetch("schema")
    assert_empty @server.requests
  end

  def test_remote_targets_and_unsafe_approval_flags_fail_before_any_request
    select_remote
    [ %w[task task-1 --json], %w[task /tmp/task --project demo --json],
     %w[approve demo:task-1 --force --json], %w[approve demo:task-1 --to 4-execute --json],
     %w[task demo:task-1 --diff --artifacts --json],
     %w[task demo:task-1 --project another --json], %w[task demo:task:extra --json],
     %w[task demo:task-1 --artifact /secret-bearer --json], %w[task demo:task-1 -x --json],
     %w[task demo:task-1 --json=secret-bearer --json],
     %w[approve demo:task-1 --from 2 --generation invalid --json] ].each do |args|
      out, err, status = hive(*args)
      assert_equal 64, status.exitstatus, err
      assert_equal false, JSON.parse(out).fetch("ok")
    end
    assert_empty @server.requests
    assert_equal [ "sentinel" ], Dir.children(@checkout)
  end

  def test_write_only_actions_answers_approvals_and_own_operation_lookup_need_no_task_read
    select_remote
    @metadata = RemoteTlsServer.metadata(scopes: [ "act", "answer" ])
    [ [ %w[act workflow.advance demo:task-1 --observation observation --json], "" ],
     [ %w[answer demo:task-1 --binding opaque-question --json], "literal answer\n--never-an-option" ],
     [ [ "approve", "demo:task-1", "--from", "2-brainstorm", "--generation", "a" * 64, "--json" ], "" ] ].each do |args, input|
      out, err, status = hive(*args, stdin: input)
      assert status.success?, err
      assert_equal OPERATION, JSON.parse(out).dig("data", "operation_id")
    end
    assert_equal %w[GET POST GET POST GET POST], @server.requests.map { |request| request.fetch(:method) }
    answer = JSON.parse(@server.requests.find { |request| request.fetch(:path).end_with?("/answers") }.fetch(:body))
    assert_equal "opaque-question", answer.fetch("handle")
    assert_equal "literal answer\n--never-an-option", answer.fetch("answer")
    out, err, status = hive("operation", OPERATION, "--project", "demo", "--json")
    assert status.success?, err
    document = JSON.parse(out)
    assert_equal "hive-operation", document.fetch("schema")
    assert_empty JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operation")))).validate(document).to_a
  end

  def test_remote_status_project_filter_and_default_task_have_json_and_human_output
    select_remote
    out, err, status = hive("status", "--project", "demo", "--json")
    assert status.success?, err
    assert JSON.parse(out).fetch("ok")
    assert_equal "/api/v1/status?project=demo", @server.requests.last.fetch(:path)
    out, err, status = hive("task", "demo:task-1", "--no-log")
    assert status.success?, err
    assert_equal "task-1", JSON.parse(out).dig("task", "slug")
    assert_equal "/api/v1/projects/demo/tasks/task-1", @server.requests.last.fetch(:path)
    destination = File.join(@root, "human-output.txt")
    out, err, status = hive("task", "demo:task-1", "--artifact", "opaque-artifact", "--output", destination)
    assert status.success?, err
    assert_equal "Saved requested remote content\n", out
    assert_equal "artifact content", File.read(destination)
  end

  def test_remote_output_and_malformed_dto_errors_remain_one_safe_document
    select_remote
    out, err, status = hive("task", "demo:task-1", "--artifact", "opaque-artifact", "--output", File.join(@root, "missing", "artifact"), "--json")
    assert_equal 64, status.exitstatus
    assert_equal false, JSON.parse(out).fetch("ok")
    @handler = ->(*) { [ 200, {}, RemoteTlsServer.envelope({ "sections" => "secret-bearer" }) ] }
    out, err, status = hive("task", "demo:task-1", "--diff", "--json")
    refute status.success?
    assert_equal false, JSON.parse(out).fetch("ok")
    refute_includes out + err, "secret-bearer"
  end

  def test_remote_operation_rejects_invalid_id_with_its_own_error_schema_before_http
    select_remote
    out, err, status = hive("operation", "not-an-id", "--project", "demo", "--json")
    assert_equal 64, status.exitstatus
    document = JSON.parse(out)
    assert_equal "hive-operation", document.fetch("schema")
    assert_empty JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operation")))).validate(document).to_a
    assert_empty @server.requests
  end

  def test_approval_can_use_fresh_read_metadata_but_answer_only_requires_explicit_generation
    select_remote
    @metadata = RemoteTlsServer.metadata(scopes: [ "answer" ])
    out, err, status = hive("approve", "demo:task-1", "--from", "2-brainstorm", "--json")
    assert_equal 64, status.exitstatus
    assert_match(/--generation/, err)
    assert_equal false, JSON.parse(out).fetch("ok")
    assert_equal [ "GET" ], @server.requests.map { |request| request.fetch(:method) }
    @server.requests.clear
    @metadata = RemoteTlsServer.metadata
    out, err, status = hive("approve", "demo:task-1", "--json")
    assert status.success?, err
    assert JSON.parse(out).fetch("ok")
    assert_equal "/api/v1/projects/demo/tasks/task-1", @server.requests[1].fetch(:path)
    body = JSON.parse(@server.requests.last.fetch(:body))
    assert_equal "2-brainstorm", body.fetch("stage")
    assert_equal "a" * 64, body.fetch("generation")
  end

  def test_answer_inventory_preserves_opaque_handles_and_rejects_oversized_literal_input
    select_remote
    @handler = lambda do |request|
      if request.fetch(:path).end_with?("/questions")
        [ 200, {}, RemoteTlsServer.envelope({ "slots" => [ { "handle" => "opaque-question", "text" => "Which color?" } ] }) ]
      else
        response_for(request)
      end
    end
    out, err, status = hive("answer", "demo:task-1", "--json")
    assert status.success?, err
    assert_equal "opaque-question", JSON.parse(out).dig("data", "slots", 0, "handle")
    refute_includes out, "binding"
    @server.requests.clear
    out, err, status = hive("answer", "demo:task-1", "--binding", "opaque-question", "--json", stdin: "x" * (64 * 1024 + 1))
    assert_equal 64, status.exitstatus
    assert_equal false, JSON.parse(out).fetch("ok")
    assert_empty @server.requests
  end

  def test_lost_response_reports_the_generated_key_and_manual_retry_preserves_payload
    select_remote
    dropped = false
    @handler = lambda do |request|
      if request.fetch(:method) == "POST" && !dropped
        dropped = true
        :disconnect
      else
        response_for(request)
      end
    end
    out, err, status = hive("new", "demo", "same request", "--json")
    assert_equal 75, status.exitstatus
    assert_match(/UNKNOWN SUBMISSION OUTCOME/, err)
    document = JSON.parse(out)
    assert_equal "unknown_submission_outcome", document.dig("error", "code")
    key = document.dig("error", "idempotency_key")
    assert_match(/\A[0-9a-f]{64}\z/, key)
    assert_includes err, key
    assert_equal "demo:new", document.dig("error", "target")
    out, err, status = hive("new", "demo", "same request", "--idempotency-key", key, "--json")
    assert status.success?, err
    assert JSON.parse(out).fetch("ok")
    posts = @server.requests.select { |request| request.fetch(:method) == "POST" }
    assert_equal 2, posts.length
    assert_equal posts.first.fetch(:body), posts.last.fetch(:body)
    assert_equal [ key ], posts.map { |request| request.dig(:headers, "idempotency-key") }.uniq
  end

  def test_another_process_switching_selection_cannot_retarget_an_inflight_mutation
    select_remote
    other = RemoteTlsServer.new(root: @root) { |request| response_for(request) }
    @additional_servers << other
    @contexts.add("other", url: other.url, token: "another-bearer")
    @trust_file = File.join(@root, "both-ca.pem")
    File.write(@trust_file, File.read(@server.certificate_path) + File.read(other.certificate_path))
    switched = false
    @handler = lambda do |request|
      if request.fetch(:path) == "/api/v1/context" && !switched
        switched = true
        _out, err, status = hive("context", "use", "other", "--json")
        raise err unless status.success?
      end
      response_for(request)
    end
    out, err, status = hive("new", "demo", "pinned request", "--json")
    assert status.success?, err
    assert JSON.parse(out).fetch("ok")
    assert_equal "other", @contexts.resolve.fetch("name")
    assert_equal 1, @server.requests.count { |request| request.fetch(:method) == "POST" }
    assert_equal [ "GET" ], other.requests.map { |request| request.fetch(:method) }
    assert_equal "Bearer secret-bearer", @server.requests.last.dig(:headers, "authorization")
  end

  def test_failed_context_selection_and_retired_api_guidance_never_select_unverified_credentials
    @contexts.add("nas", url: @server.url, token: "secret-bearer")
    @handler = ->(*) { :disconnect }
    out, err, status = hive("context", "use", "nas", "--json")
    refute status.success?
    assert_equal false, JSON.parse(out).fetch("ok")
    assert_equal "local", @contexts.resolve.fetch("name")
    @handler = ->(*) { [ 404, {}, { "schema" => "hive-remote", "schema_version" => 1, "ok" => false,
      "instance_id" => nil, "error" => { "code" => "unsupported_version", "message" => "secret-bearer",
        "served_base_paths" => [ "/api/v2", "/secret-bearer" ] } } ] }
    out, err, status = hive("context", "use", "nas", "--json")
    assert_equal 78, status.exitstatus
    assert_equal "config", JSON.parse(out).fetch("error_kind")
    assert_equal false, JSON.parse(out).fetch("ok")
    assert_match(%r{/api/v2}, err)
    refute_includes out + err, "secret-bearer"
    assert_equal "local", @contexts.resolve.fetch("name")
  end

  def test_new_public_commands_have_safe_schema_valid_predispatch_errors
    [ [ %w[context add nas accidental-literal-token --json], "hive-context" ],
     [ %w[token create accidental-literal-token extra --json], "hive-token" ],
     [ %w[token create --token accidental-literal-token --json], "hive-token" ],
     [ %w[operation --json], "hive-operation" ] ].each do |args, schema|
      out, err, status = hive(*args)
      assert_equal 64, status.exitstatus, err
      document = JSON.parse(out)
      assert_equal schema, document.fetch("schema")
      assert_empty JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema)))).validate(document).to_a
      refute_includes out + err, "accidental-literal-token"
    end
    assert_empty @server.requests
  end

  def test_accidental_literal_bearers_are_rejected_before_local_token_administration
    bearer = "a" * 24 + "." + "b" * 64
    [ [ "token", "revoke", bearer, "--json" ],
     [ "token", "create", "--name=#{bearer}", "--scopes", "read", "--all-projects", "--json" ] ].each do |args|
      out, err, status = hive(*args)
      assert_equal 64, status.exitstatus
      assert_equal "hive-token", JSON.parse(out).fetch("schema")
      refute_includes out + err, bearer
      refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
    end
  end

  def test_local_token_grammar_rejects_unknown_actions_ids_and_wrong_action_options_before_runtime
    [ %w[token invalid --json], %w[token revoke bad-id --json], %w[token list --scopes read --json],
     %w[approve demo:task-1 --generation invalid --json] ].each do |args|
      out, err, status = hive(*args)
      assert_equal 64, status.exitstatus
      assert_equal false, JSON.parse(out).fetch("ok")
      refute File.exist?(File.join(@home, "runtime-control-plane.sqlite3"))
    end
  end

  private

  def select_remote
    @contexts.add("nas", url: @server.url, token: "secret-bearer")
    @contexts.use("nas")
  end

  def hive(*args, stdin: "")
    Open3.capture3(environment, RbConfig.ruby, HIVE, *args, stdin_data: stdin, chdir: @checkout)
  end

  def environment
    { "HIVE_HOME" => @home, "SSL_CERT_FILE" => @trust_file || @server.certificate_path,
      "GEM_PATH" => HIVE_TEST_PARENT_GEM_PATH }
  end

  def response_for(request)
    data = if request.fetch(:method) == "POST"
      { "operation_id" => OPERATION, "command_receipt" => { "id" => OPERATION, "generation" => 0, "state" => "succeeded" },
        "task_id" => "1", "slug" => "task-1", "stage" => "1-inbox", "queued" => false, "state" => "succeeded" }
    elsif request.fetch(:path) == "/api/v1/context"
      @metadata
    elsif request.fetch(:path).include?("/operations/")
      { "id" => OPERATION, "command" => "new", "state" => "succeeded", "command_outcome" => "succeeded",
        "result_available" => true, "result_expired" => false, "acknowledgement" => {}, "progress" => nil }
    elsif request.fetch(:path).end_with?("/tasks/task-1")
      { "task" => { "stage" => "2-brainstorm", "slug" => "task-1" }, "approval_generation" => "a" * 64 }
    elsif request.fetch(:path).end_with?("/diff")
      { "state" => "available", "sections" => { "committed" => "diff content" }, "truncated" => false }
    elsif request.fetch(:path).end_with?("/artifacts")
      { "state" => "available", "records" => [ { "id" => "opaque-artifact", "name" => "result.md" } ] }
    else
      { "state" => "available", "content" => "artifact content" }
    end
    [ 200, {}, RemoteTlsServer.envelope(data) ]
  end

  def checkout_snapshot
    Dir.glob(File.join(@checkout, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [ path.delete_prefix(@checkout), File.binread(path) ] }
  end
end
