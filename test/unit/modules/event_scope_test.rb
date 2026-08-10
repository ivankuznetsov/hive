require "test_helper"
require "hive/modules/event_scope"

class ModulesEventScopeTest < Minitest::Test
  SELECTION = {
    "name" => "demo",
    "active" => {
      "source_commit" => "a" * 40,
      "configuration_digest" => "b" * 64
    }
  }.freeze
  HOOK = { "id" => "setup" }.freeze

  def test_ordinary_events_are_not_scoped
    event = { "source" => { "type" => "project_registry" }, "payload" => {} }

    assert Hive::Modules::EventScope.matches?(
      event: event, selection: SELECTION, hook: HOOK
    )
  end

  def test_install_setup_event_matches_only_its_generation_and_hook
    event = setup_event

    assert Hive::Modules::EventScope.matches?(
      event: event, selection: SELECTION, hook: HOOK
    )
    refute Hive::Modules::EventScope.matches?(
      event: event, selection: SELECTION, hook: { "id" => "other" }
    )
    refute Hive::Modules::EventScope.matches?(
      event: event,
      selection: SELECTION.merge(
        "active" => SELECTION.fetch("active").merge("source_commit" => "c" * 40)
      ),
      hook: HOOK
    )
  end

  def test_malformed_install_scope_fails_closed
    event = setup_event
    event.fetch("payload").delete("target_hooks")

    assert_raises(Hive::ConfigError) do
      Hive::Modules::EventScope.matches?(
        event: event, selection: SELECTION, hook: HOOK
      )
    end
  end

  private

  def setup_event
    {
      "source" => { "type" => "module_install" },
      "payload" => {
        "target_module" => "demo",
        "target_generation" => "a" * 40,
        "target_configuration_digest" => "b" * 64,
        "target_hooks" => [ "setup" ],
        "install_receipt_digest" => "c" * 64
      }
    }
  end
end
