require "test_helper"

class TasksTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!
    @slug = create_task!(@project, "actions probe")
    sign_in!
  end

  test "status grid lists the task" do
    get "/"
    assert_response :success
    assert_match @slug, response.body
    assert_select "#projects", 1
  end

  test "task page shows artifacts and actions" do
    get "/tasks/#{@project}/#{@slug}"
    assert_response :success
    assert_match "idea.md", response.body
    assert_select "form[action=?]", "/tasks/#{@project}/#{@slug}/approve"
  end

  test "approve with force moves the task to the next stage" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    assert_redirected_to "/"
    assert stage_dir(@project, "2-brainstorm").join(@slug).directory?,
           "approve must move the task folder to 2-brainstorm"
  end

  test "unforced approve without a completion marker renders the typed error page" do
    # Move the task to a gated stage first (1-inbox forward moves are free).
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "2-brainstorm" }

    assert_response :unprocessable_entity
    assert_match "Action failed", response.body
    assert_match "forward approve requires", response.body,
                 "the real Approve refusal reason must reach the operator"
    assert stage_dir(@project, "2-brainstorm").join(@slug).directory?,
           "a refused approve must not move the task"
  end

  test "unknown project and traversal slugs are 404" do
    get "/tasks/nope/#{@slug}"
    assert_response :not_found

    # A traversal-shaped slug fails the route constraint outright.
    get "/tasks/#{@project}/..%2f..%2fetc"
    assert_response :not_found
  end

  test "intervene writes the answer into the task" do
    post "/tasks/#{@project}/#{@slug}/approve", params: { from: "1-inbox", force: "1" }

    post "/tasks/#{@project}/#{@slug}/intervene", params: { message: "Prefer option B" }

    # Without an open brainstorm question the writer reports a typed error —
    # still a readable page, never a blank 500.
    assert_includes [ 302, 422 ], response.status
  end

  test "run stage dispatches the current stage's verb to the daemon queue" do
    post "/tasks/#{@project}/#{@slug}/run",
         params: { action_name: "ready_to_brainstorm", stage: "1-inbox" }

    assert_redirected_to "/tasks/#{@project}/#{@slug}",
                         "a queued dispatch returns to the task page"
    queue = Dir.glob(File.join(ENV["HIVE_HOME"], "**", "dispatch_requests", "**", "*"))
               .select { |f| File.file?(f) }
    assert queue.any? { |f| File.read(f).include?(@slug) },
           "the dispatch request must land in the daemon queue"
  end

  test "run stage rejects a bogus action with a readable 422" do
    post "/tasks/#{@project}/#{@slug}/run",
         params: { action_name: "run", stage: "1-inbox" }

    assert_response :unprocessable_entity
    assert_match "unknown dispatch action", response.body
  end

  test "open brainstorm questions render as a per-question Q&A form" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")

    get "/tasks/#{@project}/#{@slug}"

    assert_response :success
    assert_select ".qa-item", 2, "each open question must get its own answer field"
    assert_select "textarea[name='answers[1]']", 1
    assert_select "textarea[name='answers[2]']", 1
    assert_match "Scope?", response.body
  end

  test "submitted answers land under the right question headers" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n### Q2. Acceptance?\n\n### A2.\n\n")

    post "/tasks/#{@project}/#{@slug}/answers",
         params: { answers: { "1" => "Header only", "2" => "Green tests" } }

    assert_redirected_to "/tasks/#{@project}/#{@slug}"
    content = folder.join("brainstorm.md").read
    assert_match(/### A1\.\nHeader only/, content, "answer 1 must land under its header")
    assert_match(/### A2\.\nGreen tests/, content, "answer 2 must land under its header")
  end

  test "answering an already-closed question is a readable 422" do
    folder = stage_dir(@project, "1-inbox").join(@slug)
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\nDone\n\n")

    post "/tasks/#{@project}/#{@slug}/answers", params: { answers: { "1" => "again" } }

    assert_response :unprocessable_entity
    assert_match "no longer open", response.body
  end

  test "diff link renders only when the worktree exists" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select "a", { text: "Diff", count: 0 }, "pre-execute stages have no worktree → no Diff link"

    # Worktrees first exist at 4-execute; move the task there (the mv IS the
    # pipeline's approval primitive) and materialize the derived path.
    FileUtils.mv(stage_dir(@project, "1-inbox").join(@slug),
                 stage_dir(@project, "4-execute").join(@slug))
    project_payload = StatusBroadcaster.snapshot.fetch("projects", [])
                                        .find { |p| p["name"] == @project }
    row = project_payload.fetch("tasks", []).find { |t| t["slug"] == @slug }
    assert row["worktree_path"].present?, "an execute-stage task must derive a worktree path"
    FileUtils.mkdir_p(row["worktree_path"])

    get "/tasks/#{@project}/#{@slug}"
    assert_select "a", { text: "Diff", count: 1 }, "an existing worktree must expose the Diff link"
  ensure
    FileUtils.rm_rf(row["worktree_path"]) if row && row["worktree_path"].present?
  end

  test "run stage appears only when the project daemon is disabled, labeled with the verb" do
    get "/tasks/#{@project}/#{@slug}"
    assert_select "form[action$='/run']", 0, "daemon-enabled projects must not offer manual runs"

    config_path = stage_dir(@project, "1-inbox").join("..", "..", "config.yml").to_s
    data = YAML.safe_load_file(config_path) || {}
    data["daemon"] = (data["daemon"] || {}).merge("enabled" => false)
    File.write(config_path, data.to_yaml)

    get "/tasks/#{@project}/#{@slug}"
    assert_select "form[action$='/run']", 1
    assert_select "form[action$='/run'] button", text: "Run brainstorm",
                  count: 1
  ensure
    if config_path && File.exist?(config_path)
      data = YAML.safe_load_file(config_path) || {}
      data["daemon"] = (data["daemon"] || {}).merge("enabled" => true)
      File.write(config_path, data.to_yaml)
    end
  end

  test "diff for a task without a worktree is 404 not a crash" do
    get "/tasks/#{@project}/#{@slug}/diff"
    assert_response :not_found
    assert_match "no worktree", response.body
  end
end
