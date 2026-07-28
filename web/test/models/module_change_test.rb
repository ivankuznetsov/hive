require "test_helper"

class ModuleChangeTest < ActiveSupport::TestCase
  class FakeLifecycle
    attr_reader :applies

    def initialize
      @applies = []
      @previews = 0
    end

    def preview(_project, operation:, source:, name:, choices:)
      @previews += 1
      {
        "operation" => operation, "status" => "preview", "name" => name || "demo",
        "preview_receipt" => "1.#{@previews.to_s(16).rjust(64, '0')}",
        "proposed" => {
          "settings" => [], "hooks" => [],
          "grants" => {
            "repository_write" => true,
            "github_mutations" => %w[pull_requests issues],
            "external_commands" => [], "network_hosts" => [],
            "filesystem_read" => [], "filesystem_write" => [], "secrets" => []
          },
          "permission_digest" => "d" * 64
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

  test "signed preview binds one opaque consent token to every permission atom" do
    change = ModuleChange.preview!(
      operation: "install", project: @project, source: "honeycomb/demo",
      choices: { "settings" => [ "mode=safe" ], "hooks" => [ "run=enabled" ], "grants" => [] }
    )
    consents = change.permission_consents
    assert_equal(
      [
        [ "repository_write", true ],
        [ "github_mutations", "issues" ],
        [ "github_mutations", "pull_requests" ]
      ],
      consents.map { |row| [ row.fetch("category"), row.fetch("value") ] }
    )
    atom = verifier.verify(
      consents.first.fetch("token"), purpose: ModuleChange::PERMISSION_PURPOSE
    )
    assert_equal(
      %w[category module module_receipt operation permission_digest project value],
      atom.keys.sort
    )
    assert_equal "install", atom.fetch("operation")
    assert_equal @project.name, atom.fetch("project")
    assert_equal "demo", atom.fetch("module")
    assert_equal change.fetch("preview_receipt"), atom.fetch("module_receipt")
    assert_equal "d" * 64, atom.fetch("permission_digest")

    outcome = ModuleChange.apply!(
      operation: "install", token: change.token, consent: "module_install",
      permission_atom_tokens: consents.map { |row| row.fetch("token") }
    )
    assert_equal "demo installed.", outcome.notice
    applied = @lifecycle.applies.sole.last
    assert_equal [ "mode=safe" ], applied.fetch(:choices).fetch("settings")
    assert_equal change.fetch("preview_receipt"), applied.fetch(:receipt)
  end

  test "permission consent requires an exact token set from the same preview" do
    change = preview_change
    tokens = change.permission_consents.map { |row| row.fetch("token") }
    invalid_sets = [
      tokens.drop(1),
      tokens + [ tokens.first ],
      [ "repository_write", *tokens.drop(1) ],
      [ "#{tokens.first}tampered", *tokens.drop(1) ]
    ]

    context = verifier.verify(
      tokens.first, purpose: ModuleChange::PERMISSION_PURPOSE
    )
    category_only = verifier.generate(
      context.except("value"),
      expires_in: ModuleChange::PREVIEW_TTL, purpose: ModuleChange::PERMISSION_PURPOSE
    )
    duplicate_atom = verifier.generate(
      context,
      expires_in: ModuleChange::PREVIEW_TTL, purpose: ModuleChange::PERMISSION_PURPOSE
    )
    extra = verifier.generate(
      context.merge("category" => "network_hosts", "value" => "extra.example.test"),
      expires_in: ModuleChange::PREVIEW_TTL, purpose: ModuleChange::PERMISSION_PURPOSE
    )
    invalid_sets.concat(
      [
        [ category_only, *tokens.drop(1) ],
        tokens + [ duplicate_atom ],
        tokens + [ extra ]
      ]
    )

    invalid_sets.each do |supplied|
      assert_raises(Hive::Error) do
        ModuleChange.apply!(
          operation: "install", token: change.token, consent: "module_install",
          permission_atom_tokens: supplied
        )
      end
    end

    other = preview_change
    other_tokens = other.permission_consents.map { |row| row.fetch("token") }
    assert_raises(Hive::Error) do
      ModuleChange.apply!(
        operation: "install", token: other.token, consent: "module_install",
        permission_atom_tokens: [ tokens.first, *other_tokens.drop(1) ]
      )
    end
    assert_empty @lifecycle.applies
  end

  test "pre-atom preview tokens cannot bypass permission confirmation" do
    old_token = verifier.generate(
      {
        "operation" => "install", "project" => @project.name,
        "module_receipt" => "1.#{'a' * 64}", "required_grants" => [],
        "source" => "honeycomb/demo", "name" => nil,
        "choices" => { "settings" => [ "mode=safe" ] }
      },
      expires_in: ModuleChange::PREVIEW_TTL, purpose: ModuleChange::PREVIEW_PURPOSE
    )

    assert_raises(Hive::Error) do
      ModuleChange.apply!(
        operation: "install", token: old_token, consent: "module_install",
        permission_atom_tokens: []
      )
    end
    assert_empty @lifecycle.applies
  end

  test "preview fails closed when the permission map or digest is incomplete" do
    change = preview_change
    change.details.fetch("proposed").fetch("grants").delete("secrets")
    assert_raises(Hive::ConfigError) { change.token }

    change = preview_change
    change.details.fetch("proposed")["permission_digest"] = nil
    assert_raises(Hive::Error) { change.token }
  end

  test "receipt cannot cross operation or outlive its preview window" do
    change = preview_change
    assert_raises(Hive::Error) do
      ModuleChange.apply!(operation: "disable", token: change.token, consent: "module_disable")
    end
    token = change.token
    travel ModuleChange::PREVIEW_TTL + 1.second do
      assert_raises(Hive::Error) do
        ModuleChange.apply!(
          operation: "install", token: token, consent: "module_install",
          permission_atom_tokens: change.permission_consents.map { |row| row.fetch("token") }
        )
      end
    end
  end

  private

  def preview_change
    ModuleChange.preview!(
      operation: "install", project: @project, source: "honeycomb/demo",
      choices: { "settings" => [ "mode=safe" ] }
    )
  end

  def verifier
    Rails.application.message_verifier(:module_lifecycle)
  end
end
