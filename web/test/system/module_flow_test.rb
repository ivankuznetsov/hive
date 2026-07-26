require "application_system_test_case"

class ModuleFlowTest < ApplicationSystemTestCase
  class FakeLifecycle
    attr_reader :installed

    def initialize
      @installed = false
    end

    def list(_project, include_history: false)
      return [] unless installed
      [
        {
          "name" => "demo", "lifecycle_state" => "active", "installed" => true, "enabled" => true,
          "epoch" => 1, "active" => { "version" => "1.0.0", "source_commit" => "a" * 40 },
          "previous" => nil, "settings" => [], "grants" => { "repository_write" => true },
          "hooks" => [], "latest_decision" => nil, "failure_reason" => nil
        }
      ].tap { raise "history mismatch" if include_history }
    end

    def preview(_project, operation:, source:, name:, choices:)
      raise "unexpected preview" unless operation == "install" && source == "honeycomb/demo@1.0.0"
      raise "choices missing" unless choices.fetch("hooks") == [ "scan=enabled" ]
      {
        "name" => name || "demo", "status" => "preview", "preview_receipt" => "1.#{'a' * 64}",
        "candidate" => {
          "version" => "1.0.0", "source_commit" => "a" * 40,
          "catalog_commit" => "b" * 40, "manifest_digest" => "c" * 64
        },
        "proposed" => {
          "settings" => [
            { "name" => "mode", "type" => "enum", "required" => true, "secret" => false,
              "value" => "safe", "binding" => nil }
          ],
          "hooks" => [
            { "id" => "scan", "enabled" => true, "target" => { "kind" => "entrypoint", "id" => "demo.run" },
              "schedules" => [], "events" => [], "concurrency" => "drop", "default_enabled" => false }
          ],
          "grants" => {
            "repository_write" => true, "github_mutations" => [],
            "external_commands" => [], "network_hosts" => [],
            "filesystem_read" => [], "filesystem_write" => [], "secrets" => []
          },
          "permission_digest" => "d" * 64
        }
      }
    end

    def apply(_project, operation:, **)
      raise "wrong operation" unless operation == "install"
      @installed = true
      { "name" => "demo", "status" => "installed" }
    end
  end

  setup do
    @project = create_hive_project!("module-browser-app")
    @lifecycle = FakeLifecycle.new
    HiveModule.lifecycle = @lifecycle
    configure_owner!
  end

  teardown { HiveModule.reset_lifecycle! }

  test "operator previews grants and installs from primary navigation" do
    sign_in!
    click_link "Modules"
    visit modules_path(project: @project)
    assert_selector "#project-modules-heading", text: "#{@project} modules"

    within("[aria-labelledby='install-module-heading']") do
      fill_in "Reviewed package", with: "honeycomb/demo@1.0.0"
      fill_in "Setting choices", with: "mode=safe"
      fill_in "Hook choices", with: "scan=enabled"
      fill_in "Permission grants", with: "repository_write=true"
      click_button "Preview install"
    end
    assert_selector "#module-preview-heading", text: "Review install: demo", wait: 5
    check "Apply this exact install transaction"
    check "Separately grant Repository write: enabled"
    click_button "Apply install"

    assert_selector ".flash-notice", text: "demo installed", wait: 5
    assert_selector "[data-module-name='demo'][data-module-state='active']"
  end
end
