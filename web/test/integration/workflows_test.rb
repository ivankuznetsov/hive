require "test_helper"

class WorkflowsTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  class FakeLifecycle
    attr_reader :calls

    def initialize
      @calls = []
      @rows = [
        workflow_row("coding", "built_in"),
        workflow_row("release-notes", "authored"),
        workflow_row(
          "demo", "managed", selection: "selected", integrity: "verified",
          version: "1.0.0", source_commit: "a" * 40
        )
      ]
    end

    def templates = %w[blank writing]
    def list(_project) = @rows

    def scaffold(project, id:, template:)
      @calls << [ :scaffold, project.fetch("name"), id, template ]
      { "id" => id }
    end

    def preview_install(project, source:)
      @calls << [ :preview_install, project.fetch("name"), source ]
      {
        "status" => "dry_run", "name" => "docs", "version" => "1.2.0",
        "catalog_commit" => "b" * 40, "source_commit" => "c" * 40,
        "manifest_digest" => "d" * 64,
        "permissions" => {
          "risk" => "low", "capabilities" => [ "filesystem-read" ],
          "network_hosts" => [], "filesystem_read" => %w[repository task],
          "filesystem_write" => [], "secrets" => []
        }
      }
    end

    def install(project, source:, expected:)
      @calls << [ :install, project.fetch("name"), source, expected ]
      { "status" => "installed", "name" => expected.fetch("name") }
    end

    def preview_update(project, name:)
      @calls << [ :preview_update, project.fetch("name"), name ]
      {
        "status" => "dry_run", "name" => name,
        "from_commit" => "a" * 40, "from_manifest_digest" => "e" * 64,
        "to_commit" => "c" * 40, "manifest_digest" => "d" * 64,
        "diff" => {
          "metadata" => { "version" => { "from" => "1.0.0", "to" => "1.1.0" } },
          "files" => { "added" => [ "README.md" ], "removed" => [], "modified" => [ "workflow.yml" ] },
          "security" => {
            "filesystem_write" => { "added" => [ "repository/docs/**" ], "removed" => [] }
          },
          "dependencies" => {},
          "escalation" => true,
          "escalation_reasons" => [ "permissions.filesystem_write.added" ]
        }
      }
    end

    def update(project, name:, expected:, allow_escalation:)
      @calls << [ :update, project.fetch("name"), name, expected, allow_escalation ]
      { "status" => "updated", "name" => name }
    end

    def preview_remove(project, name:)
      @calls << [ :preview_remove, project.fetch("name"), name ]
      {
        "status" => "dry_run", "name" => name,
        "source_commit" => "a" * 40, "manifest_digest" => "e" * 64,
        "retained_commits" => [ "9" * 40 ], "deletable_commits" => [ "a" * 40 ]
      }
    end

    def remove(project, name:, expected:)
      @calls << [ :remove, project.fetch("name"), name, expected ]
      { "status" => "removed", "name" => name, "retained_commits" => [ "9" * 40 ] }
    end

    private

    def workflow_row(name, origin, **values)
      {
        "name" => name, "origin" => origin, "selection" => nil,
        "integrity" => nil, "catalog_visibility" => nil,
        "version" => nil, "source_commit" => nil, "manifest_digest" => nil
      }.merge(values.transform_keys(&:to_s))
    end
  end

  setup do
    @project = create_hive_project!("workflow-web-app")
    @lifecycle = FakeLifecycle.new
    WorkflowsController.instance_variable_set(:@workflow_lifecycle, @lifecycle)
    sign_in!
  end

  teardown do
    WorkflowsController.instance_variable_set(:@workflow_lifecycle, nil)
  end

  test "page exposes built-in, authored, and managed workflows for one selected project" do
    get workflows_path, params: { project: @project }

    assert_response :success
    assert_select "nav a.nav-link-active", text: "Workflows"
    assert_select "[data-workflow-origin='built_in']", text: /coding/
    assert_select "[data-workflow-origin='authored']", text: /release-notes/
    assert_select "[data-workflow-origin='managed'][data-workflow-selection='selected']", text: /demo.*verified/m
    assert_select "form[action='#{preview_workflow_install_path}'][data-turbo='false']"
    assert_select "form[action='#{preview_workflow_update_path}'][data-turbo='false']"
    assert_select "form[action='#{preview_workflow_remove_path}'][data-turbo='false']"
    assert_select "form[action='#{create_workflow_path}']"
    assert_select "select[name='template'] option[value='blank'][selected]",
                  text: "blank", count: 1,
                  message: "Web scaffolding must share the CLI's blank default"
    assert_match "legacy submission layout", response.body,
                 "the known v2 publishing gap must be explicit, not a broken action"
  end

  test "project workflow scaffolding delegates to the real lifecycle boundary" do
    post create_workflow_path,
         params: { project: @project, id: "launch-copy", template: "writing" }

    assert_redirected_to workflows_path(project: @project)
    assert_includes @lifecycle.calls, [ :scaffold, @project, "launch-copy", "writing" ]
  end

  test "install requires an untampered permission preview and explicit consent" do
    post preview_workflow_install_path,
         params: { project: @project, source: "honeycomb/docs@1.2.0" },
         headers: { "HTTP_ACCEPT" => "text/vnd.turbo-stream.html, text/html" }

    assert_response :success
    assert_equal "text/html", response.media_type,
                 "Turbo form previews must return a navigable page, not a bare stream MIME type"
    assert_select "#workflow-preview-heading", text: /Review install: docs 1.2.0/
    assert_select ".permission-grid", text: /Filesystem read.*repository, task/m
    token = preview_token(install_workflow_path)

    post install_workflow_path,
         params: { preview_token: "#{token}tampered", consent: "workflow_install" }
    assert_response :unprocessable_entity
    refute @lifecycle.calls.any? { |call| call.first == :install }

    post install_workflow_path,
         params: { preview_token: token, consent: "workflow_install" }

    assert_redirected_to workflows_path(project: @project)
    call = @lifecycle.calls.find { |entry| entry.first == :install }
    assert_equal "honeycomb/docs@1.2.0", call[2]
    assert_equal "c" * 40, call[3].fetch("source_commit")
  end

  test "security-expanding update requires ordinary and separate escalation consent" do
    post preview_workflow_update_path, params: { project: @project, name: "demo" }

    assert_response :success
    assert_select ".workflow-escalation", text: /Security capabilities expand/
    assert_select ".workflow-change-list", text: /Filesystem write.*repository\/docs\/\*\*/m
    assert_select "input[name='allow_escalation'][required]", 1
    token = preview_token(update_workflow_path)

    post update_workflow_path,
         params: { preview_token: token, consent: "workflow_update" }
    assert_response :unprocessable_entity
    refute @lifecycle.calls.any? { |call| call.first == :update }

    post update_workflow_path,
         params: {
           preview_token: token, consent: "workflow_update", allow_escalation: "1"
         }

    assert_redirected_to workflows_path(project: @project)
    call = @lifecycle.calls.find { |entry| entry.first == :update }
    assert_equal true, call[4]
    assert_equal "a" * 40, call[3].fetch("from_commit")
  end

  test "removal preview discloses retained and deletable generations before consent" do
    post preview_workflow_remove_path, params: { project: @project, name: "demo" }

    assert_response :success
    assert_select ".workflow-diff-summary", text: /1 generations retained.*1 unreferenced generations deleted/m
    token = preview_token(remove_workflow_path)

    post remove_workflow_path,
         params: { preview_token: token, consent: "workflow_remove" }

    assert_redirected_to workflows_path(project: @project)
    call = @lifecycle.calls.find { |entry| entry.first == :remove }
    assert_equal "a" * 40, call[3].fetch("source_commit")
    assert_match "1 task-pinned generation(s) retained", flash[:notice]
  end

  test "preview receipts cannot be replayed across operations" do
    post preview_workflow_update_path, params: { project: @project, name: "demo" }
    token = preview_token(update_workflow_path)

    post remove_workflow_path,
         params: { preview_token: token, consent: "workflow_remove" }

    assert_response :unprocessable_entity
    assert_match(/preview does not match this action/, response.body)
    refute @lifecycle.calls.any? { |call| call.first == :remove }
  end

  test "expired preview receipt is rejected independently of tampering" do
    post preview_workflow_remove_path, params: { project: @project, name: "demo" }
    token = preview_token(remove_workflow_path)

    travel WorkflowsController::PREVIEW_TTL + 1.second do
      post remove_workflow_path,
           params: { preview_token: token, consent: "workflow_remove" }
    end

    assert_response :unprocessable_entity
    assert_match(/preview expired or changed/, response.body)
    refute @lifecycle.calls.any? { |call| call.first == :remove }
  end

  test "every workflow mutation requires its operation-specific consent" do
    cases = [
      [ preview_workflow_install_path, { project: @project, source: "honeycomb/docs@1.2.0" }, install_workflow_path ],
      [ preview_workflow_update_path, { project: @project, name: "demo" }, update_workflow_path ],
      [ preview_workflow_remove_path, { project: @project, name: "demo" }, remove_workflow_path ]
    ]

    cases.each do |preview_path, preview_params, apply_path|
      post preview_path, params: preview_params
      post apply_path, params: { preview_token: preview_token(apply_path) }
      assert_response :unprocessable_entity
      assert_match(/confirm the reviewed workflow/, response.body)
    end

    refute @lifecycle.calls.any? { |call| %i[install update remove].include?(call.first) }
  end

  test "completed workflow mutations surface post-commit warnings" do
    @lifecycle.define_singleton_method(:update) do |*_args, **_kwargs|
      {
        "status" => "updated", "name" => "demo",
        "warnings" => [ "cleanup state commit failed; the workflow selection change already succeeded" ]
      }
    end
    post preview_workflow_update_path, params: { project: @project, name: "demo" }
    token = preview_token(update_workflow_path)

    post update_workflow_path,
         params: {
           preview_token: token, consent: "workflow_update", allow_escalation: "1"
         }

    assert_redirected_to workflows_path(project: @project)
    assert_match(/completed with warnings.*cleanup state commit failed/, flash[:alert])
  end

  private

  def preview_token(action)
    css_select("form[action='#{action}'] input[name='preview_token']").first["value"]
  end
end
