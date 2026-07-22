require "test_helper"

class ModulesTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  class FakeLifecycle
    attr_reader :calls

    def initialize
      @calls = []
    end

    def list(project, include_history: false)
      @calls << [ :list, project.name, include_history ]
      return [] if project.name == "module-web-empty"
      [ status_row(project.name) ]
    end

    def preview(project, operation:, source:, name:, choices:)
      @calls << [ :preview, project.name, operation, source, name, choices ]
      proposal = if %w[install update].include?(operation)
        {
          "settings" => [
            { "name" => "mode", "type" => "enum", "required" => true, "secret" => false, "value" => "safe", "binding" => nil },
            { "name" => "api_token", "type" => "secret", "required" => true, "secret" => true, "value" => nil, "binding" => "MODULE_TOKEN" }
          ],
          "hooks" => [
            {
              "id" => "scan", "enabled" => true, "target" => { "kind" => "entrypoint", "id" => "demo.run" },
              "schedules" => [ "0 * * * *" ], "events" => [ "task.completed" ], "concurrency" => "drop",
              "default_enabled" => false
            }
          ],
          "grants" => {
            "repository_write" => true, "github_mutations" => [], "external_commands" => [],
            "network_hosts" => [], "filesystem_read" => [ "repository" ], "filesystem_write" => [],
            "secrets" => [ "MODULE_TOKEN" ]
          }
        }
      end
      {
        "operation" => operation, "status" => "preview", "name" => name.presence || "demo",
        "preview_receipt" => "1.#{'a' * 64}",
        "candidate" => proposal && {
          "version" => "1.0.0", "source_commit" => "a" * 40,
          "catalog_commit" => "b" * 40, "manifest_digest" => "c" * 64
        },
        "proposed" => proposal, "selection" => {}
      }
    end

    def apply(project, **attributes)
      @calls << [ :apply, project.name, attributes ]
      { "name" => attributes[:name].presence || "demo", "status" => operation_status(attributes.fetch(:operation)) }
    end

    private

    def operation_status(operation)
      { "install" => "installed", "update" => "updated", "enable" => "enabled",
        "disable" => "disabled", "uninstall" => "uninstalled" }.fetch(operation)
    end

    def status_row(project)
      {
        "name" => "demo", "lifecycle_state" => "active", "installed" => true, "enabled" => true,
        "epoch" => 2, "high_water_at" => "2026-07-22T10:00:00.000000Z",
        "generated_at" => "2026-07-22T11:00:00.000000Z",
        "active" => { "version" => "1.0.0", "source_commit" => "a" * 40 }, "previous" => nil,
        "integrity" => {},
        "settings" => [
          { "name" => "api_token", "type" => "secret", "required" => true, "secret" => true,
            "value" => nil, "binding" => "MODULE_TOKEN", "available" => true }
        ],
        "grants" => { "repository_write" => true }, "grant_digest" => "d" * 64,
        "hooks" => [
          { "id" => "scan", "enabled" => true, "cursor" => nil, "binding_digest" => "e" * 64,
            "target" => { "kind" => "entrypoint", "id" => "demo.run" }, "concurrency" => "drop",
            "schedules" => [ "0 * * * *" ], "event_bindings" => [ "task.completed" ],
            "next_trigger_at" => "2026-07-22T12:00:00.000000Z" }
        ],
        "latest_decision" => { "outcome" => "skip", "reason" => "duplicate" },
        "latest_attempt" => nil, "retry" => nil, "artifacts" => [], "failure_reason" => nil,
        "history_available" => false, "project_marker" => project
      }
    end
  end

  setup do
    @project = create_hive_project!("module-web-app")
    @other = create_hive_project!("module-web-empty")
    @lifecycle = FakeLifecycle.new
    HiveModule.lifecycle = @lifecycle
    sign_in!
  end

  teardown { HiveModule.reset_lifecycle! }

  test "page is project filtered and renders only the shared redacted status" do
    get modules_path, params: { project: @project }

    assert_response :success
    assert_select "nav a.nav-link-active", text: "Modules"
    assert_select "[data-module-name='demo'][data-module-state='active']", text: /MODULE_TOKEN.*available/m
    refute_includes response.body, "raw-secret-value"

    get modules_path, params: { project: @other }
    assert_response :success
    assert_select "[data-module-name]", count: 0
  end

  test "install preview binds exact choices and separately consents every grant" do
    post preview_module_install_path, params: {
      project: @project, source: "honeycomb/demo@1.0.0",
      settings: "mode=safe\napi_token=MODULE_TOKEN\n",
      hooks: "scan=enabled\n", grants: "repository_write=true\nfilesystem_read=repository\nsecrets=MODULE_TOKEN\n"
    }

    assert_response :success
    assert_select "#module-preview-heading", text: /Review install: demo/
    assert_select ".permission-grid", text: /api_token.*MODULE_TOKEN/m
    assert_select "input[name='grant_consents[]'][value='repository_write'][required]"
    assert_select "input[name='grant_consents[]'][value='filesystem_read'][required]"
    assert_select "input[name='grant_consents[]'][value='secrets'][required]"
    token = preview_token(apply_module_install_path)

    post apply_module_install_path, params: {
      preview_token: token, consent: "module_install", grant_consents: [ "repository_write" ]
    }
    assert_response :unprocessable_entity
    refute @lifecycle.calls.any? { |call| call.first == :apply }

    post apply_module_install_path, params: {
      preview_token: token, consent: "module_install",
      grant_consents: %w[filesystem_read repository_write secrets]
    }
    assert_redirected_to modules_path(project: @project)
    apply = @lifecycle.calls.find { |call| call.first == :apply }
    assert_equal [ "scan=enabled" ], apply.last.fetch(:choices).fetch("hooks")
    assert_equal "1.#{'a' * 64}", apply.last.fetch(:receipt)
  end

  test "state preview is operation bound and requires consent" do
    post preview_module_disable_path, params: { project: @project, name: "demo" }
    assert_response :success
    token = preview_token(apply_module_disable_path)

    post apply_module_enable_path, params: { preview_token: token, consent: "module_enable" }
    assert_response :unprocessable_entity
    post apply_module_disable_path, params: { preview_token: token, consent: "module_disable" }
    assert_redirected_to modules_path(project: @project)
  end

  private

  def preview_token(action)
    css_select("form[action='#{action}'] input[name='preview_token']").first["value"]
  end
end
