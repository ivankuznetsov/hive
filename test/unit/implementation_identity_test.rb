require "test_helper"
require "hive/agent_profiles"
require "hive/implementation_identity"

class ImplementationIdentityTest < Minitest::Test
  include HiveTestHelper

  def test_native_arguments_reject_empty_or_multiline_values
    [ "", "safe\n--unsafe", "safe\r--unsafe", "safe\0unsafe" ].each do |value|
      assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
        Hive::ImplementationIdentity.validate_native_arguments([ value ])
      end
    end
  end

  def test_codex_native_default_reads_only_top_level_model
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".codex"))
      File.write(
        File.join(home, ".codex", "config.toml"),
        "# comment\nmodel = \"gpt-5.6-sol\" # selected\n[profile]\nmodel = \"ignored\"\n"
      )

      assert_equal "gpt-5.6-sol",
                   Hive::ImplementationIdentity::NativeDefaults.resolve(:codex, home: home)
      assert_equal "gpt-5.6-sol",
                   Hive::AgentProfiles.lookup(:codex).concrete_default_model(home: home)
    end
  end

  def test_native_default_rejects_unknown_provider_and_malformed_json
    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      Hive::ImplementationIdentity::NativeDefaults.resolve(:unknown, home: nil)
    end

    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "settings.json"), "{")

      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        Hive::ImplementationIdentity::NativeDefaults.resolve(:claude, home: home)
      end
      assert_match(/could not inspect claude default model/, error.message)
    end
  end

  def test_pi_native_default_reports_absent_model
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".pi"))
      File.write(File.join(home, ".pi", "settings.json"), JSON.generate("provider" => "google"))

      assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        Hive::ImplementationIdentity::NativeDefaults.resolve(:pi, home: home)
      end
    end
  end
end
