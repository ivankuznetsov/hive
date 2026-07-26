require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hive/agent_profiles"
require "hive/implementation_identity/utility_models"

class AgentProfilesTest < Minitest::Test
  include HiveTestHelper

  def test_logged_in_false_when_only_a_config_dir_exists_without_credential
    with_tmp_dir do |home|
      # Both CLIs create their dir (settings/cache) *before* any login. A bare
      # non-empty dir must NOT read as logged in.
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "settings.json"), "{}")
      FileUtils.mkdir_p(File.join(home, ".codex"))
      File.write(File.join(home, ".codex", "history.jsonl"), "noise\n")

      refute Hive::AgentProfiles.logged_in?(:claude, home: home),
             "a ~/.claude with only settings must not report logged in"
      refute Hive::AgentProfiles.logged_in?(:codex, home: home),
             "a ~/.codex with only history must not report logged in"
    end
  end

  def test_logged_in_true_when_credential_artifact_present
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", ".credentials.json"),
                 JSON.generate("claudeAiOauth" => { "accessToken" => "x" }))
      FileUtils.mkdir_p(File.join(home, ".codex"))
      File.write(File.join(home, ".codex", "auth.json"), JSON.generate("OPENAI_API_KEY" => "x"))

      assert Hive::AgentProfiles.logged_in?(:claude, home: home)
      assert Hive::AgentProfiles.logged_in?(:codex, home: home)
    end
  end

  def test_logged_in_false_for_empty_credential_object
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".codex"))
      File.write(File.join(home, ".codex", "auth.json"), "{}")

      refute Hive::AgentProfiles.logged_in?(:codex, home: home),
             "an empty {} credential file is not a real credential"
    end
  end

  def test_logged_in_false_for_unknown_agent
    with_tmp_dir do |home|
      refute Hive::AgentProfiles.logged_in?(:nonesuch, home: home),
             "an unrecognized agent name must read as not logged in"
    end
  end

  def test_pi_preflight_honors_pi_coding_agent_dir
    with_tmp_dir do |home|
      agent_dir = File.join(home, "custom-pi")
      FileUtils.mkdir_p(agent_dir)
      File.write(File.join(agent_dir, "auth.json"), JSON.generate("provider" => "configured"))

      with_env("HOME" => home, "PI_CODING_AGENT_DIR" => agent_dir) do
        assert_nil Hive::AgentProfiles::PI.preflight!
      end
    end
  end

  def test_logged_in_swallows_path_errors_and_returns_false
    # A NUL byte in the home makes File.file?/File.read raise ArgumentError
    # ("string contains null byte"); the rescue must absorb it and report
    # not-logged-in rather than letting the probe blow up the status view.
    refute Hive::AgentProfiles.logged_in?(:pi, home: "bad\0home"),
           "a path-construction error must be rescued into a false result"
  end

  def teardown
    # Restore the v1 built-in registrations after any test that mutated the
    # registry. require'd files don't re-evaluate, so reset + explicit
    # re-register is the deterministic path.
    Hive::AgentProfiles.reset_for_tests!
    Hive::AgentProfiles.register(:claude, Hive::AgentProfiles::CLAUDE)
    Hive::AgentProfiles.register(:codex, Hive::AgentProfiles::CODEX)
    Hive::AgentProfiles.register(:pi, Hive::AgentProfiles::PI)
    Hive::AgentProfiles.register(:grok, Hive::AgentProfiles::GROK)
  end

  def test_lookup_returns_v1_built_in_profiles
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:claude)
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:codex)
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:pi)
    assert_kind_of Hive::AgentProfile, Hive::AgentProfiles.lookup(:grok)
  end

  def test_lookup_accepts_string_or_symbol
    by_sym = Hive::AgentProfiles.lookup(:claude)
    by_str = Hive::AgentProfiles.lookup("claude")
    assert_same by_sym, by_str
  end

  def test_claude_patrol_profile_reserves_context_and_disables_customizations
    claude = Hive::AgentProfiles.lookup(:claude)

    assert_equal 20_000, claude.initial_context_tokens
    assert_equal [
      "--safe-mode", "--disable-slash-commands",
      "--tools", "Read,Grep,Glob,Write"
    ], claude.cli_capabilities.fetch(:patrol_review_context)
    assert_equal [
      "--safe-mode", "--disable-slash-commands",
      "--tools", "Read,Grep,Glob,Bash,Edit,Write"
    ], claude.cli_capabilities.fetch(:patrol_fix_context)
  end

  def test_builtin_profiles_translate_normalized_identity_arguments
    claude = Hive::AgentProfiles.lookup(:claude).identity_arguments(
      model: "sonnet", effort: "medium"
    )
    codex = Hive::AgentProfiles.lookup(:codex).identity_arguments(
      model: "gpt-5.6-terra", effort: "high"
    )
    pi = Hive::AgentProfiles.lookup(:pi).identity_arguments(
      model: "google/gemini-2.5-pro", effort: "medium", pin_model: false
    )
    grok = Hive::AgentProfiles.lookup(:grok).identity_arguments(
      model: "grok-4.5", effort: "high"
    )

    assert_equal %w[--model sonnet --effort medium], claude.native_arguments
    assert_equal [ "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=high" ],
                 codex.native_arguments
    assert_equal [], pi.native_arguments
    refute pi.effort_supported
    assert_nil pi.effective_effort
    assert_equal [ "--model", "grok-4.5", "--reasoning-effort", "high" ],
                 grok.native_arguments
    assert grok.effort_supported
    assert_equal "high", grok.effective_effort
  end

  def test_utility_model_registry_never_crosses_providers
    assert_equal({ model: "sonnet", pin_model: true },
                 Hive::ImplementationIdentity::UtilityModels.resolve(:claude))
    assert_equal({ model: "gpt-5.6-terra", pin_model: true },
                 Hive::ImplementationIdentity::UtilityModels.resolve(:codex))
    assert_equal({ model: nil, pin_model: false },
                 Hive::ImplementationIdentity::UtilityModels.resolve(:pi))
    assert_equal({ model: nil, pin_model: false },
                 Hive::ImplementationIdentity::UtilityModels.resolve(:grok))
    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      Hive::ImplementationIdentity::UtilityModels.resolve(:unknown)
    end
  end

  def test_lookup_raises_unknown_agent_for_missing_name
    err = assert_raises(Hive::AgentProfiles::UnknownAgent) do
      Hive::AgentProfiles.lookup(:nonexistent)
    end
    assert_match(/unknown agent profile/, err.message)
  end

  def test_unknown_agent_inherits_config_error_for_exit_code
    assert_kind_of Hive::ConfigError,
                   Hive::AgentProfiles::UnknownAgent.new("test")
  end

  def test_register_replaces_existing_entry
    custom = Hive::AgentProfile.new(
      name: :custom,
      bin_default: "x",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )
    Hive::AgentProfiles.register(:claude, custom)
    assert_same custom, Hive::AgentProfiles.lookup(:claude)
  end

  def test_register_rejects_non_agent_profile
    err = assert_raises(ArgumentError) do
      Hive::AgentProfiles.register(:bad, "not a profile")
    end
    assert_match(/expected Hive::AgentProfile/, err.message)
  end

  def test_registered_names_lists_v1_built_ins
    names = Hive::AgentProfiles.registered_names.sort
    assert_includes names, :claude
    assert_includes names, :codex
    assert_includes names, :pi
    assert_includes names, :grok
  end

  def test_grok_prompt_rides_the_headless_flag_value
    grok = Hive::AgentProfiles.lookup(:grok)

    assert_equal :headless_flag_value, grok.prompt_style
  end

  def test_grok_profile_shape
    grok = Hive::AgentProfiles.lookup(:grok)

    assert_equal "grok", grok.bin_default
    assert_equal "-p", grok.headless_flag
    assert_equal "--always-approve", grok.permission_skip_flag
    assert_equal [ "--output-format", "streaming-json" ], grok.output_format_flags
    assert grok.headless_supported
    assert_equal "/ce-code-review", grok.format_skill_invocation("ce-code-review")
  end

  def test_grok_profile_verifies_native_plugin_skills
    Dir.mktmpdir do |home|
      grok_home = File.join(home, ".grok")
      install = File.join(grok_home, "installed-plugins", "compound-engineering-plugin-abc123")
      FileUtils.mkdir_p(File.join(install, "skills", "ce-code-review"))
      File.write(File.join(install, "skills", "ce-code-review", "SKILL.md"), "")
      FileUtils.mkdir_p(File.join(grok_home, "installed-plugins"))
      File.write(
        File.join(grok_home, "installed-plugins", "registry.json"),
        JSON.generate(
          "version" => 1,
          "repos" => {
            "compound-engineering-plugin-abc123" => {
              "path" => install,
              "plugins" => { "compound-engineering" => { "version" => "3.20.0" } }
            }
          }
        )
      )
      File.write(File.join(grok_home, "config.toml"), "[plugins]\nenabled = [\"compound-engineering\"]\n")

      with_env("HOME" => home, "GROK_HOME" => grok_home) do
        status, path = Hive::AgentProfiles.lookup(:grok).verify_skill("/ce-code-review")
        assert_equal :present, status
        assert_equal File.join(install, "skills", "ce-code-review", "SKILL.md"), path
      end
    end
  end

  def test_grok_logged_in_probes_auth_json
    Dir.mktmpdir do |home|
      refute Hive::AgentProfiles.logged_in?(:grok, home: home), "no dir yet"
      FileUtils.mkdir_p(File.join(home, ".grok"))
      File.write(File.join(home, ".grok", "auth.json"), "{}")

      refute Hive::AgentProfiles.logged_in?(:grok, home: home), "empty stub is not a credential"
      File.write(File.join(home, ".grok", "auth.json"), '{"access_token":"x"}')

      assert Hive::AgentProfiles.logged_in?(:grok, home: home)
    end
  end

  def test_grok_logged_in_uses_auth_path_override
    Dir.mktmpdir do |home|
      auth_path = File.join(home, "shared-auth.json")
      File.write(auth_path, '{"access_token":"x"}')

      with_env("GROK_AUTH_PATH" => auth_path, "GROK_HOME" => "/missing/grok-home") do
        assert Hive::AgentProfiles.logged_in?(:grok, home: home)
      end
    end
  end

  def test_grok_logged_in_rejects_relative_auth_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "auth.json"), '{"access_token":"x"}')

      Dir.chdir(dir) do
        with_env(
          "GROK_AUTH_PATH" => "auth.json",
          "XAI_API_KEY" => nil,
          "GROK_CODE_XAI_API_KEY" => nil
        ) { refute Hive::AgentProfiles.logged_in?(:grok) }
      end
    end
  end

  def test_grok_logged_in_ignores_unused_relative_paths_with_api_key
    with_env(
      "GROK_AUTH_PATH" => "auth.json",
      "GROK_HOME" => "relative/grok-home",
      "XAI_API_KEY" => "test-key"
    ) do
      assert Hive::AgentProfiles.logged_in?(:grok)
    end
  end

  def test_grok_logged_in_rejects_relative_grok_home
    with_env("GROK_AUTH_PATH" => nil, "GROK_HOME" => "relative/grok-home") do
      refute Hive::AgentProfiles.logged_in?(:grok)
    end
  end

  def test_grok_logged_in_explicit_locations_do_not_require_home_resolution
    Dir.mktmpdir do |auth_dir|
      auth_path = File.join(auth_dir, "shared-auth.json")
      File.write(auth_path, '{"access_token":"x"}')
      grok_home = File.join(auth_dir, "grok-home")
      FileUtils.mkdir_p(grok_home)
      File.write(File.join(grok_home, "auth.json"), '{"access_token":"x"}')

      with_replaced_singleton_method(Dir, :home, -> { raise ArgumentError, "no home" }) do
        with_env("GROK_AUTH_PATH" => auth_path, "GROK_HOME" => nil) do
          assert Hive::AgentProfiles.logged_in?(:grok)
        end

        with_env("GROK_AUTH_PATH" => nil, "GROK_HOME" => grok_home) do
          assert Hive::AgentProfiles.logged_in?(:grok)
        end
      end
    end
  end

  def test_registered_check
    assert Hive::AgentProfiles.registered?(:claude)
    refute Hive::AgentProfiles.registered?(:nonexistent)
  end

  def test_format_skill_invocation_preserves_claude_slash_invocations
    profile = Hive::AgentProfiles.lookup(:claude)
    assert_equal "/plan", profile.format_skill_invocation("/plan")
    assert_equal "/plan", profile.format_skill_invocation("plan")
  end

  def test_format_skill_invocation_normalizes_legacy_compound_engineering_namespace
    claude = Hive::AgentProfiles.lookup(:claude)
    codex = Hive::AgentProfiles.lookup(:codex)
    pi = Hive::AgentProfiles.lookup(:pi)

    assert_equal "/ce-code-review",
                 claude.format_skill_invocation("/compound-engineering:ce-code-review")
    assert_equal "/ce-code-review",
                 claude.format_skill_invocation("compound-engineering:ce-code-review")
    assert_equal "/ce-code-review",
                 codex.format_skill_invocation("/compound-engineering:ce-code-review")
    assert_equal "/ce-code-review",
                 codex.format_skill_invocation("compound-engineering:ce-code-review")
    assert_equal "/skill:ce-code-review",
                 pi.format_skill_invocation("/compound-engineering:ce-code-review")
    assert_equal "/skill:ce-code-review",
                 pi.format_skill_invocation("compound-engineering:ce-code-review")
  end

  def test_format_skill_invocation_normalizes_pi_skill_form
    profile = Hive::AgentProfiles.lookup(:pi)
    assert_equal "/skill:plan", profile.format_skill_invocation("/plan")
    assert_equal "/skill:ce-brainstorm", profile.format_skill_invocation("/compound-engineering:ce-brainstorm")
    assert_equal "/skill:plan", profile.format_skill_invocation("/skill:plan")
    assert_equal "/skill:plan", profile.format_skill_invocation("plan")
  end

  # --- agents.* config overrides --------------------------------------

  def test_lookup_with_cfg_applies_bin_override
    cfg = { "agents" => { "claude" => { "bin" => "/opt/custom/claude" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    refute_same Hive::AgentProfiles.lookup(:claude), profile
    assert_equal "/opt/custom/claude", profile.bin_default
    # Registry-stored profile must NOT be mutated.
    assert_equal "claude", Hive::AgentProfiles.lookup(:claude).bin_default
  end

  def test_lookup_with_cfg_applies_min_version_override
    cfg = { "agents" => { "claude" => { "min_version" => "99.99.99" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    assert_equal "99.99.99", profile.min_version
  end

  def test_lookup_with_cfg_returns_registered_profile_when_no_override
    cfg = { "agents" => { "codex" => { "bin" => "/opt/codex" } } }
    profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    assert_same Hive::AgentProfiles.lookup(:claude), profile
  end

  def test_lookup_with_cfg_returns_registered_profile_when_cfg_nil
    profile = Hive::AgentProfiles.lookup(:claude, cfg: nil)
    assert_same Hive::AgentProfiles.lookup(:claude), profile
  end

  def test_lookup_with_cfg_raises_config_error_on_unknown_override_key
    cfg = { "agents" => { "claude" => { "min_versn" => "1.2.3" } } }
    err = assert_raises(Hive::ConfigError) do
      Hive::AgentProfiles.lookup(:claude, cfg: cfg)
    end
    assert_match(/min_versn/, err.message)
    assert_match(/agents\.claude/, err.message)
  end

  def test_lookup_with_cfg_accepts_string_or_symbol_name_for_overrides
    cfg = { "agents" => { "codex" => { "bin" => "/opt/codex" } } }
    by_sym = Hive::AgentProfiles.lookup(:codex, cfg: cfg)
    by_str = Hive::AgentProfiles.lookup("codex", cfg: cfg)
    assert_equal "/opt/codex", by_sym.bin_default
    assert_equal "/opt/codex", by_str.bin_default
  end
end
