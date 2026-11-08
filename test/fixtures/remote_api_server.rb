# frozen_string_literal: true

# A real Rack application over a small HTTP socket. Killing and restarting this
# process preserves the fixture's native runtime database and receipt namespace.
require "bundler/setup"
require "json"
require "socket"
require "stringio"
require "fileutils"
require "yaml"

root = ENV.fetch("HIVE_REMOTE_FIXTURE_ROOT")
ENV["HIVE_HOME"] = File.join(root, "hive-home")
ENV["RAILS_ENV"] = "test"
ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = "1"
ENV["HIVE_CLAUDE_BIN"] ||= File.expand_path("fake-claude", __dir__)
ENV["HIVE_CODEX_BIN"] ||= File.expand_path("fake-codex", __dir__)
%w[PI GROK OPENCODE MUSE].each { |provider| ENV["HIVE_#{provider}_BIN"] ||= "/usr/bin/false" }
ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] ||= File.join(root, "fake-agent-logs")
ENV["HIVE_FAKE_CODEX_LOG_DIR"] ||= File.join(root, "fake-agent-logs")
ENV.delete("HIVE_WEB_LOCAL_LOOPBACK") unless ENV["HIVE_REMOTE_PRESERVE_LOOPBACK"] == "1"
ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
FileUtils.mkdir_p(ENV.fetch("HIVE_HOME"))
require_relative "../../web/config/environment"
require "hive/commands/init"
require "hive/runtime_control_plane/installation"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/remote/token_store"
require "hive/operational_action"
require "rack/mock"

Hive::RuntimeControlPlane::Installation.setup(state_home: ENV.fetch("HIVE_HOME"))
Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
  database: Hive::RuntimeControlPlane.database,
  package_coordinates: { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 }
)
fixture_path = File.join(root, "fixture.json")
if File.file?(fixture_path)
  fixture = JSON.parse(File.read(fixture_path))
else
  File.write(File.join(ENV.fetch("HIVE_HOME"), "config.yml"), {
    "web" => { "origin" => "http://127.0.0.1", "github" => { "owner" => "operator" } }
  }.to_yaml)
  repo = File.join(root, "remote-project")
  FileUtils.mkdir_p(repo)
  system("git", "init", "-q", repo, exception: true)
  system("git", "-C", repo, "config", "user.email", "test@example.com", exception: true)
  system("git", "-C", repo, "config", "user.name", "Remote Test", exception: true)
  File.write(File.join(repo, "README.md"), "# Remote fixture\n")
  system("git", "-C", repo, "add", ".", exception: true)
  system("git", "-C", repo, "commit", "-qm", "initial", exception: true)
  original_stdout = $stdout
  begin
    $stdout = StringIO.new
    Hive::Commands::Init.new(repo).call
  ensure
    $stdout = original_stdout
  end
  project = Hive::Config.registered_projects.find { |entry| entry.fetch("path") == repo }
  config_path = File.join(project.fetch("hive_state_path"), "config.yml")
  config = YAML.safe_load_file(config_path)
  config["command_receipts"] = { "keyed_intake_enabled" => true }
  File.write(config_path, config.to_yaml)
  token = Hive::Remote::TokenStore.new.create(name: "transport", scopes: %w[read create act answer], projects: [ project.fetch("name") ])
  fixture = { "project" => project.fetch("name"), "token" => token.fetch("token") }
  File.write(fixture_path, JSON.generate(fixture), mode: "w", perm: 0o600)
end

if ENV["HIVE_REMOTE_ACCEPTANCE"] == "1"
  require_relative "remote_acceptance_setup"
  fixture = RemoteAcceptanceSetup.prepare(root: root, fixture: fixture)
end

if ENV["HIVE_REMOTE_DISPATCH_ACCEPTED"] == "1"
  project = Hive::Config.find_project(fixture.fetch("project"))
  slug = "slow-worker-260923-abcd"
  folder = File.join(project.fetch("hive_state_path"), "stages", "2-brainstorm", slug)
  unless File.directory?(folder)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: 42, slug: slug, display_name: "Slow detached worker", workflow: "coding")
    File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
  end
  task = Hive::Task.new(folder)
  fixture["task"] = slug
  fixture["action"] = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
  ENV["HIVE_CLAUDE_BIN"] = File.expand_path("fake-claude", __dir__)
  ENV["HIVE_CODEX_BIN"] = ENV.fetch("HIVE_CLAUDE_BIN")
  ENV["HIVE_FAKE_CLAUDE_BEFORE_WRITE_RELEASE_FILE"] = File.join(root, "release-worker")
  ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(project.fetch("hive_state_path"), "stages", "3-plan", slug, "plan.md")
  ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Plan\n<!-- WAITING -->\n"
end

server = TCPServer.new("127.0.0.1", 0)
$stdout.puts(JSON.generate(fixture.merge("port" => server.addr[1])))
$stdout.flush
drop_response = ENV["HIVE_REMOTE_DROP_ACCEPTED"] == "1"
loop do
  socket = server.accept
  begin
    request_line = socket.gets
    next unless request_line
    method, path, = request_line.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    raw = socket.read(headers.fetch("content-length", "0").to_i)
    env = Rack::MockRequest.env_for("http://127.0.0.1#{path}", method: method, input: raw)
    headers.each do |name, value|
      key = %w[content-type content-length].include?(name) ? name.upcase.tr("-", "_") : "HTTP_#{name.upcase.tr('-', '_')}"
      env[key] = value
    end
    status, response_headers, body = Rails.application.call(env)
    bytes = +""
    body.each { |part| bytes << part }
    body.close if body.respond_to?(:close)
    dropped = drop_response && method == "POST" && status.between?(200, 299)
    if dropped
      drop_response = false
      socket.close
    else
      socket.write("HTTP/1.1 #{status} Result\r\nContent-Length: #{bytes.bytesize}\r\nConnection: close\r\nContent-Type: #{response_headers.fetch('content-type', 'application/json')}\r\n\r\n")
      socket.write(bytes)
    end
    # This is the daemon's durable admission boundary, outside Rack and after
    # the caller socket is closed. The actual native worker owns execution.
    if ENV["HIVE_REMOTE_DISPATCH_ACCEPTED"] == "1" && method == "POST" && status == 202
      acknowledgement = JSON.parse(bytes).fetch("data")
      repository = Hive::RuntimeControlPlane::DispatchRepository.open_default
      admitted_request = repository.fetch(acknowledgement.fetch("request_id"))
      Hive::Attempts::API.new.dispatch_request(admitted_request) if admitted_request&.state == "queued"
    end
  ensure
    socket.close unless socket.closed?
  end
end
