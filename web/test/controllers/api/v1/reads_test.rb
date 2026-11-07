# frozen_string_literal: true

require "test_helper"
require "hive/remote/token_store"
require "hive/remote/read_service"
require "hive/remote/question_handles"

class ApiReadsTest < ActionDispatch::IntegrationTest
  setup do
    @loopback = ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback = ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    configure_owner!(owner: "operator")
    @project = create_hive_project!("api-reads-#{SecureRandom.hex(4)}")
    @private = create_hive_project!("private-reads-#{SecureRandom.hex(4)}")
    @slug = create_task!(@project, "A visible read fixture")
    @private_slug = create_task!(@private, "Invisible secret fixture")
    @issued = Hive::Remote::TokenStore.new.create(name: "reader", scopes: %w[read act answer], projects: [ @project ])
    @headers = { "Authorization" => "Bearer #{@issued.fetch('token')}" }
    @path = "/api/v1/projects/#{@project}/tasks/#{@slug}"
  end

  teardown do
    @loopback ? ENV["HIVE_WEB_LOCAL_LOOPBACK"] = @loopback : ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback ? ENV["HIVEBOX_LOCAL_LOOPBACK"] = @legacy_loopback : ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
  end

  test "status scans only authorized projects and exposes explicit semantic fields" do
    seen = nil
    original = Hive::Remote::ReadService.instance_method(:status)
    Hive::Remote::ReadService.define_method(:status) do |projects:|
      seen = projects.map { |project| project.fetch("name") }
      original.bind_call(self, projects: projects)
    end
    get "/api/v1/status", headers: @headers
    assert_response :success
    assert_equal [ @project ], seen
    data = response.parsed_body.fetch("data")
    assert_equal 1, data.fetch("task_count")
    assert_equal [ @slug ], data.fetch("tasks").map { |task| task.fetch("slug") }
    refute_includes response.body, @private
    refute_includes response.body, ENV.fetch("HIVE_TEST_HOME_ROOT")
    refute_includes response.body, "suggested_command"
    assert_equal "hive-status", data.fetch("source_schema")
  ensure
    Hive::Remote::ReadService.define_method(:status, original) if original
  end

  test "task exact lookup hides filesystem paths and binds explicit approval generation" do
    get @path, headers: @headers
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal @slug, data.dig("task", "slug")
    assert_match(/\A[0-9a-f]{64}\z/, data.fetch("approval_generation"))
    refute_includes response.body, ENV.fetch("HIVE_TEST_HOME_ROOT")
    get "/api/v1/projects/#{@private}/tasks/#{@private_slug}", headers: @headers
    assert_response :not_found
    hidden = response.parsed_body.fetch("error")
    get "/api/v1/projects/#{@project}/tasks/no-such-task", headers: @headers
    assert_response :not_found
    assert_equal hidden, response.parsed_body.fetch("error")
  end

  test "explicit status project filters authorized projects before the projection" do
    token = Hive::Remote::TokenStore.new.create(name: "both", scopes: [ "read" ], projects: [ @project, @private ])
    headers = { "Authorization" => "Bearer #{token.fetch('token')}" }
    get "/api/v1/status", params: { project: @project }, headers: headers
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal [ @project ], data.fetch("projects").map { |project| project.fetch("name") }
    assert_equal [ @slug ], data.fetch("tasks").map { |task| task.fetch("slug") }
    get "/api/v1/status", params: { project: @private }, headers: @headers
    assert_response :not_found
  end

  test "write-only token cannot read status or questions" do
    token = Hive::Remote::TokenStore.new.create(name: "writer", scopes: [ "answer" ], projects: [ @project ])
    headers = { "Authorization" => "Bearer #{token.fetch('token')}" }
    get "/api/v1/status", headers: headers
    assert_response :forbidden
    get "#{@path}/questions", headers: headers
    assert_response :forbidden
  end

  test "opaque question handles preserve native bindings only on the server and stale after edits" do
    task = brainstorm!
    File.write(task.state_file, "# Brainstorm\n\n### Q1. Which color?\n\n### A1.\n\n<!-- WAITING -->\n")
    get "#{@path}/questions", headers: @headers
    assert_response :success
    slot = response.parsed_body.fetch("data").fetch("slots").first
    refute_nil slot
    refute_includes response.body, "binding"
    refute_includes response.body, task.folder
    assert_equal "Which color?", slot.fetch("text")
    project = Hive::Config.registered_projects.find { |entry| entry["name"] == @project }
    store = Hive::Remote::QuestionHandles.new
    record = store.resolve(handle: slot.fetch("handle"), project: project, task: task)
    inventory = Hive::Remote::ReadService.new.questions(project: project, task: task)
    assert store.current!(record: record, inventory: inventory)
    File.write(task.state_file, "# Brainstorm\n\n### Q1. Different question?\n\n### A1.\n\n<!-- WAITING -->\n")
    inventory = Hive::Remote::ReadService.new.questions(project: project, task: task)
    assert_equal 409, assert_raises(Hive::Remote::Error) { store.current!(record: record, inventory: inventory) }.status
  end

  test "artifact content handles cap serialized bytes scrub invalid UTF8 and reject symlink escapes" do
    task = Hive::TaskResolver.new(@slug, project_filter: @project).resolve
    File.binwrite(task.state_file, "\"\\\n" * 2000 + "\xff".b)
    get "#{@path}/artifacts", headers: @headers
    assert_response :success
    artifact = response.parsed_body.fetch("data").fetch("records").find { |record| record["name"] == File.basename(task.state_file) }
    refute_nil artifact
    refute_includes response.body, task.folder
    get "#{@path}/artifacts/#{artifact.fetch('id')}", params: { max_bytes: 1024 }, headers: @headers
    assert_response :success
    assert_operator response.body.bytesize, :<=, 1024
    assert response.parsed_body.dig("data", "truncated")
    get "#{@path}/artifacts/#{artifact.fetch('id')}", headers: @headers
    assert_response :success
    assert response.parsed_body.dig("data", "invalid_encoding")
    File.write(task.state_file, "# Task\nChanged generation\n")
    get "#{@path}/artifacts/#{artifact.fetch('id')}", headers: @headers
    assert_response :conflict
    get "#{@path}/artifacts", headers: @headers
    artifact = response.parsed_body.dig("data", "records").find { |record| record["name"] == File.basename(task.state_file) }
    outside = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "outside-sentinel")
    File.write(outside, "private outside sentinel")
    File.unlink(task.state_file)
    File.symlink(outside, task.state_file)
    get "#{@path}/artifacts/#{artifact.fetch('id')}", headers: @headers
    assert_response :conflict
    refute_includes response.body, "private outside sentinel"
  end

  test "status pagination is opaque snapshot bound and response limits include envelope" do
    create_task!(@project, "A second visible fixture")
    get "/api/v1/status", params: { limit: 1 }, headers: @headers
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal 2, data.fetch("task_count")
    assert_equal 1, data.fetch("tasks").length
    assert data.fetch("truncated")
    cursor = data.fetch("continuation")
    assert_match(/\A[0-9a-f]{64}\z/, cursor)
    get "/api/v1/status", params: { limit: 1, cursor: cursor }, headers: @headers
    assert_response :success
    assert_equal 1, response.parsed_body.dig("data", "tasks").length
    assert_nil response.parsed_body.dig("data", "continuation")
    create_task!(@project, "A third fixture changes snapshot")
    get "/api/v1/status", params: { cursor: cursor }, headers: @headers
    assert_response :conflict
    get "/api/v1/status", params: { limit: 1000, max_bytes: 2048 }, headers: @headers
    assert_response :success
    assert_operator response.body.bytesize, :<=, 2048
  end

  test "logs and unavailable diff use bounded semantic DTOs without diagnostics" do
    get "#{@path}/logs", headers: @headers
    assert_response :success
    assert_equal "unavailable", response.parsed_body.dig("data", "state")
    get "#{@path}/diff", headers: @headers
    assert_response :success
    assert_equal "unavailable", response.parsed_body.dig("data", "state")
    refute_includes response.body, ENV.fetch("HIVE_TEST_HOME_ROOT")
    refute_includes response.body, "diagnostic"
  end

  test "unknown API versions reject before parsing mutation input and unknown v1 routes stay JSON" do
    post "/api/v99/projects/#{@project}/tasks", params: "not JSON", headers: @headers
    assert_response :not_found
    assert_equal "unsupported_version", response.parsed_body.dig("error", "code")
    assert_equal [ "/api/v1" ], response.parsed_body.dig("error", "served_base_paths")
    get "/api/v1/no-such-endpoint", headers: @headers
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    get "#{@path}/artifacts/%2e%2e%2fprivate", headers: @headers
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
  end

  test "remote question and task reads refuse oversized symlinked and nonregular state before domain reading" do
    task = brainstorm!
    File.write(task.state_file, "a" * (512 * 1024 + 1))
    get "#{@path}/questions", headers: @headers
    assert_response :content_too_large
    get @path, headers: @headers
    assert_response :content_too_large
    outside = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "escaped-question-state")
    File.write(outside, "### Q1. Private outside question?\n### A1.\n")
    File.unlink(task.state_file)
    File.symlink(outside, task.state_file)
    get "#{@path}/questions", headers: @headers
    assert_response :service_unavailable
    refute_includes response.body, "Private outside question"
    get @path, headers: @headers
    assert_response :service_unavailable
    File.unlink(task.state_file)
    File.mkfifo(task.state_file)
    get "#{@path}/questions", headers: @headers
    assert_response :service_unavailable
  end

  test "API audit closes request tagged response before emitting fixed fields" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    body = Class.new do
      def initialize(logger)
        @logger = logger
      end
      def each
        yield JSON.generate({ "ok" => true })
      end
      def close
        @logger.pop_tags
      end
    end
    app = ->(_env) do
      logger.push_tags("attacker-request-id")
      [ 200, { "content-type" => "application/json" }, body.new(logger) ]
    end
    boundary = Hive::Remote::RequestBoundary.new(app, logger: logger)
    with_replaced_singleton_method(Hive::Remote::Protocol, :interlock, ->(**) { nil }) do
      result = boundary.call({ "PATH_INFO" => "/api/v1/context", "REQUEST_METHOD" => "GET" })
      assert_equal 200, result.first
    end
    refute_includes output.string, "attacker-request-id"
    assert_includes output.string, '"operation":"api.request"'
  end

  private

  def brainstorm!
    source = stage_dir(@project, "1-inbox").join(@slug)
    destination = stage_dir(@project, "2-brainstorm").join(@slug)
    FileUtils.mv(source, destination)
    Hive::TaskResolver.new(@slug, project_filter: @project).resolve
  end
end
