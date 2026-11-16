require "test_helper"
require "hive/agent_git_gate"
require "hive/git_config_pins"

class GitConfigPinsTest < Minitest::Test
  RERERE_OFF = {
    "GIT_CONFIG_KEY_0" => "rerere.enabled", "GIT_CONFIG_VALUE_0" => "false",
    "GIT_CONFIG_KEY_1" => "rerere.autoupdate", "GIT_CONFIG_VALUE_1" => "false"
  }.freeze

  def test_pins_rerere_off_when_no_config_entries_exist
    assert_equal({ "GIT_EDITOR" => "true", "GIT_CONFIG_COUNT" => "2", **RERERE_OFF },
                 Hive::GitConfigPins.apply({ "GIT_EDITOR" => "true" }))
  end

  def test_extends_hive_owned_entries_without_clobbering_them
    hive_owned = Hive::AgentGitGate.read_environment
    count = Hive::ManagedGit::CONFIG.length

    pinned = Hive::GitConfigPins.apply(hive_owned)

    assert_equal (count + 2).to_s, pinned.fetch("GIT_CONFIG_COUNT")
    hive_owned.except("GIT_CONFIG_COUNT").each do |key, value|
      assert_equal value, pinned.fetch(key), "#{key} must keep its Hive-owned value"
    end
    assert_equal "rerere.enabled", pinned.fetch("GIT_CONFIG_KEY_#{count}")
    assert_equal "false", pinned.fetch("GIT_CONFIG_VALUE_#{count}")
    assert_equal "rerere.autoupdate", pinned.fetch("GIT_CONFIG_KEY_#{count + 1}")
    assert_equal "false", pinned.fetch("GIT_CONFIG_VALUE_#{count + 1}")
  end

  def test_appends_after_inherited_entries_the_overrides_leave_alone
    inherited = { "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "user.signingkey",
                  "GIT_CONFIG_VALUE_0" => "ABC123" }

    pinned = Hive::GitConfigPins.apply({}, inherited: inherited)

    assert_equal "3", pinned.fetch("GIT_CONFIG_COUNT")
    refute pinned.key?("GIT_CONFIG_KEY_0"), "the inherited operator entry must stay untouched"
    assert_equal "rerere.enabled", pinned.fetch("GIT_CONFIG_KEY_1")
    assert_equal "rerere.autoupdate", pinned.fetch("GIT_CONFIG_KEY_2")
  end

  def test_an_override_count_wins_over_the_inherited_one
    inherited = { "GIT_CONFIG_COUNT" => "5" }

    assert_equal "2", Hive::GitConfigPins.apply({ "GIT_CONFIG_COUNT" => nil }, inherited: inherited)
      .fetch("GIT_CONFIG_COUNT")
    assert_equal "3", Hive::GitConfigPins.apply({ "GIT_CONFIG_COUNT" => "1" }, inherited: inherited)
      .fetch("GIT_CONFIG_COUNT")
  end

  def test_reads_counts_the_way_git_does
    assert_equal 0, Hive::GitConfigPins.existing_count(nil)
    assert_equal 0, Hive::GitConfigPins.existing_count("")
    assert_equal 2, Hive::GitConfigPins.existing_count("2")
    assert_equal 2, Hive::GitConfigPins.existing_count(" +2")
    assert_equal 8, Hive::GitConfigPins.existing_count("08")
    [ "abc", "2 ", "-1", "1_0", "0x2" ].each do |bogus|
      assert_nil Hive::GitConfigPins.existing_count(bogus), bogus.inspect
    end
  end

  # Git refuses every command when it cannot parse the count, so no merge
  # can run. Hive leaves that environment as it is rather than guessing.
  def test_leaves_an_environment_git_would_reject_unchanged
    environment = { "GIT_CONFIG_COUNT" => "not-a-number" }

    assert_same environment, Hive::GitConfigPins.apply(environment)
  end
end
