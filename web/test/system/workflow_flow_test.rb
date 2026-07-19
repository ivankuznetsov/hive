require "application_system_test_case"

class WorkflowFlowTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("workflow-browser-app")
    configure_owner!
  end

  teardown do
    WorkflowsController.instance_variable_set(:@workflow_lifecycle, nil)
    Hive::Workflows::Project.reset!
  end

  test "operator creates a project workflow from the primary navigation" do
    sign_in!
    click_link "Workflows"

    assert_current_path workflows_path
    select @project, from: "Project workflows"
    click_button "View workflows"
    assert_selector "h2", text: "#{@project} workflows", wait: 5
    assert_selector "[data-workflow-origin='built_in']", text: /coding.*default/m
    assert_selector "select[name='template'] option:checked", text: "blank"
    within("[aria-labelledby='author-workflow-heading']") do
      fill_in "Workflow ID", with: "launch-brief"
      select "research", from: "Starting template"
      click_button "Create workflow"
    end

    assert_selector ".flash-notice", text: "Created launch-brief", wait: 5
    assert_selector "[data-workflow-origin='authored']", text: "launch-brief"

    root = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", @project, ".hive-state", "workflows")
    assert File.file?(File.join(root, "launch-brief.yml")),
           "the browser must create the real project descriptor"
    assert File.file?(File.join(root, "launch-brief", "gather.md")),
           "the selected research template must create its stage instructions"
  end

  test "operator reviews exact managed permissions before installing" do
    lifecycle = FakeManagedLifecycle.new
    WorkflowsController.instance_variable_set(:@workflow_lifecycle, lifecycle)
    sign_in!
    visit workflows_path(project: @project)

    within("[aria-labelledby='install-workflow-heading']") do
      fill_in "Reviewed package", with: "honeycomb/docs@1.2.0"
      click_button "Preview install"
    end

    assert_selector "#workflow-preview-heading", text: "Review install: docs 1.2.0", wait: 5
    assert_selector ".permission-grid", text: /Filesystem read.*repository, task/m
    check "Install this exact verified package with the permissions above"
    click_button "Install workflow"

    assert_selector ".flash-notice", text: "docs installed", wait: 5
    assert_selector "[data-workflow-origin='managed']", text: /docs.*selected/m
    assert_equal [ "honeycomb/docs@1.2.0" ], lifecycle.installed_sources
  end

  test "mobile header keeps every capability visible beside the account action" do
    sign_in!
    page.current_window.resize_to(390, 844)
    visit workflows_path(project: @project)

    assert_button "Log out"
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const nav = document.querySelector("nav[aria-label='Primary']")
        return {
          pageWidth: document.documentElement.scrollWidth,
          viewportWidth: document.documentElement.clientWidth,
          navWidth: nav.scrollWidth,
          navViewport: nav.clientWidth,
          links: [...nav.querySelectorAll("a")].map((link) => link.textContent.trim())
        }
      })()
    JS
    assert_equal %w[Status Repos Workflows Agents Telegram], metrics.fetch("links")
    assert_operator metrics.fetch("navWidth"), :<=, metrics.fetch("navViewport"),
                    "primary capabilities must not start hidden in a tiny horizontal scroller"
    assert_equal metrics.fetch("viewportWidth"), metrics.fetch("pageWidth"),
                 "the workflow page must not overflow the mobile viewport"
  end

  class FakeManagedLifecycle
    attr_reader :installed_sources

    def initialize
      @installed_sources = []
    end

    def templates = %w[blank research]

    def list(_project)
      rows = [ row("coding", "built_in") ]
      rows << row("docs", "managed", selection: "selected", integrity: "verified", version: "1.2.0") if @installed_sources.any?
      rows
    end

    def preview_install(_project, source:)
      {
        "status" => "dry_run", "name" => "docs", "version" => "1.2.0",
        "catalog_commit" => "b" * 40, "source_commit" => "c" * 40,
        "manifest_digest" => "d" * 64,
        "permissions" => {
          "risk" => "low", "capabilities" => [ "filesystem-read" ],
          "network_hosts" => [], "filesystem_read" => %w[repository task],
          "filesystem_write" => [], "secrets" => []
        }
      }.tap { raise "unexpected source" unless source == "honeycomb/docs@1.2.0" }
    end

    def install(_project, source:, expected:)
      raise "preview identity lost" unless expected.fetch("source_commit") == "c" * 40

      @installed_sources << source
      { "status" => "installed", "name" => "docs" }
    end

    private

    def row(name, origin, **values)
      {
        "name" => name, "origin" => origin, "selection" => nil,
        "integrity" => nil, "catalog_visibility" => nil,
        "version" => nil, "source_commit" => nil, "manifest_digest" => nil
      }.merge(values.transform_keys(&:to_s))
    end
  end
end
