# frozen_string_literal: true

require "test_helper"
require "net/http"
require "open3"
require "tempfile"
require "timeout"
require_relative "../support/remote_tls_server"

class RemoteAccessAcceptanceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  HIVE = File.join(ROOT, "bin/hive")
  SERVER = File.join(ROOT, "test/fixtures/remote_api_server.rb")

  def setup
    @root = Dir.mktmpdir("hive-remote-acceptance")
    @server_root = File.join(@root, "server")
    @client_home = File.join(@root, "client-home")
    @checkout = File.join(@root, "unrelated", "remote-project")
    FileUtils.mkdir_p([ @server_root, @checkout ])
    @processes = []
    @server = start_server
    @proxy = RemoteTlsServer.new(root: @root) { |request| proxy(request) }
  end

  def teardown
    @proxy&.close
    @processes.reverse_each { |process| stop_process(process) }
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_remote_creation_approval_and_progress_leave_the_same_named_local_project_unchanged
    initialize_client_project
    before = checkout_inventory
    connect
    document = successful("status", "--json")
    assert_equal "hive-remote", document.fetch("schema")
    assert_equal [ project ], document.dig("data", "projects").map { |row| row.fetch("name") }
    assert_equal 4, document.dig("data", "task_count")
    refute_includes JSON.generate(document), fixture.fetch("private_project")
    refute_includes JSON.generate(document), "private-only-secret"

    key = SecureRandom.hex(24)
    created = successful("new", project, "Remote-only acceptance idea", "--idempotency-key", key, "--json").fetch("data")
    assert_equal true, created.fetch("created")
    assert File.directory?(File.join(@server_root, "remote-project", ".hive-state", "stages", "1-inbox", created.fetch("slug")))
    post = @proxy.requests.reverse.find { |request| request.fetch(:method) == "POST" }
    notice = post.fetch(:notice)
    %W[context=server #{@proxy.url} #{document.fetch('instance_id')} create #{project} #{key}].each do |value|
      assert_includes notice, value
    end
    refute_includes notice, fixture.fetch("token")

    task = successful("task", fixture.fetch("approval_task"), "--project", project, "--json").fetch("data")
    approval = successful("approve", fixture.fetch("approval_task"), "--project", project,
      "--from", "1-inbox", "--generation", task.fetch("approval_generation"), "--json").fetch("data")
    worker = start_daemon(approval.fetch("request_id"))
    result = finish_daemon(worker)
    assert_equal "succeeded", result.fetch("outcome")
    operation = successful("operation", approval.fetch("operation_id"), "--project", project, "--json").fetch("data")
    assert_equal "succeeded", operation.fetch("state")
    assert File.directory?(File.join(@server_root, "remote-project", ".hive-state", "stages", "2-brainstorm", fixture.fetch("approval_task")))
    assert_equal before, checkout_inventory

    requests = @proxy.requests.length
    denied("init", @checkout, "--json")
    assert_equal requests, @proxy.requests.length
    successful("--context", "local", "status", "--json")
    assert_equal requests, @proxy.requests.length
    assert_equal before, checkout_inventory
  end

  def test_each_scope_works_alone_and_operation_lookup_respects_principal_and_project_grants
    connect
    %w[read create act answer other all].each { |name| connect(name, token: token(name)) }
    all = successful("--context", "all", "status", "--json").fetch("data")
    assert_equal [ fixture.fetch("private_project"), project ].sort, all.fetch("projects").map { |row| row.fetch("name") }.sort
    assert_equal 5, all.fetch("task_count")
    %w[create act answer].each do |name|
      failure = denied("--context", name, "status", "--json")
      assert_equal "insufficient_scope", failure.dig("error", "code")
    end

    creation = successful("--context", "create", "new", project, "Create scope alone",
      "--idempotency-key", SecureRandom.hex(24), "--json").fetch("data")
    assert_equal "succeeded", successful("--context", "create", "operation", creation.fetch("operation_id"),
      "--project", project, "--json").dig("data", "state")
    other = denied("--context", "other", "operation", creation.fetch("operation_id"), "--project", project, "--json")
    assert_equal "remote", other.fetch("error_kind")
    assert_match(/unavailable or inaccessible/, other.fetch("message"))
    assert_equal creation.fetch("operation_id"), successful("--context", "read", "operation", creation.fetch("operation_id"),
      "--project", project, "--json").dig("data", "id")
    foreign = denied("--context", "read", "operation", creation.fetch("operation_id"),
      "--project", fixture.fetch("private_project"), "--json")
    assert_equal "remote", foreign.fetch("error_kind")
    assert_match(/unavailable or inaccessible/, foreign.fetch("message"))

    task = successful("--context", "server", "task", fixture.fetch("task"), "--project", project, "--json").fetch("data")
    action = task.fetch("actions").first
    accepted = successful("--context", "act", "act", action.fetch("action_id"), fixture.fetch("task"),
      "--project", project, "--observation", action.fetch("observation_token"), "--json").fetch("data")
    assert_equal "queued", successful("--context", "act", "operation", accepted.fetch("operation_id"),
      "--project", project, "--json").dig("data", "state")

    inventory = successful("--context", "server", "answer", fixture.fetch("question_task"), "--project", project, "--json").fetch("data")
    handle = inventory.fetch("slots").first.fetch("handle")
    answered = successful("--context", "answer", "answer", fixture.fetch("question_task"), "--project", project,
      "--binding", handle, "--json", stdin: "Literal answer $HOME `unexecuted`\n").fetch("data")
    assert_equal "written", answered.fetch("outcome")
    assert_equal "succeeded", successful("--context", "answer", "operation", answered.fetch("operation_id"),
      "--project", project, "--json").dig("data", "state")
    assert_includes File.read(File.join(@server_root, "remote-project", ".hive-state", "stages", "2-brainstorm",
      fixture.fetch("question_task"), "brainstorm.md")), "Literal answer $HOME `unexecuted`"

    approval_task = successful("--context", "server", "task", fixture.fetch("approval_task"), "--project", project, "--json").fetch("data")
    approval = successful("--context", "answer", "approve", fixture.fetch("approval_task"), "--project", project,
      "--from", "1-inbox", "--generation", approval_task.fetch("approval_generation"), "--json").fetch("data")
    assert_equal "queued", successful("--context", "answer", "operation", approval.fetch("operation_id"),
      "--project", project, "--json").dig("data", "state")
    assert_equal "401", request("GET", "/api/v1/context", bearer: token("expired")).code
    denied("context", "add", "expired", "--url", @proxy.url, "--token-stdin", "--json", stdin: "#{token('expired')}\n")
    revoke(token_record("create").fetch("id"))
    revoked = denied("--context", "create", "operation", creation.fetch("operation_id"), "--project", project, "--json")
    assert_equal "remote", revoked.fetch("error_kind")
    assert_match(/bearer|token/, revoked.fetch("message"))
  end

  def test_lost_acceptance_survives_restart_and_revocation_then_a_separate_daemon_executes_it
    initialize_client_project
    before = checkout_inventory
    connect
    connect("act", token: token("act"))
    task = successful("--context", "server", "task", fixture.fetch("task"), "--project", project, "--json").fetch("data")
    action = task.fetch("actions").first
    key = SecureRandom.hex(24)
    arguments = [ "--context", "act", "act", action.fetch("action_id"), fixture.fetch("task"), "--project", project,
      "--observation", action.fetch("observation_token"), "--idempotency-key", key, "--json" ]
    @drop_next_accepted = true
    out, err, status = hive(*arguments)
    refute status.success?, out
    assert_includes err, key
    assert_includes err, @proxy.url
    refute File.exist?(File.join(@server_root, "remote-project", ".hive-state", "stages", "3-plan", fixture.fetch("task"), "plan.md"))
    assert_equal 1, @proxy.requests.count { |request| request.fetch(:method) == "POST" }
    stop_process(@server)
    @server = start_server(server_context: true)
    assert_equal "elsewhere", fixture.fetch("selected_client_context")
    acknowledgement = successful(*arguments).fetch("data")
    assert_equal "queued", successful("--context", "act", "operation", acknowledgement.fetch("operation_id"),
      "--project", project, "--json").dig("data", "state")
    worker = start_daemon(acknowledgement.fetch("request_id"))
    running = successful("--context", "act", "operation", acknowledgement.fetch("operation_id"), "--project", project, "--json").fetch("data")
    assert_equal "running", running.fetch("state")
    assert_equal worker.fetch(:started).fetch("attempt_id"), running.dig("progress", "attempt_id")
    revoke(token_record("act").fetch("id"))
    revoked = denied("--context", "act", "operation", acknowledgement.fetch("operation_id"), "--project", project, "--json")
    assert_equal "remote", revoked.fetch("error_kind")
    assert_match(/bearer|token/, revoked.fetch("message"))
    result = finish_daemon(worker)
    assert_equal "succeeded", result.fetch("outcome"), result.inspect
    assert result.fetch("events").any? { |event| event.fetch("name") == "dispatch_request_dispatched" &&
      event.fetch("attributes")["request_id"] == acknowledgement.fetch("request_id") }
    fresh_home = File.join(@root, "fresh-client-home")
    connect("fresh", home: fresh_home)
    operation = successful("operation", acknowledgement.fetch("operation_id"), "--project", project, "--json", home: fresh_home).fetch("data")
    assert_equal "succeeded", operation.fetch("state")
    assert_equal acknowledgement, operation.fetch("acknowledgement")
    assert File.file?(File.join(@server_root, "remote-project", ".hive-state", "stages", "3-plan", fixture.fetch("task"), "plan.md"))
    assert_equal before, checkout_inventory
  end

  def test_denied_scopes_projects_administration_and_indirect_release_leave_both_projects_unchanged
    initialize_client_project
    connect
    connect("read", token: token("read"))
    before_client = checkout_inventory
    before_server = server_inventory
    denied("--context", "read", "new", project, "Denied create", "--json")
    denied("--context", "server", "new", fixture.fetch("private_project"), "Denied project", "--json")
    %w[forget drop archive runtime token update finalize workflow].each do |command|
      count = @proxy.requests.length
      denied("--context", "server", command, project, "--json")
      assert_equal count, @proxy.requests.length
    end
    task = successful("--context", "server", "task", fixture.fetch("release_task"), "--project", project, "--json").fetch("data")
    assert_equal "workflow.retry", task.fetch("actions").first.fetch("action_id")
    %w[release workflow.advance delete].each do |action|
      document = denied("--context", "server", "act", action, fixture.fetch("release_task"), "--project", project,
        "--observation", "0" * 64, "--json")
      assert_equal false, document.fetch("ok")
    end
    retry_action = fixture.fetch("release_action")
    assert_equal "workflow.retry", retry_action.fetch("action_id")
    request("POST", "/api/v1/projects/#{project}/tasks/#{fixture.fetch('release_task')}/actions",
      payload: { action_id: retry_action.fetch("action_id"), observation: retry_action.fetch("observation_token"),
        argv: [ "hive", "workflow", "publish" ], idempotency_key: SecureRandom.hex(24) })
      .then { |response| assert_equal "400", response.code }
    assert_includes %w[400 404], request("DELETE", "/api/v1/projects/#{project}/tasks/#{fixture.fetch('task')}").code
    after_server = server_inventory
    differences = before_server.flat_map do |name, inventory|
      (inventory.keys | after_server.fetch(name).keys).filter_map do |path|
        [ name, path ] if inventory[path] != after_server.fetch(name)[path]
      end
    end
    assert_empty differences
    assert_equal before_client, checkout_inventory
  end

  def test_supported_proxy_preserves_loopback_owner_and_bearer_interlocks
    bearer = fixture.fetch("token")
    stop_process(@server)
    @server = start_server(loopback: "1")
    loopback = request("GET", "/api/v1/context", bearer: bearer)
    assert_equal "503", loopback.code
    stop_process(@server)
    @server = start_server(ownerless: true)
    ownerless = request("GET", "/api/v1/context", bearer: bearer)
    assert_equal "503", ownerless.code
    assert_equal loopback.body, ownerless.body
    assert_equal "404", request("GET", "/", bearer: nil, cookie: "owner=operator").code
    assert_equal "404", request("GET", "/tasks", bearer: nil, cookie: "owner=operator").code
    out, err, status = hive("--context", "local", "token", "create", "--name", "ownerless", "--scopes", "read", "--projects", project, "--json",
      home: File.join(@server_root, "hive-home"))
    refute status.success?, out
    assert_match(/web.github.owner/, err)
    stop_process(@server)
    @server = start_server(loopback: "0")
    assert_equal "401", request("GET", "/api/v1/context", bearer: nil, cookie: "owner=operator").code
    assert_equal "200", request("GET", "/api/v1/context", bearer: bearer).code
  end

  private

  def fixture = @server.fetch(:fixture)
  def project = fixture.fetch("project")
  def token_record(name) = fixture.fetch("tokens").fetch(name)
  def token(name) = token_record(name).fetch("token")

  def connect(name = "server", token: fixture.fetch("token"), home: @client_home)
    added = successful("context", "add", name, "--url", @proxy.url, "--token-stdin", "--json", stdin: "#{token}\n", home: home)
    assert_equal "hive-context", added.fetch("schema")
    selected = successful("context", "use", name, "--json", home: home)
    assert_equal "hive-context", selected.fetch("schema")
  end

  def successful(*args, **options)
    out, err, status = hive(*args, **options)
    assert status.success?, "#{args.inspect}: #{err}\n#{out}"
    document = JSON.parse(out)
    assert_equal true, document.fetch("ok"), out
    refute_includes out + err, fixture.fetch("token")
    document
  end

  def denied(*args, **options)
    out, err, status = hive(*args, **options)
    refute status.success?, "#{args.inspect}: #{out} #{err}"
    assert_equal false, JSON.parse(out).fetch("ok"), out
    JSON.parse(out)
  end

  def initialize_client_project
    system("git", "init", "-q", @checkout, exception: true)
    system("git", "-C", @checkout, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", @checkout, "config", "user.name", "Client Test", exception: true)
    File.write(File.join(@checkout, "README.md"), "# Unrelated same-named client project\n")
    system("git", "-C", @checkout, "add", ".", exception: true)
    system("git", "-C", @checkout, "commit", "-qm", "initial", exception: true)
    out, err, status = hive("--context", "local", "init", @checkout)
    assert status.success?, "#{out}\n#{err}"
  end

  def inventory(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
      relative = path.delete_prefix("#{root}/")
      stat = File.lstat(path)
      value = stat.symlink? ? [ "symlink", File.readlink(path) ] : stat.file? ? [ "file", Digest::SHA256.file(path).hexdigest ] : [ "directory" ]
      [ relative, value ]
    end
  end

  def checkout_inventory
    { "files" => inventory(@checkout), "head" => git("rev-parse", "HEAD"), "status" => git("status", "--porcelain=v1"),
      "branches" => git("for-each-ref", "--format=%(refname) %(objectname)") }
  end

  def server_inventory
    %w[remote-project private-project].to_h { |name| [ name, inventory(File.join(@server_root, name)) ] }
  end

  def git(*args)
    out, status = Open3.capture2("git", "-C", @checkout, *args)
    assert status.success?
    out
  end

  def revoke(id)
    out, err, status = hive("--context", "local", "token", "revoke", id, "--json", home: File.join(@server_root, "hive-home"))
    assert status.success?, "#{out}\n#{err}"
  end

  def start_daemon(request_id)
    output, writer = IO.pipe
    log = Tempfile.new("hive-remote-acceptance-daemon")
    environment = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "GEM_PATH" => HIVE_TEST_PARENT_GEM_PATH,
      "HIVE_HOME" => File.join(@server_root, "hive-home") }
    pid = Process.spawn(environment, RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}",
      File.join(ROOT, "test/fixtures/remote_acceptance_daemon.rb"), request_id, chdir: ROOT, out: writer, err: log.path)
    writer.close
    worker = { pid: pid, output: output, log: log }
    @processes << worker
    worker[:started] = read_worker(worker)
    assert_equal "running", worker.fetch(:started).fetch("state")
    worker
  end

  def read_worker(worker)
    Timeout.timeout(35) do
      loop do
        line = worker.fetch(:output).gets
        raise "daemon fixture exited: #{File.read(worker.fetch(:log).path)}" unless line
        break JSON.parse(line) if line.start_with?("{")
      end
    end
  end

  def finish_daemon(worker)
    document = read_worker(worker)
    _, status = Process.wait2(worker.fetch(:pid))
    worker[:stopped] = true
    worker.fetch(:output).close
    log = File.read(worker.fetch(:log).path)
    worker.fetch(:log).close!
    assert status.success?, log
    assert_equal "finished", document.fetch("state")
    document
  end

  def request(method, path, bearer: fixture.fetch("token"), payload: nil, cookie: nil)
    uri = URI("#{@proxy.url}#{path}")
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = true
    http.ca_file = @proxy.certificate_path
    http.max_retries = 0
    headers = {}
    headers["Content-Type"] = "application/json" if payload
    headers["Authorization"] = "Bearer #{bearer}" if bearer
    headers["Cookie"] = cookie if cookie
    request = Net::HTTPGenericRequest.new(method, !payload.nil?, true, path, headers)
    request.body = JSON.generate(payload) if payload
    http.request(request)
  end

  def start_server(loopback: "0", ownerless: false, server_context: false)
    output, writer = IO.pipe
    log = Tempfile.new("hive-remote-acceptance-server")
    environment = {
      "BUNDLE_GEMFILE" => File.join(ROOT, "web/Gemfile"), "GEM_PATH" => HIVE_TEST_PARENT_GEM_PATH,
      "HIVE_REMOTE_FIXTURE_ROOT" => @server_root, "HIVE_REMOTE_ACCEPTANCE" => "1",
      "HIVE_REMOTE_PRESERVE_LOOPBACK" => "1", "HIVE_WEB_LOCAL_LOOPBACK" => loopback,
      "HIVE_REMOTE_OWNERLESS" => ownerless ? "1" : "0",
      "HIVE_REMOTE_SERVER_CONTEXT" => server_context ? "1" : "0"
    }.merge(fake_provider_environment)
    pid = Process.spawn(environment, RbConfig.ruby, SERVER, chdir: File.join(ROOT, "web"), out: writer, err: log.path)
    writer.close
    process = { pid: pid, output: output, log: log }
    @processes << process
    process[:fixture] = Timeout.timeout(30) do
      loop do
        line = output.gets
        raise "remote fixture exited: #{File.read(log.path)}" unless line
        break JSON.parse(line) if line.start_with?("{")
      end
    end
    process
  end

  def stop_process(process)
    return if process[:stopped]

    Process.kill("TERM", process.fetch(:pid))
    Process.wait(process.fetch(:pid))
    process.fetch(:output).close if process[:output]
    process.fetch(:log).close!
    process[:stopped] = true
  rescue Errno::ESRCH, Errno::ECHILD
    process[:stopped] = true
  end

  def proxy(request)
    return [ 404, {}, { "error" => "not found" } ] unless request.fetch(:path).start_with?("/api/v1/")

    request[:notice] = File.read(@active_stderr) if request.fetch(:method) == "POST" && @active_stderr
    http = Net::HTTP.new("127.0.0.1", @server.fetch(:fixture).fetch("port"), nil)
    http.max_retries = 0
    http.read_timeout = 20
    headers = request.fetch(:headers).slice("authorization", "content-type", "cookie", "idempotency-key")
    headers["Host"] = "127.0.0.1"
    forwarded = Net::HTTPGenericRequest.new(request.fetch(:method), !request.fetch(:body).empty?, true,
      request.fetch(:path), headers)
    forwarded.body = request.fetch(:body) unless request.fetch(:body).empty?
    response = http.request(forwarded)
    if @drop_next_accepted && request.fetch(:method) == "POST" && response.code.to_i.between?(200, 299)
      @drop_next_accepted = false
      :disconnect
    else
      [ response.code.to_i, {}, response.body ]
    end
  end

  def hive(*args, stdin: "", home: @client_home)
    log = Tempfile.new("hive-remote-acceptance-cli")
    @active_stderr = log.path
    out, status = Open3.capture2({ "HIVE_HOME" => home, "GEM_PATH" => HIVE_TEST_PARENT_GEM_PATH,
      "SSL_CERT_FILE" => @proxy.certificate_path }.merge(fake_provider_environment), RbConfig.ruby, HIVE, *args,
      stdin_data: stdin, chdir: @checkout, err: log.path)
    [ out, File.read(log.path), status ]
  ensure
    @active_stderr = nil
    log&.close!
  end

  def fake_provider_environment
    { "HIVE_CLAUDE_BIN" => File.join(ROOT, "test/fixtures/fake-claude"),
      "HIVE_CODEX_BIN" => File.join(ROOT, "test/fixtures/fake-codex"),
      "HIVE_PI_BIN" => "/usr/bin/false", "HIVE_OPENCODE_BIN" => "/usr/bin/false",
      "HIVE_GROK_BIN" => "/usr/bin/false", "HIVE_MUSE_BIN" => "/usr/bin/false",
      "HIVE_FAKE_CLAUDE_LOG_DIR" => File.join(@root, "fake-agent-logs"),
      "HIVE_FAKE_CODEX_LOG_DIR" => File.join(@root, "fake-agent-logs") }
  end
end
