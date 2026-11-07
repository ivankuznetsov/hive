# frozen_string_literal: true

require "test_helper"
require "net/http"
require "timeout"
require "tempfile"

class RemoteOperationsIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SERVER = File.join(ROOT, "test/fixtures/remote_api_server.rb")

  def test_disconnected_acceptance_survives_server_restart_and_replays_through_a_new_http_client
    Dir.mktmpdir("hive-remote-transport") do |root|
      first_server = start_server(root, drop: true)
      payload = { "text" => "Persist after disconnect", "slug" => "disconnect-260923-abcd", "idempotency_key" => "lost-response" }
      begin
        assert_raises(EOFError, IOError) { request(first_server, "POST", "/tasks", payload) }
      ensure
        stop_server(first_server)
      end

      restarted = start_server(root)
      begin
        response = request(restarted, "POST", "/tasks", payload)
        assert_equal "200", response.code, response.body
        acknowledgement = JSON.parse(response.body).fetch("data")
        id = acknowledgement.fetch("operation_id")
        response = request(restarted, "GET", "/operations/#{id}")
        assert_equal "200", response.code, response.body
        operation = JSON.parse(response.body).fetch("data")
        assert_equal "succeeded", operation.fetch("state")
        assert_equal true, operation.fetch("result_available")
        assert_equal acknowledgement, operation.fetch("acknowledgement")
        refute_includes response.body, root
        refute_includes response.body, "Persist after disconnect"
        response = request(restarted, "POST", "/tasks", payload.merge("text" => "Different input"))
        assert_equal "409", response.code, response.body
      ensure
        stop_server(restarted)
      end
    end
  end

  def test_long_native_work_continues_after_disconnected_http_acceptance_and_new_client_observes_progress
    Dir.mktmpdir("hive-remote-worker") do |root|
      server = start_server(root, drop: true, dispatch: true)
      begin
        fixture = server.fetch(:fixture)
        descriptor = fixture.fetch("action")
        suffix = "/tasks/#{fixture.fetch('task')}/actions"
        payload = { "action_id" => descriptor.fetch("action_id"), "observation" => descriptor.fetch("observation_token"), "idempotency_key" => "long-disconnect" }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(EOFError, IOError) { request(server, "POST", suffix, payload) }
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
        response = request(server, "POST", suffix, payload)
        assert_equal "202", response.code, response.body
        acknowledgement = JSON.parse(response.body).fetch("data")
        operation_path = "/operations/#{acknowledgement.fetch('operation_id')}"
        response = request(server, "GET", operation_path)
        assert_equal "200", response.code, response.body
        operation = JSON.parse(response.body).fetch("data")
        assert_includes %w[queued running], operation.fetch("state")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
        until %w[succeeded failed unresolved].include?(operation.fetch("state"))
          flunk "detached work did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.05
          response = request(server, "GET", operation_path)
          assert_equal "200", response.code, response.body
          operation = JSON.parse(response.body).fetch("data")
        end
        assert_equal "succeeded", operation.fetch("state"), operation.inspect
        assert_equal "succeeded", operation.fetch("command_outcome")
        assert_equal acknowledgement, operation.fetch("acknowledgement")
        assert operation.dig("progress", "attempt_id")
        refute_includes response.body, root
      ensure
        stop_server(server)
      end
    end
  end

  private

  def start_server(root, drop: false, dispatch: false)
    output, writer = IO.pipe
    log = Tempfile.new("hive-remote-server-log")
    environment = {
      "BUNDLE_GEMFILE" => File.join(ROOT, "web/Gemfile"), "HIVE_REMOTE_FIXTURE_ROOT" => root,
      "HIVE_REMOTE_DROP_ACCEPTED" => drop ? "1" : "0", "HIVE_REMOTE_DISPATCH_ACCEPTED" => dispatch ? "1" : "0"
    }
    pid = Process.spawn(environment, RbConfig.ruby, SERVER, chdir: File.join(ROOT, "web"), out: writer, err: log.path)
    writer.close
    fixture = Timeout.timeout(30) do
      loop do
        line = output.gets
        raise "remote fixture exited: #{File.read(log.path)}" unless line
        break JSON.parse(line) if line.start_with?("{")
      end
    end
    { pid: pid, fixture: fixture, output: output, log: log }
  rescue Exception
    Process.kill("TERM", pid) if pid
    Process.wait(pid) if pid
    output&.close
    log&.close!
    raise
  end

  def stop_server(server)
    Process.kill("TERM", server.fetch(:pid))
    Process.wait(server.fetch(:pid))
    server.fetch(:output).close
    server.fetch(:log).close!
  end

  def request(server, method, suffix, payload = nil)
    fixture = server.fetch(:fixture)
    path = "/api/v1/projects/#{fixture.fetch('project')}#{suffix}"
    http = Net::HTTP.new("127.0.0.1", fixture.fetch("port"), nil)
    http.max_retries = 0
    http.read_timeout = 20
    headers = { "Authorization" => "Bearer #{fixture.fetch('token')}", "Content-Type" => "application/json" }
    request = Net::HTTPGenericRequest.new(method, !payload.nil?, true, path, headers)
    request.body = JSON.generate(payload) if payload
    http.request(request)
  end
end
