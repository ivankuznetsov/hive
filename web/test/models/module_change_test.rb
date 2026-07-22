require "test_helper"

class ModuleChangeTest < ActiveSupport::TestCase
  class FakeLifecycle
    attr_reader :applies

    def initialize
      @applies = []
    end

    def preview(_project, operation:, source:, name:, choices:)
      {
        "operation" => operation, "status" => "preview", "name" => name || "demo",
        "preview_receipt" => "1.#{'a' * 64}",
        "proposed" => {
          "settings" => [], "hooks" => [],
          "grants" => { "repository_write" => true, "github_mutations" => [ "pull_requests" ] }
        }
      }.tap { raise "source missing" if operation == "install" && source.blank? || choices.blank? }
    end

    def apply(project, **attributes)
      @applies << [ project.name, attributes ]
      { "name" => "demo", "status" => "installed" }
    end
  end

  setup do
    @project_name = create_hive_project!("module-change-model")
    @project = Project.find!(@project_name)
    @lifecycle = FakeLifecycle.new
    HiveModule.lifecycle = @lifecycle
  end

  teardown { HiveModule.reset_lifecycle! }

  test "signed preview binds choices and requires every separate grant consent" do
    change = ModuleChange.preview!(
      operation: "install", project: @project, source: "honeycomb/demo",
      choices: { "settings" => [ "mode=safe" ], "hooks" => [ "run=enabled" ], "grants" => [] }
    )
    assert_equal %w[github_mutations repository_write], change.required_grants

    assert_raises(Hive::Error) do
      ModuleChange.apply!(
        operation: "install", token: change.token, consent: "module_install",
        grant_consents: [ "repository_write" ]
      )
    end
    outcome = ModuleChange.apply!(
      operation: "install", token: change.token, consent: "module_install",
      grant_consents: %w[github_mutations repository_write]
    )
    assert_equal "demo installed.", outcome.notice
    applied = @lifecycle.applies.sole.last
    assert_equal [ "mode=safe" ], applied.fetch(:choices).fetch("settings")
    assert_equal "1.#{'a' * 64}", applied.fetch(:receipt)
  end

  test "receipt cannot cross operation or outlive its preview window" do
    change = ModuleChange.preview!(
      operation: "install", project: @project, source: "honeycomb/demo",
      choices: { "settings" => [ "mode=safe" ] }
    )
    assert_raises(Hive::Error) do
      ModuleChange.apply!(operation: "disable", token: change.token, consent: "module_disable")
    end
    token = change.token
    travel ModuleChange::PREVIEW_TTL + 1.second do
      assert_raises(Hive::Error) do
        ModuleChange.apply!(
          operation: "install", token: token, consent: "module_install",
          grant_consents: %w[github_mutations repository_write]
        )
      end
    end
  end
end
