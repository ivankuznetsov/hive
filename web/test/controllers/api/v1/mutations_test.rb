# frozen_string_literal: true

require "test_helper"
require "hive/remote/token_store"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/attempts/api"

class ApiMutationsTest < ActionDispatch::IntegrationTest
  PACKAGE = { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 }.freeze

  setup do
    @loopback = ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback = ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    configure_owner!(owner: "operator")
    @project = create_hive_project!("api-mutations-#{SecureRandom.hex(4)}")
    @private = create_hive_project!("api-private-#{SecureRandom.hex(4)}")
    @project_record = Hive::Config.find_project(@project)
    config_path = File.join(@project_record.fetch("hive_state_path"), "config.yml")
    config = YAML.safe_load_file(config_path)
    config["command_receipts"] = { "keyed_intake_enabled" => true }
    File.write(config_path, config.to_yaml)
    @store = Hive::CommandReceiptStore.new
    Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(database: @store.database, package_coordinates: PACKAGE)
    @issued = issue(%w[read create act answer])
    @headers = headers_for(@issued)
    @base = "/api/v1/projects/#{@project}"
  end

  teardown do
    @loopback ? ENV["HIVE_WEB_LOCAL_LOOPBACK"] = @loopback : ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback ? ENV["HIVEBOX_LOCAL_LOOPBACK"] = @legacy_loopback : ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
  end

  test "create persists one principal-bound receipt and replays after advancement" do
    payload = { text: "A remote idea", slug: "remote-idea-260923-abcd", idempotency_key: "capture" }
    post "#{@base}/tasks", params: payload, headers: @headers, as: :json
    assert_response :created
    first = response.parsed_body.fetch("data")
    assert_equal first.dig("command_receipt", "id"), first.fetch("operation_id")
    refute_includes response.body, @project_record.fetch("path")
    task = Hive::TaskResolver.new(first.fetch("slug"), project_filter: @project).resolve
    FileUtils.mv(task.folder, task.folder.sub("/1-inbox/", "/2-brainstorm/"))
    post "#{@base}/tasks", params: payload, headers: @headers, as: :json
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("data")
    post "#{@base}/tasks", params: payload, headers: headers_for(issue([ "create" ])), as: :json
    assert_response :conflict
    refute_includes response.body, first.fetch("operation_id")
  end

  test "act-only tokens cannot admit a terminal inbox approval through actions" do
    slug = create_task!(@project, "Needs approval")
    task = Hive::TaskResolver.new(slug, project_filter: @project).resolve
    Hive::TaskMeta.write(task.folder, id: task.id, slug: task.slug, display_name: "Approval", workflow: "content")
    task = Hive::Task.new(task.folder)
    File.write(task.state_file, "# Idea\n<!-- COMPLETE -->\n")
    descriptor = Hive::OperationalAction.descriptor_for_task(task, project: @project)
    headers = headers_for(issue([ "act" ]))
    post "#{@base}/tasks/#{slug}/actions", params: { action_id: descriptor.fetch("action_id"),
      observation: descriptor.fetch("observation_token"), idempotency_key: "act-denial" }, headers: headers, as: :json
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
    assert_empty Hive::RuntimeControlPlane::DispatchRepository.open_default.pending.select { |request| request.project == @project }
    assert_includes File.read(task.state_file), "COMPLETE"
  end

  test "workflow traversal is rejected before lookup" do
    [ "../config", "/tmp/config", "coding/../../config" ].each do |workflow|
      post "#{@base}/tasks", params: { text: "Unsafe", workflow: workflow,
        idempotency_key: "workflow-path" }, headers: @headers, as: :json
      assert_response :bad_request
    end
  end

  test "scope and project are checked before target lookup and receipt access" do
    writer = headers_for(issue([ "create" ]))
    post "#{@base}/tasks/not-present/answers", params: { handle: "0" * 64, answer: "Yes", idempotency_key: "forbidden" }, headers: writer, as: :json
    assert_response :forbidden
    post "/api/v1/projects/#{@private}/tasks", params: { text: "Hidden", idempotency_key: "private" }, headers: writer, as: :json
    assert_response :not_found
    assert_empty Dir.children(stage_dir(@private, "1-inbox")).reject { |name| name.start_with?(".") }
    get "/api/v1/projects/#{@private}/operations/unknown", headers: writer
    assert_response :not_found
    no_scopes = headers_for(issue([]))
    %w[/tasks /tasks/missing/actions /tasks/missing/answers /tasks/missing/approvals].each do |suffix|
      post "#{@base}#{suffix}", params: { idempotency_key: "denied" }, headers: no_scopes, as: :json
      assert_response :forbidden
      post "/api/v1/projects/#{@private}#{suffix}", params: { idempotency_key: "denied" }, headers: @headers, as: :json
      assert_response :not_found
    end
  end

  test "typed mutation inputs require matching keys and reject arbitrary execution fields" do
    post "#{@base}/tasks", params: { text: "Missing key" }, headers: @headers, as: :json
    assert_response :bad_request
    post "#{@base}/tasks", params: { text: "Conflict key", idempotency_key: "body" }, headers: @headers.merge("Idempotency-Key" => "header"), as: :json
    assert_response :bad_request
    %w[argv class path env force bypass attachments].each do |field|
      post "#{@base}/tasks", params: { text: "Forbidden", idempotency_key: field, field => "anything" }, headers: @headers, as: :json
      assert_response :bad_request
    end
    post "#{@base}/tasks", params: { text: [ "wrong type" ], idempotency_key: "type" }, headers: @headers, as: :json
    assert_response :bad_request
    assert_empty Dir.children(stage_dir(@project, "1-inbox")).reject { |name| name.start_with?(".") }
    # Rack transports header bytes as ASCII-8BIT, even for ordinary ASCII keys.
    post "#{@base}/tasks", params: { text: "Header key" }, headers: @headers.merge("Idempotency-Key" => "header-only".b), as: :json
    assert_response :created
    post "#{@base}/tasks", params: { text: "Invalid header encoding" }, headers: @headers.merge("Idempotency-Key" => "bad\xff".b), as: :json
    assert_response :bad_request
  end

  test "answer receipts replay after handle eviction and advance with oversized new state" do
    task, handle = question_task!
    payload = { handle: handle, answer: "Use blue", idempotency_key: "answer" }
    answer_headers = headers_for(issue([ "answer" ]))
    post "#{@base}/tasks/#{task.slug}/answers", params: payload, headers: answer_headers, as: :json
    assert_response :ok
    first = response.parsed_body.fetch("data")
    assert_equal "written", first.fetch("outcome")
    refute_includes response.body, "binding"
    refute_includes response.body, "Which color"
    handles = Hive::Remote::QuestionHandles.new(max_handles: 1)
    handles.cursor(projects: [ @project ], snapshot: "unrelated-read", offset: 1)
    refute JSON.parse(File.read(handles.path)).fetch("handles").key?(handle)
    post "#{@base}/tasks/#{task.slug}/answers", params: payload, headers: answer_headers, as: :json
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("data")
    assert_equal 1, File.read(task.state_file).scan("Use blue").length
    post "#{@base}/tasks/#{task.slug}/answers", params: payload.merge(idempotency_key: "fresh-answer"), headers: answer_headers, as: :json
    assert_response :conflict
    folder = task.folder.sub("/2-brainstorm/", "/3-plan/")
    FileUtils.mv(task.folder, folder)
    File.write(File.join(folder, "plan.md"), "x" * (512 * 1024 + 1))
    post "#{@base}/tasks/#{task.slug}/answers", params: payload, headers: answer_headers, as: :json
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("data")
    get "#{@base}/operations/#{first.fetch('operation_id')}", headers: answer_headers
    assert_response :ok
    assert_equal "succeeded", response.parsed_body.dig("data", "state")
    assert_equal first, response.parsed_body.dig("data", "acknowledgement")

    [ payload.merge(answer: "Use red"), payload.merge(handle: "0" * 64) ].each do |changed|
      post "#{@base}/tasks/#{task.slug}/answers", params: changed, headers: answer_headers, as: :json
      assert_response :conflict
      refute_includes response.body, first.fetch("operation_id")
    end
    other = create_task!(@project, "Different answer target")
    post "#{@base}/tasks/#{other}/answers", params: payload, headers: answer_headers, as: :json
    assert_response :conflict
    post "#{@base}/tasks/#{task.slug}/answers", params: payload, headers: headers_for(issue([ "answer" ])), as: :json
    assert_response :conflict
    refute_includes response.body, first.fetch("operation_id")
  end

  test "answer receipts from before remote binding retention still replay with a retained handle" do
    task, handle = question_task!
    record = Hive::Remote::QuestionHandles.new.resolve(handle: handle, project: @project_record, task: task)
    result = Hive::Remote::CommandService.new.answer(project: @project_record, task: task,
      binding: record.fetch("binding"), answer: "Use blue", idempotency_key: "legacy-answer",
      principal: "installation:#{@store.database.installation_identity.fetch(:installation_id)}:token:#{@issued.fetch('id')}", scopes: [ "answer" ])
    post "#{@base}/tasks/#{task.slug}/answers", params: {
      handle: handle, answer: "Use blue", idempotency_key: "legacy-answer"
    }, headers: @headers, as: :json
    assert_response :ok
    assert_equal Hive::Remote::Serializers.acknowledgement(result), response.parsed_body.fetch("data")
  end

  test "unknown stale and cross-task question handles fail without writing" do
    task, handle = question_task!
    original = File.read(task.state_file)
    payload = { handle: "0" * 64, answer: "Wrong", idempotency_key: "unknown" }
    post "#{@base}/tasks/#{task.slug}/answers", params: payload, headers: @headers, as: :json
    assert_response :not_found
    other = create_task!(@project, "Another task")
    post "#{@base}/tasks/#{other}/answers", params: payload.merge(handle: handle, idempotency_key: "cross-task"), headers: @headers, as: :json
    assert_response :not_found
    File.write(task.state_file, original.sub("Which color?", "Which shape?"))
    post "#{@base}/tasks/#{task.slug}/answers", params: payload.merge(handle: handle, idempotency_key: "stale"), headers: @headers, as: :json
    assert_response :conflict
    refute_includes File.read(task.state_file), "Wrong"
    post "#{@base}/tasks/#{task.slug}/answers", params: payload.merge(handle: handle, answer: "x" * (64 * 1024 + 1)), headers: @headers, as: :json
    assert_response :content_too_large
  end

  test "queued approval exposes admission separately from durable attempt progress" do
    task, = question_task!
    File.write(task.state_file, "# Brainstorm\n<!-- COMPLETE -->\n")
    generation = Hive::WorkflowAdmission.generation_for(task, project: @project)
    payload = { stage: "2-brainstorm", generation: generation, idempotency_key: "approve" }
    writer = headers_for(issue([ "answer" ]))
    post "#{@base}/tasks/#{task.slug}/approvals", params: payload, headers: writer, as: :json
    assert_response :accepted
    acknowledgement = response.parsed_body.fetch("data")
    assert_equal true, acknowledgement.fetch("queued")
    operation_id = acknowledgement.fetch("operation_id")
    get "#{@base}/operations/#{operation_id}", headers: writer
    assert_response :ok
    assert_equal "queued", response.parsed_body.dig("data", "state")
    assert_equal "succeeded", response.parsed_body.dig("data", "command_outcome")
    repository = runtime_dispatch_repository
    request = repository.fetch(acknowledgement.fetch("request_id"))
    admitted = Hive::Attempts::API.new.dispatch_request(request)
    assert_equal :accepted, admitted.status
    attempts = Hive::Attempts::Repository.open_default
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      break if attempts.fetch(admitted.attempt.attempt_id).final?
      flunk "detached worker did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    @store.database.transaction { |db| db[:dispatch_requests].where(request_id: request.request_id).delete }
    get "#{@base}/operations/#{operation_id}", headers: writer
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "succeeded", data.fetch("state")
    assert_equal admitted.attempt.attempt_id, data.dig("progress", "attempt_id")
    assert_equal acknowledgement, data.fetch("acknowledgement")
    post "#{@base}/tasks/#{task.slug}/approvals", params: payload, headers: writer, as: :json
    assert_response :accepted
    assert_equal acknowledgement, response.parsed_body.fetch("data")
  end

  test "only the submitting principal or a reader can look up an operation and revoked tokens lose access" do
    writer_token = issue([ "create" ])
    writer = headers_for(writer_token)
    post "#{@base}/tasks", params: { text: "A private acknowledgement", idempotency_key: "own" }, headers: writer, as: :json
    assert_response :created
    id = response.parsed_body.dig("data", "operation_id")
    get "#{@base}/operations/#{id}", headers: writer
    assert_response :ok
    get "#{@base}/operations/#{id}", headers: headers_for(issue([ "create" ]))
    assert_response :not_found
    get "#{@base}/operations/#{id}", headers: @headers
    assert_response :ok
    all_projects = Hive::Remote::TokenStore.new.create(name: "all-project-reader", scopes: [ "read" ], all_projects: true)
    get "/api/v1/projects/#{@private}/operations/#{id}", headers: headers_for(all_projects)
    assert_response :not_found
    Hive::Remote::TokenStore.new.revoke(writer_token.fetch("id"))
    get "#{@base}/operations/#{id}", headers: writer
    assert_response :unauthorized
  end

  test "expiring tokens lose their own operation access before receipt lookup" do
    token = Hive::Remote::TokenStore.new.create(name: "short-lived", scopes: [ "create" ], projects: [ @project ],
      expires_at: (Time.now.utc + 60).iso8601)
    headers = headers_for(token)
    post "#{@base}/tasks", params: { text: "Expiring owner", idempotency_key: "expiry" }, headers: headers, as: :json
    assert_response :created
    id = response.parsed_body.dig("data", "operation_id")
    travel_to(Time.now.utc + 120) do
      get "#{@base}/operations/#{id}", headers: headers
      assert_response :unauthorized
    end
  end

  test "project qualified creation dependencies require the dependency project grant" do
    post "#{@base}/tasks", params: { text: "Unauthorized dependency", depends_on: "#{@private}:missing-task", idempotency_key: "dependency" }, headers: @headers, as: :json
    assert_response :not_found
    assert_empty Dir.children(stage_dir(@project, "1-inbox")).reject { |name| name.start_with?(".") }
    post "#{@base}/tasks", params: { text: "Unauthorized dependency list", depends_on: [ "#{@private}:missing-task" ], idempotency_key: "dependency-list" }, headers: @headers, as: :json
    assert_response :not_found
    first = create_task!(@project, "First prerequisite")
    second = create_task!(@project, "Second prerequisite")
    post "#{@base}/tasks", params: { text: "Scheduling dependencies", depends_on: [ first, second ], idempotency_key: "scheduling-list" }, headers: @headers, as: :json
    assert_response :created
    post "#{@base}/tasks", params: { text: "Too many dependencies", depends_on: [ first ] * 65, idempotency_key: "oversized-list" }, headers: @headers, as: :json
    assert_response :content_too_large
  end

  test "actions accept canonical observations and reject stale or administrative effects" do
    task, = question_task!
    File.write(task.state_file, "# Brainstorm\n<!-- COMPLETE -->\n")
    descriptor = Hive::OperationalAction.descriptor_for_task(task, project: @project)
    writer = headers_for(issue([ "act" ]))
    payload = { action_id: descriptor.fetch("action_id"), observation: descriptor.fetch("observation_token"), idempotency_key: "action" }
    post "#{@base}/tasks/#{task.slug}/actions", params: payload.merge(observation: "0" * 64, idempotency_key: "stale-action"), headers: writer, as: :json
    assert_response :conflict
    post "#{@base}/tasks/#{task.slug}/actions", params: payload, headers: writer, as: :json
    assert_response :accepted
    acknowledgement = response.parsed_body.fetch("data")
    assert_equal task.id, acknowledgement.fetch("task_id")
    assert_equal 1, runtime_dispatch_requests.count { |entry| entry.slug == task.slug }
    File.write(task.state_file, "x" * (512 * 1024 + 1))
    post "#{@base}/tasks/#{task.slug}/actions", params: payload, headers: writer, as: :json
    assert_response :accepted
    assert_equal acknowledgement, response.parsed_body.fetch("data")
    File.write(task.state_file, "# Brainstorm\n<!-- COMPLETE -->\n")
    %w[setup configure module delete release workflow.close_with_evidence].each do |action|
      post "#{@base}/tasks/#{task.slug}/actions", params: payload.merge(action_id: action, idempotency_key: "denied-#{action}"), headers: writer, as: :json
      assert_response :unprocessable_entity
    end
    post "#{@base}/tasks/#{task.slug}/actions", params: payload.merge(force: true), headers: @headers, as: :json
    assert_response :bad_request
  end

  test "force derived transition guidance is fixed and cannot expose server details" do
    slug = create_task!(@project, "Force advance")
    task = Hive::TaskResolver.new(slug, project_filter: @project).resolve
    # Inbox advance requires native force and remains local even for all scopes.
    descriptor = Hive::OperationalAction.descriptor_for_task(task, project: @project)
    post "#{@base}/tasks/#{slug}/actions", params: { action_id: descriptor.fetch("action_id"), observation: descriptor.fetch("observation_token"), idempotency_key: "force-derived" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "advance this task locally", response.parsed_body.dig("error", "message")
    assert_empty runtime_dispatch_requests.select { |entry| entry.project == @project }
  end

  private

  def issue(scopes)
    Hive::Remote::TokenStore.new.create(name: "mutation-token", scopes: scopes, projects: [ @project ])
  end

  def headers_for(issued)
    { "Authorization" => "Bearer #{issued.fetch('token')}" }
  end

  def question_task!
    slug = create_task!(@project, "Question fixture")
    folder = stage_dir(@project, "2-brainstorm").join(slug)
    FileUtils.mv(stage_dir(@project, "1-inbox").join(slug), folder)
    task = Hive::Task.new(folder.to_s)
    File.write(task.state_file, "# Brainstorm\n### Q1. Which color?\n### A1.\n<!-- WAITING -->\n")
    get "#{@base}/tasks/#{slug}/questions", headers: @headers
    assert_response :ok
    [ task, response.parsed_body.dig("data", "slots", 0, "handle") ]
  end
end
