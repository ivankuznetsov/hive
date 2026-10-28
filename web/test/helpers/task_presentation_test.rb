require "test_helper"

class TaskPresentationTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @task_source = "active"
    @task = Task.new(project: Project.new("name" => "demo"), attributes: {
      "slug" => "article", "workflow" => "content", "stage" => "6-done", "action" => "ready_to_run"
    })
  end

  test "final agent stage retains manual run" do
    render partial: "tasks/primary_actions", locals: { task: @task, daemon_enabled: false }
    assert_select "form[action^='/tasks/demo/article/run'] button", text: "Run stage"
  end

  test "unavailable artifact evidence does not imply work never started" do
    render partial: "tasks/primary_result", locals: { result: { "primary" => nil, "warning" => "Artifact unavailable" } }
    assert_select "h2", text: /not started/, count: 0
    assert_select ".workspace-empty", text: /No document is available/
  end

  test "unavailable PR identity does not imply no PR exists" do
    render partial: "tasks/publication", locals: {
      publication: { "state" => "unavailable", "publication_state" => "worktree_unavailable", "diagnostics" => [] },
      refresh_available: false, refresh_notice: nil
    }
    assert_select ".empty-state", text: /No pull request yet/, count: 0
    assert_select ".workspace-state-label", text: "Worktree unavailable"
    assert_select "details", text: /Git details/, count: 0
  end

  test "git details link native repository references and omit unknown facts" do
    @task.define_singleton_method(:worktree?) { false }
    render partial: "tasks/publication", locals: {
      publication: {
        "state" => "partial", "publication_state" => "not_configured", "diagnostics" => [],
        "local" => {
          "repository" => "github.com/acme/demo", "branch" => "feat/web-ui", "base_branch" => "main",
          "head_oid" => "b" * 40, "push" => { "state" => "unavailable" }, "dirty" => nil
        }
      },
      refresh_available: false, refresh_notice: nil
    }
    assert_select "a[href=?]", "https://github.com/acme/demo", text: "github.com/acme/demo"
    assert_select "a[href=?]", "https://github.com/acme/demo/tree/feat/web-ui", text: "feat/web-ui"
    assert_select "a[href=?]", "https://github.com/acme/demo/commit/#{'b' * 40}", text: "b" * 12
    assert_select "dt", text: "Push", count: 0
    assert_select "dt", text: "Working tree", count: 0
    assert_select "*", text: "Unavailable", count: 0
    assert_select "*", text: /has not been checked/, count: 0
  end

  test "absent local tracking ref with a known PR is not reported as unpushed" do
    @task.define_singleton_method(:worktree?) { false }
    render partial: "tasks/publication", locals: {
      publication: {
        "state" => "partial", "publication_state" => "not_observed", "diagnostics" => [],
        "pull_request" => { "url" => "https://github.com/acme/demo/pull/7", "number" => 7 },
        "local" => { "repository" => "github.com/acme/demo", "branch" => "feat", "push" => { "state" => "not_observed" } }
      },
      refresh_available: false, refresh_notice: nil
    }
    assert_select "dt", text: "Push", count: 0
    assert_no_match(/not pushed/i, rendered)
    assert_select "a[href=?]", "https://github.com/acme/demo/pull/7", text: "PR #7"
    assert_select "a[href=?]", "https://github.com/acme/demo/pull/7/files", text: "View diff on GitHub"
    assert_select "a", text: "View diff", count: 0
  end

  test "compact publication groups state with title, actions together and names GitHub state once" do
    @task.define_singleton_method(:worktree?) { false }
    render partial: "tasks/publication", locals: {
      publication: {
        "state" => "current", "publication_state" => "merged", "diagnostics" => [],
        "pull_request" => { "url" => "https://github.com/acme/demo/pull/7", "number" => 7 },
        "remote" => { "observed_at" => "2026-07-09T16:56:33Z", "observation" => { "state" => "MERGED" } }
      },
      refresh_available: false, refresh_notice: nil
    }
    assert_select ".publication-title h2", text: "Code changes"
    assert_select ".publication-title .workspace-state-label", text: "Merged"
    assert_select ".publication-actions a[href=?]", "https://github.com/acme/demo/pull/7", text: "PR #7"
    assert_select ".publication-actions a[href=?]", "https://github.com/acme/demo/pull/7/files", text: "View diff on GitHub"
    assert_select "h3", count: 0
    assert_select ".publication-observed", text: /Checked on GitHub · 9 Jul 2026, 16:56 UTC/
    assert_select ".publication-observed time[datetime=?]", "2026-07-09T16:56:33Z"
    assert_equal 1, rendered.scan("Merged").size
  end

  test "publication names the GitHub state when it differs from the panel state" do
    @task.define_singleton_method(:worktree?) { false }
    render partial: "tasks/publication", locals: {
      publication: {
        "state" => "current", "publication_state" => "checks_failing", "diagnostics" => [],
        "pull_request" => { "url" => "https://github.com/acme/demo/pull/7", "number" => 7 },
        "remote" => { "observed_at" => "not-a-time", "observation" => { "state" => "OPEN", "checks" => [ { "name" => "ci", "status" => "COMPLETED", "conclusion" => "FAILURE" } ] } }
      },
      refresh_available: false, refresh_notice: nil
    }
    assert_select ".publication-title .workspace-state-label", text: "Checks failing"
    assert_select ".publication-observed", text: /Open on GitHub · checked not-a-time/
    assert_select "table caption", text: "Checks"
  end

  test "primary document section label is styled apart from the document title" do
    render partial: "tasks/primary_result", locals: { result: { "primary" => { "name" => "task.md", "reference" => "task.md", "content" => "# Go CLI\n\nBody" } } }
    assert_select "h2#workspace-primary-result-heading.document-section-label", text: "Implementation"
    assert_select ".primary-markdown h1", text: "Go CLI"
    assert_select ".primary-markdown h1.document-section-label", count: 0
  end

  test "repository web url normalizes native and common repository spellings" do
    assert_equal "https://github.com/acme/demo", repository_web_url("github.com/acme/demo")
    assert_equal "https://github.com/acme/demo", repository_web_url("https://github.com/acme/demo.git")
    assert_equal "https://github.com/acme/demo", repository_web_url("git@github.com:acme/demo.git")
    assert_equal "https://ghe.example.com/acme/demo", repository_web_url("ghe.example.com/acme/demo")
    assert_nil repository_web_url("github.com/acme/demo/extra")
    assert_nil repository_web_url("github.com/../demo")
    assert_nil repository_web_url("javascript:alert(1)")
    assert_nil repository_web_url("")
  end

  test "documents use meaningful labels with the file name as secondary text" do
    render partial: "tasks/supporting_artifacts", locals: { result: { "supporting" => [
      { "name" => "plan.md", "reference" => "plan.md", "content" => "# Plan" },
      { "name" => "notes.txt", "reference" => "notes.txt", "content" => "hello" }
    ] } }
    assert_select "#workspace-supporting-artifacts-heading", text: "Documents"
    assert_select "summary", text: /\APlan\s+plan\.md\z/
    assert_select "summary", text: "notes.txt"
    assert_select "summary > .document-section-label", text: "Plan"
    assert_select ".artifact-body .document-section-label", count: 0
  end

  test "stale running status renders an idle dot" do
    task = Task.new(project: @task.project, attributes: { "stage" => "4-execute", "action" => "agent_running" })
    html = status_dot(task, fresh: false)
    assert_includes html, "status-dot-idle"
    refute_includes html, "status-dot-running"
    assert_includes html, "Status unavailable"
  end
end
