require "test_helper"
require "hive/config"

class ConfigGlobalAgentsTest < Minitest::Test
  include HiveTestHelper

  def test_load_global_agents_defaults_when_key_absent
    with_tmp_global_config do
      assert_equal %w[claude codex], Hive::Config.load_global_agents
    end
  end

  def test_write_and_load_global_agents_round_trips_in_backend_order
    with_tmp_global_config do |home|
      written = Hive::Config.write_global_agents!(%w[pi claude pi])

      assert_equal %w[claude pi], written
      assert_equal %w[claude pi], Hive::Config.load_global_agents

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal %w[claude pi], data.dig("agents", "selected")
      assert_equal [], data.fetch("registered_projects")
    end
  end

  def test_write_global_agents_preserves_other_agent_settings
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "notes" => "operator-owned" }
      }.to_yaml)

      Hive::Config.write_global_agents!(%w[codex])

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal "operator-owned", data.dig("agents", "notes")
      assert_equal %w[codex], data.dig("agents", "selected")
    end
  end

  def test_load_global_agents_rejects_malformed_agents_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => "claude"
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/agents .* must be a Hash/, err.message)
    end
  end

  def test_load_global_agents_rejects_malformed_selected_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => "claude" }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/agents\.selected .* must be an Array/, err.message)
    end
  end

  def test_load_global_agents_rejects_unknown_backend
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ "claude", "unknown" ] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/unknown backend "unknown"/, err.message)
    end
  end

  def test_load_global_agents_rejects_blank_string_in_selected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ "claude", "" ] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/must contain non-empty strings/, err.message)
    end
  end

  def test_load_global_agents_rejects_non_string_in_selected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ 123 ] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/must contain non-empty strings/, err.message)
    end
  end

  def test_load_global_agents_rejects_empty_selected
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/must list at least one backend/, err.message)
    end
  end

  def test_write_global_agents_rejects_empty_selection
    with_tmp_global_config do
      err = assert_raises(Hive::ConfigError) { Hive::Config.write_global_agents!([]) }
      assert_match(/must list at least one backend/, err.message)
    end
  end

  def test_write_global_agents_rejects_pre_existing_non_hash_agents_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => "claude"
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.write_global_agents!(%w[claude]) }
      assert_match(/agents .* must be a Hash/, err.message)
    end
  end

  def test_default_global_agents_filters_out_unregistered_backends
    with_restricted_registry(%i[claude]) do
      assert_equal %w[claude], Hive::Config.default_global_agents
    end
  end

  def test_default_global_agents_raises_when_no_default_backend_registered
    # When neither claude nor codex is registered (only the opt-in pi),
    # there is no default to fall back to and the method raises rather
    # than returning []. Exercises the `raise ConfigError` branch.
    with_restricted_registry(%i[pi]) do
      err = assert_raises(Hive::ConfigError) { Hive::Config.default_global_agents }
      assert_match(/no default agent backend is registered/, err.message)
    end
  end

  def test_registered_agent_names_projects_registry_symbols_to_strings
    # Locks the symbol→string projection that BackendPrompt and
    # normalize_global_agents both depend on.
    names = Hive::Config.registered_agent_names

    assert_equal %w[claude codex pi], names.sort
    assert(names.all?(String), "registered_agent_names must be strings, not symbols")
  end

  def test_load_global_agents_distinguishes_valid_but_unregistered_backend
    # A backend that IS in GLOBAL_AGENT_BACKENDS but isn't registered on
    # this machine (the synced-dotfiles case) gets the "valid but not
    # installed here" message, NOT the typo-flavored "unknown backend" one.
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ "codex" ] }
      }.to_yaml)

      with_restricted_registry(%i[claude]) do
        err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
        assert_match(/"codex", which is valid but/, err.message)
        assert_match(/not installed or registered/, err.message)
        refute_match(/unknown backend/, err.message)
      end
    end
  end

  def test_load_global_agents_rejects_typo_with_unknown_backend_message
    # A name not in GLOBAL_AGENT_BACKENDS at all keeps the typo-flavored
    # "unknown backend" message — the other half of the message split.
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ "claud" ] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/unknown backend "claud"/, err.message)
      refute_match(/valid but/, err.message)
    end
  end

  def test_load_global_agents_accepts_capitalized_names_case_insensitively
    # The capitalization the setup prompt itself displays ([claude]) must
    # load: normalize downcases before the allowed-list check.
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => %w[Claude CODEX] }
      }.to_yaml)

      assert_equal %w[claude codex], Hive::Config.load_global_agents
    end
  end

  def test_load_global_agents_defaults_on_cold_start_without_config_file
    # The genuine first-run path: no config.yml exists yet.
    # with_tmp_global_config pre-writes one, so delete it to exercise the
    # `File.exist?(path) ? load_global_config(path) : {}` branch that
    # resolves to the built-in defaults.
    with_tmp_global_config do |home|
      File.delete(File.join(home, "config.yml"))

      assert_equal %w[claude codex], Hive::Config.load_global_agents
    end
  end

  def test_load_global_agents_defaults_when_selected_is_null
    # A bare `selected:` (YAML key present, value null) is treated as "unset"
    # and resolves to the defaults — deliberately asymmetric with the empty
    # `selected: []` array, which raises (see test below).
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => nil }
      }.to_yaml)

      assert_equal %w[claude codex], Hive::Config.load_global_agents
    end
  end

  def test_write_global_agents_overwrites_existing_selection_keeping_siblings
    # The realistic re-run-`hive setup` path: a `selected:` already exists
    # alongside an operator-owned sibling; the write overwrites selected and
    # preserves the sibling.
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => %w[claude], "notes" => "operator-owned" }
      }.to_yaml)

      written = Hive::Config.write_global_agents!(%w[codex pi])

      assert_equal %w[codex pi], written
      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal %w[codex pi], data.dig("agents", "selected")
      assert_equal "operator-owned", data.dig("agents", "notes")
    end
  end

  def test_write_global_agents_attributes_bad_argument_to_caller_not_file
    # A bad caller argument (e.g. [123]) must blame the argument, not the
    # config file — and never carry the misleading "no file present" suffix.
    with_tmp_global_config do
      err = assert_raises(Hive::ConfigError) { Hive::Config.write_global_agents!([ 123 ]) }
      assert_match(/must contain non-empty strings/, err.message)
      assert_match(/write_global_agents! argument/, err.message)
      refute_match(/no file present/, err.message)
    end
  end

  def test_write_global_agents_returns_frozen_array
    with_tmp_global_config do
      written = Hive::Config.write_global_agents!(%w[claude])
      assert written.frozen?, "write_global_agents! must return a frozen array"
    end
  end

  def test_default_global_agents_returns_frozen_array
    assert Hive::Config.default_global_agents.frozen?,
           "default_global_agents must return a frozen array"
  end

  def test_global_agent_backends_matches_registry
    # Drift guard mirroring the load-time CHOICES/MODES assertion in
    # init/prompts.rb: GLOBAL_AGENT_BACKENDS (strings) and the AgentProfiles
    # registry (symbols) are two sources of truth for "known backends".
    # Registering a 4th profile without listing it here would silently make
    # it unselectable; this fails when the two sets diverge.
    assert_equal Hive::AgentProfiles.registered_names.map(&:to_s).sort,
                 Hive::Config::GLOBAL_AGENT_BACKENDS.sort,
                 "GLOBAL_AGENT_BACKENDS and the AgentProfiles registry have drifted"
  end

  private

  # Run the block with only `names` registered in the AgentProfiles
  # registry, restoring the full registry afterward. Lets a test exercise
  # the registered-intersection filter in default_global_agents /
  # normalize_global_agents, which is a no-op while all three built-ins
  # are auto-registered.
  def with_restricted_registry(names)
    originals = Hive::AgentProfiles.registered_names.to_h do |name|
      [ name, Hive::AgentProfiles.lookup(name) ]
    end
    Hive::AgentProfiles.reset_for_tests!
    names.each { |name| Hive::AgentProfiles.register(name, originals.fetch(name)) }
    yield
  ensure
    Hive::AgentProfiles.reset_for_tests!
    originals&.each { |name, profile| Hive::AgentProfiles.register(name, profile) }
  end
end
