require "test_helper"
require "json"
require "hive/web/agents_auth"
require "hive/agent_profiles"

class AgentsAuthTest < Minitest::Test
  include HiveTestHelper

  def test_pi_token_writer_rejects_empty_json
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        auth = Hive::Web::AgentsAuth.new

        assert_raises(Hive::Error) { auth.write_pi_token("{}") }
      end
    end
  end

  def test_pi_token_writer_persists_valid_json
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        auth = Hive::Web::AgentsAuth.new
        path = auth.write_pi_token(JSON.generate("provider" => "x"))

        assert_equal File.join(home, ".pi", "agent", "auth.json"), path
        assert Hive::AgentProfiles.logged_in?(:pi, home: home)
      end
    end
  end
end
