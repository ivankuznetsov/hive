require "test_helper"
require "json"
require "hive/commands/forget"

# End-to-end coverage for `hive forget NAME`. Drives the command class
# directly. Asserts both the human-readable text path and the --json
# envelope shape, plus the USAGE (64) exit-code contract for unknown
# names — symmetric with `hive metrics --project NAME` so agent
# wrappers can branch on a single canonical error_kind value.
class ForgetCommandTest < Minitest::Test
  include HiveTestHelper

  def test_forget_removes_named_entry_text_output
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      out, _err = capture_io { Hive::Commands::Forget.new("drop").call }
      assert_match(/removed drop/, out)
      assert_equal [ "keep" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_forget_emits_success_envelope_under_json
    with_tmp_global_config do
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      out, _err = capture_io { Hive::Commands::Forget.new("drop", json: true).call }
      payload = JSON.parse(out)
      assert_equal "hive-forget", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal true, payload["ok"]
      assert_equal true, payload["removed"]
      assert_equal "drop", payload["name"]
      assert_equal "/tmp/drop", payload["path"]
      assert_equal "/tmp/drop/.hive-state", payload["hive_state_path"]
    end
  end

  def test_forget_unknown_name_exits_usage
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      _out, err, status = with_captured_exit do
        Hive::Commands::Forget.new("ghost").call
      end
      assert_equal Hive::ExitCodes::USAGE, status
      assert_match(/no entry named "ghost"/, err)
      assert_equal [ "keep" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_forget_unknown_name_json_emits_error_envelope
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      out, _err, status = with_captured_exit do
        Hive::Commands::Forget.new("ghost", json: true).call
      end
      assert_equal Hive::ExitCodes::USAGE, status

      payload = JSON.parse(out)
      assert_equal "hive-forget", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unknown_project", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/no entry named "ghost"/, payload["message"])
    end
  end

  def test_forget_if_exists_unknown_name_exits_success_without_mutating_registry
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      out, _err = capture_io { Hive::Commands::Forget.new("ghost", if_exists: true).call }
      assert_match(/already absent/, out)
      assert_equal [ "keep" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_forget_if_exists_unknown_name_json_emits_removed_false
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      out, _err = capture_io { Hive::Commands::Forget.new("ghost", json: true, if_exists: true).call }
      payload = JSON.parse(out)
      assert_equal "hive-forget", payload["schema"]
      assert_equal true, payload["ok"]
      assert_equal "ghost", payload["name"]
      assert_equal false, payload["removed"]
      refute payload.key?("path")
      refute payload.key?("hive_state_path")
    end
  end

  def test_forget_missing_name_argument_exits_usage
    with_tmp_global_config do
      _out, err, status = with_captured_exit do
        Hive::Commands::Forget.new(nil).call
      end
      assert_equal Hive::ExitCodes::USAGE, status
      assert_match(/missing project NAME/, err)
    end
  end

  # Distinct error_kind for missing-NAME (empty argv) vs unknown-NAME
  # (typo against a real registry). Used to share `unknown_project`,
  # which collapsed two distinct failure modes for agent retry wrappers.
  def test_forget_missing_name_json_emits_missing_name_error_kind
    with_tmp_global_config do
      out, _err, status = with_captured_exit do
        Hive::Commands::Forget.new(nil, json: true).call
      end
      assert_equal Hive::ExitCodes::USAGE, status

      payload = JSON.parse(out)
      assert_equal "missing_name", payload["error_kind"],
                   "empty NAME positional must surface as missing_name, not unknown_project"
      assert_equal "UsageError", payload["error_class"]
    end
  end

  # Every error envelope must carry `error_class` (cross-reviewer P1).
  # The shared Hive::Schemas::ErrorEnvelope.build helper guarantees it;
  # this test pins the contract end-to-end so a future rewrite that
  # bypasses the helper trips here.
  def test_forget_error_envelope_carries_error_class
    with_tmp_global_config do
      out, _err, _status = with_captured_exit do
        Hive::Commands::Forget.new("ghost", json: true).call
      end
      payload = JSON.parse(out)
      assert_equal "UsageError", payload["error_class"]
    end
  end

  # P1 #4: malformed YAML used to leak as InternalError(70). It must
  # now surface as ConfigError → exit 78 with `error_kind: "config"`.
  def test_forget_malformed_yaml_emits_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects: [\nthis: is: not: yaml")

      out, _err, status = with_captured_exit do
        Hive::Commands::Forget.new("anything", json: true).call
      end
      assert_equal Hive::ExitCodes::CONFIG, status,
                   "malformed YAML must exit 78 (CONFIG), not 70 (SOFTWARE)"

      payload = JSON.parse(out)
      assert_equal "config", payload["error_kind"]
      assert_equal "ConfigError", payload["error_class"]
      assert_match(/not valid YAML/, payload["message"])
    end
  end

  # NEW-1: typoed $HIVE_HOME used to surface as `unknown_project` /
  # exit 64 because unregister_project silently returned nil when the
  # config path didn't exist. validate_hive_home! is now called first
  # so the operator sees the real cause.
  def test_forget_with_typoed_hive_home_emits_config_error
    bad = "/tmp/hive-typo-#{Process.pid}-#{rand(1_000_000)}"
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = bad

    out, _err, status = with_captured_exit do
      Hive::Commands::Forget.new("anything", json: true).call
    end
    assert_equal Hive::ExitCodes::CONFIG, status,
                 "typoed HIVE_HOME must exit 78 (CONFIG), not 64 (USAGE)"

    payload = JSON.parse(out)
    assert_equal "config", payload["error_kind"],
                 "typoed HIVE_HOME must not masquerade as unknown_project"
  ensure
    ENV["HIVE_HOME"] = prev
  end

  # PR-review P2 #4: `unregister_project` matches `name: 42` (Integer)
  # via `to_s.==.to_s`, so a hand-edited row with an Integer name is
  # reachable from the CLI's String argv. The success envelope used to
  # leak that Integer into `"name": 42`, violating the schema's
  # `"name": { "type": "string" }` contract. `to_s` in the payload keeps
  # the JSON envelope schema-conformant.
  def test_forget_success_payload_stringifies_integer_name
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ { "name" => 42, "path" => "/tmp/hive-int" } ] }.to_yaml
      )

      out, _err = capture_io { Hive::Commands::Forget.new("42", json: true).call }
      payload = JSON.parse(out)
      assert_equal "42", payload["name"],
                   "schema requires string `name`; Integer registry row must be stringified"
    end
  end

  # P3 #25: schema describes `path` / `hive_state_path` as "Absolute path",
  # but a hand-edited row can carry a relative or `~`-prefixed string.
  # Normalize via File.expand_path in the success payload.
  def test_forget_success_payload_normalizes_relative_path_to_absolute
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "rel", "path" => "relative/dir", "hive_state_path" => "relative/dir/.hive-state" }
          ]
        }.to_yaml
      )

      out, _err = capture_io { Hive::Commands::Forget.new("rel", json: true).call }
      payload = JSON.parse(out)
      assert_equal File.expand_path("relative/dir"), payload["path"],
                   "schema says 'Absolute path' — relative input must be normalized"
      assert payload["hive_state_path"].start_with?("/"),
             "hive_state_path must also be absolute"
    end
  end
end
