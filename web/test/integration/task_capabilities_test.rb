require "test_helper"
require "hive/task_capabilities/projection"
require "hive/commands/task"
require "hive/attempts/dispatcher"

class TaskCapabilitiesTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!("capabilities-#{SecureRandom.hex(4)}")
    sign_in!
    config = stage_dir(@project, "1-inbox").parent.parent.join("config.yml")
    values = YAML.safe_load(config.read, permitted_classes: [ Symbol ], aliases: true) || {}
    values["task_capabilities"] = { "enabled" => true }
    config.write(values.to_yaml)
  end

  test "preview has native labelled choices and live blockers below the toolbar" do
    get "/capabilities", params: { project: @project, text: "Add a form" }
    assert_response :success
    assert_select "#composer-capabilities fieldset", count: 3
    %w[ui qa security].each do |id|
      assert_select "fieldset legend", text: id.upcase
      assert_select "input[type=radio][name='capabilities[#{id}]']", count: 3
    end
    assert_select "[role=status][aria-live=polite][data-blocked=true]"
    assert_select "input[name=qa_waiver_reason]", count: 0
    assert_select "select[name='capability_approvals[security]']", count: 0
    assert_select "input[type=radio][aria-describedby]", minimum: 3
  end

  test "QA off places audited fields after its radios and security on asks approval" do
    get "/capabilities", params: { project: @project, capabilities: { qa: "off", security: "on" } }
    assert_response :success
    qa = css_select("fieldset").find { |node| node.at_css("legend").text == "QA" }
    assert qa.at_css("input[name=qa_waiver_reason]")
    assert_operator qa.to_html.index("qa_waiver_reason"), :>, qa.to_html.index("value=\"off\"")
    assert_select "input[name='qa_waiver_checks[]'][value=all]"
    assert_select "select[name='capability_approvals[security]']"
  end

  test "CLI and web previews share reasons blockers and exact shell corrections" do
    project = Project.find!(@project)
    web = project.capability_preview("Add a form")
    command = Hive::Commands::New.new(@project, "Add a form", preview: true, json: true)
    output, = capture_io { command.call! }
    assert_equal JSON.parse(output), web
    get "/capabilities", params: { project: @project, text: "Add a form" }
    web.fetch("capability_recovery").each { |item| assert_includes response.body, CGI.escapeHTML(item.fetch("message")) }
    assert_includes web.fetch("capability_recovery").first.fetch("command"), "--verification-plan"
    assert_includes web.fetch("capability_recovery").first.fetch("alternative_command"), "--checks all"
  end

  test "stale preview rejection stays in its region and leaves capture unwritten" do
    preview = Project.find!(@project).capability_preview("Draft with [image1]")
    change_config { |cfg| cfg["review"] = { "ci" => { "command" => "ruby -e 'puts 42'" } } }
    before = stage_dir(@project, "1-inbox").children
    post "/ideas", params: { project: @project, text: "Draft with [image1]", capability_preview: preview.dig("capabilities", "preview_digest") },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=replace][target=composer-capabilities]"
    assert_includes response.body, "Selections changed"
    assert_equal before, stage_dir(@project, "1-inbox").children
    refute File.exist?(File.join(Project.find!(@project).hive_state_path, "task-capabilities-adoption.json"))
  end

  test "bad named choice is rejected inline and never becomes an inferred default" do
    post "/ideas", params: { project: @project, text: "Invalid choice", capabilities: { unknown: "on" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "unknown"
    refute_includes response.body, "Selections ready"
  end

  test "real Rails capture and durable execution enforce the same final identity across caller environments" do
    command = %q(ruby -rjson -e 'abort "framework environment leaked" if %w[RAILS_ENV BUNDLE_GEMFILE BUNDLE_PATH NODE_ENV].any? { |k| ENV.key?(k) }; abort "locale mismatch" unless ENV["TZ"] == "UTC"; puts JSON.generate(ENV.to_h)')
    change_config { |cfg| cfg["review"] = { "ci" => { "command" => command } } }
    project = Project.find!(@project)
    created = nil
    with_environment("RAILS_ENV" => "creator", "BUNDLE_GEMFILE" => "/creator/Gemfile", "BUNDLE_PATH" => "/creator/bundle", "NODE_ENV" => "creator", "PATH" => "/creator/bin:/usr/bin:/bin") do
      capture_io { created = project.add_idea!("Verify the real Rails capture") }
    end
    task = review_task(created)
    plan = Hive::TaskCapabilities::Store.new(task.folder).current
    before = Hive::TaskCapabilities::Projection.new(task: task, cfg: project.config, project: @project).call
    with_environment("RAILS_ENV" => "daemon", "BUNDLE_GEMFILE" => "/daemon/Gemfile", "BUNDLE_PATH" => "/daemon/bundle", "NODE_ENV" => "daemon", "PATH" => "/daemon/bin:/usr/bin:/bin") do
      with_durable_parent(task) do |context|
        aggregate = Hive::TaskCapabilities::Verification.new(task: task, cfg: project.config, worktree_path: task.worktree_path, context: context).run!
        assert_equal "passed", aggregate.fetch("state"), aggregate.inspect
        assert_equal context.attempt_id, aggregate.fetch("checks").first.fetch("result").fetch("parent_attempt_id")
      end
    end
    with_environment("RAILS_ENV" => "viewer", "BUNDLE_GEMFILE" => "/viewer/Gemfile", "BUNDLE_PATH" => "/viewer/bundle", "NODE_ENV" => "viewer", "PATH" => "/viewer/bin:/usr/bin:/bin") do
      assert Hive::TaskCapabilities::Gate.new(task: task, cfg: project.config).enforce!.fetch("allowed")
      output, = capture_io { Hive::Commands::Task.new(task.slug, project: @project, json: true).call }
      cli = JSON.parse(output).fetch("capabilities")
      get "/tasks/#{@project}/#{task.slug}.json"
      assert_response :success
      assert_equal cli, response.parsed_body.fetch("capabilities")
      assert_equal "Passed", cli.dig("gate", "label")
      refute_equal before.fetch("refresh_digest"), cli.fetch("refresh_digest")
      assert_equal plan.digest, cli.fetch("execution_plan_digest")
      post "/tasks/#{@project}/#{task.slug}/approve", params: { from: "6-review" }
      assert_response :redirect
      assert stage_dir(@project, "7-artifacts").join(task.slug).directory?
    end
  end

  test "task corrections use version fencing and show stale errors inline" do
    task = captured_review_task
    expected = Hive::TaskCapabilities::Revision.new(task: task).show.fetch("expected")
    fields = correction_fields(expected)
    post "/tasks/#{@project}/#{task.slug}/capabilities/propose", params: fields.merge(capabilities: { ui: "off" }, reason: "Backend task")
    assert_response :redirect
    get "/tasks/#{@project}/#{task.slug}"
    assert_select "section[aria-label='Pending capability changes']", count: 1
    assert_select "input[type=submit][value='Accept capability changes']"
    assert_select "input[type=submit][value='Reject capability changes']"
    proposal = Hive::TaskCapabilities::Revision.new(task: task).show.fetch("proposals").first.fetch("proposal_digest")
    post "/tasks/#{@project}/#{task.slug}/capabilities/accept", params: fields.merge(proposal: proposal)
    assert_response :redirect
    assert_equal 2, Hive::TaskCapabilities::Store.new(task.folder).current.version
    post "/tasks/#{@project}/#{task.slug}/capabilities/waive", params: fields.merge(reason: "Operator checks behavior", checks: [ "all" ]),
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :unprocessable_entity
    assert_select "turbo-stream[target=task-capabilities]"
    assert_select "#capability-correction-error[role=alert]", text: /changed/
    assert_equal 2, Hive::TaskCapabilities::Store.new(task.folder).current.version
  end

  test "all authorization operations and capture waivers reject an owning attempt without writes" do
    task = captured_review_task
    expected = Hive::TaskCapabilities::Revision.new(task: task).show.fetch("expected")
    fields = correction_fields(expected).merge(proposal: "a" * 64, result: "a" * 64, findings: [ "finding" ], reason: "Operator reason", checks: [ "all" ])
    with_durable_parent(task) do |context|
      before = task_files(task)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        %w[accept reject waive risk-accept].each do |operation|
          post "/tasks/#{@project}/#{task.slug}/capabilities/#{operation}", params: fields
          assert_response :unprocessable_entity
          assert_includes response.body, "active Hive attempt cannot authorize"
          assert_equal before, task_files(task)
        end
        post "/ideas", params: { project: @project, text: "Agent cannot waive", capabilities: { qa: "off" }, qa_waiver_reason: "Agent reason", qa_waiver_checks: [ "all" ] }
        assert_response :unprocessable_entity
        assert_includes response.body, "active Hive attempt cannot authorize"
      end
      get "/tasks/#{@project}/#{task.slug}"
      assert_select "input[aria-disabled=true]", minimum: 1
      assert_includes response.body, "owning attempt"
    end
  end

  test "task presentation labels all eight states and preserves terminal closure annotation" do
    task = captured_review_task
    projection = Hive::TaskCapabilities::Projection.new(task: task, cfg: Project.find!(@project).config).call
    projection["gate"]["checks"] = Hive::TaskCapabilities::Projection::LABELS.map do |state, label|
      { "capability_id" => "qa", "check_id" => state, "state" => state, "label" => label,
        "result_digest" => "b" * 64, "evidence" => [], "applicability" => {}, "findings" => [] }
    end
    projection["gate"]["terminal_dispositions"] = [ { "label" => "Closed out-of-band — gate not evaluated", "reference" => "closure-receipt" } ]
    markup = TasksController.render(partial: "tasks/capabilities", locals: { capabilities: projection },
      assigns: { project: Project.find!(@project), task: Task.new(project: Project.find!(@project), attributes: { "slug" => task.slug }) })
    Hive::TaskCapabilities::Projection::LABELS.each_value { |label| assert_includes markup, label }
    assert_includes markup, "Closed out-of-band — gate not evaluated"
    assert_includes markup, 'href="#capability-closure-receipt"'
  end

  test "retained task without a worktree exposes unavailable mutation rather than inferring a plan" do
    project = Project.find!(@project)
    created = nil
    capture_io { created = project.add_idea!("Needs real checks") }
    get "/tasks/#{@project}/#{created.fetch('slug')}"
    assert_response :success
    assert_includes response.body, "declare a usable check"
    assert_includes response.body, "Execution plan v1"
    assert_includes response.body, "--verification-plan"
  end

  private

  def captured_review_task
    change_config { |cfg| cfg["review"] = { "ci" => { "command" => "ruby -e 'puts 42'" } } }
    created = nil
    capture_io { created = Project.find!(@project).add_idea!("Capability correction") }
    review_task(created)
  end

  def correction_fields(expected)
    { identity: JSON.generate(expected.fetch("expected_identity")), plan_version: expected.fetch("expected_version"), sha: expected.fetch("expected_sha") }
  end

  def task_files(task)
    Dir.glob(File.join(task.folder, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) && File.basename(path) != ".lock" }.to_h { |path| [ path, File.binread(path) ] }
  end

  def change_config
    path = Pathname(Project.find!(@project).hive_state_path).join("config.yml")
    cfg = YAML.safe_load_file(path)
    yield cfg
    path.write(cfg.to_yaml)
  end

  def with_environment(values)
    previous = values.to_h { |key, _| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def review_task(created)
    folder = stage_dir(@project, "6-review").join(created.fetch("slug"))
    FileUtils.mv(created.fetch("task_folder"), folder)
    folder.join("task.md").write("# Review\n<!-- REVIEW_COMPLETE -->\n")
    project = Project.find!(@project)
    branch = Hive::GitOps.new(project.path).current_branch
    owned = Hive::Worktree.new(project.path, created.fetch("slug"), worktree_root: File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "capability-worktrees"))
    owned.create!(created.fetch("slug"), default_branch: branch)
    owned.write_pointer!(folder.to_s, created.fetch("slug"))
    Hive::Task.new(folder.to_s)
  end

  def with_durable_parent(task)
    attempts = Hive::Attempts::Repository.open_default
    launcher = Object.new
    launcher.define_singleton_method(:preflight!) { true }
    launcher.define_singleton_method(:launch) { |*, **| { "claimed" => true } }
    dispatcher = Hive::Attempts::Dispatcher.new(store: attempts, launcher: launcher, capability_generator: -> { "c" * 64 })
    parent = dispatcher.dispatch(task: task, project: @project, intended_stage: "6-review", argv: [ "hive", "run", task.slug ], request_id: "surfaces-#{task.id}", provider: "claude").attempt
    owner = { "pid" => Process.pid, "start_fingerprint" => Hive::Lock.process_start_time(Process.pid), "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
    parent = attempts.claim(parent, owner: owner, claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
    parent = attempts.first_heartbeat(parent, stale_sec: 30, now: Time.now.utc)
    context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: parent.task_input_epoch,
      ownership_generation: parent.ownership_generation, intended_stage: "6-review")
    yield context
  ensure
    context&.close
    if attempts && parent
      attempts.terminalize(attempts.fetch(parent.attempt_id), outcome: "succeeded", exit_status: 0,
        final_checkpoint: { "marker" => "review_complete" }, output_references: [],
        log_reference: { "path" => "open/fixture.frames", "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
    end
  end
end
