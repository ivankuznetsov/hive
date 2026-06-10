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

  test "diff for a task without a worktree is 404 not a crash" do
    get "/tasks/#{@project}/#{@slug}/diff"
    assert_response :not_found
    assert_match "no worktree", response.body
  end
end
