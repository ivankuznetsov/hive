require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/status"
require "open3"

# Pin the agent-callable error contract emitted by `hive status --json`.
# Status's producer surface is narrow: ConfigError (e.g., HIVE_HOME unreadable)
# and InternalError (StandardError wrap). Both must produce a parseable
# ErrorPayload validating against the bounded running-status schema.
class StatusErrorEnvelopeTest < Minitest::Test
  include HiveTestHelper

  def setup
    @schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-running-status")))
    )
  end

  # Happy path regression: SuccessPayload still validates.
  def test_success_path_emits_validating_payload
    with_tmp_global_config do
      out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
      payload = JSON.parse(out)
      assert_equal "hive-running-status", payload["schema"]
      assert_equal true, payload["ok"], "SuccessPayload carries `ok: true` so the discriminator is symmetric with ErrorPayload's `ok: false`"
      assert @schemer.valid?(payload),
             "SuccessPayload must validate (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # ConfigError → kind "config", exit 78. Stub Hive::Config.registered_projects
  # to raise ConfigError deterministically (production raise sites are in
  # Hive::Config; the kind dispatch is what the contract pins).
  def test_config_error_emits_envelope
    with_tmp_global_config do
      cmd = Hive::Commands::Status.new(json: true)
      Hive::Config.singleton_class.alias_method(:__orig_registered_projects, :registered_projects)
      Hive::Config.define_singleton_method(:registered_projects) do
        raise Hive::ConfigError, "HIVE_HOME unreadable: simulated"
      end

      begin
        out, err, status = with_captured_exit { cmd.call }
        assert_equal Hive::ExitCodes::CONFIG, status, "ConfigError exits 78"
        payload = JSON.parse(out)
        assert_equal "hive-running-status", payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "config", payload["error_kind"]
        assert_equal "ConfigError", payload["error_class"]
        assert_equal Hive::ExitCodes::CONFIG, payload["exit_code"]
        assert_includes payload["message"], "HIVE_HOME unreadable"
        assert_includes err, "hive:", "human-path stderr message must still fire (raise was preserved)"
        assert @schemer.valid?(payload),
               "ConfigError envelope must validate (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
      ensure
        Hive::Config.singleton_class.alias_method(:registered_projects, :__orig_registered_projects)
        Hive::Config.singleton_class.send(:remove_method, :__orig_registered_projects)
      end
    end
  end

  # StandardError → wrapped as InternalError, kind "internal", exit 70.
  def test_standard_error_wraps_to_internal_envelope
    with_tmp_global_config do
      cmd = Hive::Commands::Status.new(json: true)
      Hive::Config.singleton_class.alias_method(:__orig_registered_projects, :registered_projects)
      Hive::Config.define_singleton_method(:registered_projects) do
        raise RuntimeError, "boom from test"
      end

      begin
        out, _err, status = with_captured_exit { cmd.call }
        assert_equal Hive::ExitCodes::SOFTWARE, status, "InternalError exits 70 (SOFTWARE)"
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "internal", payload["error_kind"]
        assert_equal "InternalError", payload["error_class"]
        assert_includes payload["message"], "RuntimeError",
                        "wrapped message must preserve the original class for debugging"
        assert @schemer.valid?(payload)
      ensure
        Hive::Config.singleton_class.alias_method(:registered_projects, :__orig_registered_projects)
        Hive::Config.singleton_class.send(:remove_method, :__orig_registered_projects)
      end
    end
  end

  # End-to-end coverage for the plan's smoke command:
  # `HIVE_HOME=/nonexistent bin/hive status --json | jq .ok` must report
  # `false` (config error envelope), not `true` (empty projects). Before
  # Fix 2, registered_projects returned [] silently on a missing HIVE_HOME,
  # which made `ok` look true. The validate_hive_home! check raises
  # Hive::ConfigError, which propagates through Status#call's rescue into
  # the envelope.
  def test_explicitly_nonexistent_hive_home_emits_config_envelope
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = "/tmp/hive-test-status-nonexistent-#{rand(1_000_000)}"
    begin
      cmd = Hive::Commands::Status.new(json: true)
      out, _err, status = with_captured_exit { cmd.call }
      assert_equal Hive::ExitCodes::CONFIG, status,
                   "explicitly nonexistent HIVE_HOME must exit 78 (CONFIG), not 0"
      payload = JSON.parse(out)
      assert_equal false, payload["ok"],
                   "smoke command `HIVE_HOME=/nonexistent hive status --json | jq .ok` must report false"
      assert_equal "config", payload["error_kind"]
      assert_equal "ConfigError", payload["error_class"]
      assert_includes payload["message"], "HIVE_HOME is set to a path that does not exist"
      assert @schemer.valid?(payload),
             "explicit-nonexistent envelope must validate (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
    ensure
      ENV["HIVE_HOME"] = prev
    end
  end

  # R3 regression: without --json, error path is stderr-text + exit code,
  # no JSON on stdout.
  def test_human_path_no_json_unchanged_on_error
    with_tmp_global_config do
      cmd = Hive::Commands::Status.new(json: false)
      Hive::Config.singleton_class.alias_method(:__orig_registered_projects, :registered_projects)
      Hive::Config.define_singleton_method(:registered_projects) do
        raise Hive::ConfigError, "simulated config error"
      end

      begin
        out, err, status = with_captured_exit { cmd.call }
        assert_equal Hive::ExitCodes::CONFIG, status
        assert_empty out.strip, "no --json must mean no JSON on stdout"
        assert_includes err, "hive:", "stderr human message must still fire"
      ensure
        Hive::Config.singleton_class.alias_method(:registered_projects, :__orig_registered_projects)
        Hive::Config.singleton_class.send(:remove_method, :__orig_registered_projects)
      end
    end
  end

  def test_bin_hive_clears_inspection_even_when_registration_finish_raises
    result = run_bootstrap_bin(%w[status --operational], scenario: "finish_failure")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_equal %w[finish clear], result.fetch(:events)
  end

  def test_bin_hive_refuses_inherited_and_unconfirmed_operational_fallbacks
    inherited = run_bootstrap_bin(
      %w[status --operational --json], scenario: "activation_failure",
      confirmed: true,
      extra_env: { "HIVE_RUNTIME_CHILD_RESERVATION_ID" => "reservation" }
    )
    refute inherited.fetch(:status).success?
    assert_equal "state_storage_read_only", JSON.parse(inherited.fetch(:stdout)).fetch("runtime_code")
    assert inherited.fetch(:events).first.include?(":true:/state:state_storage_read_only")

    unconfirmed = run_bootstrap_bin(
      %w[status --operational --json], scenario: "activation_failure", confirmed: false
    )
    refute unconfirmed.fetch(:status).success?
    assert unconfirmed.fetch(:events).first.include?("activate:true:false:false")
  end

  def test_bin_hive_mutating_commands_report_registration_storage_failure
    %w[list run].each do |route|
      result = run_bootstrap_bin(
        [ route, "project", "--json" ], scenario: "registration_failure", confirmed: true
      )

      refute result.fetch(:status).success?, route
      payload = JSON.parse(result.fetch(:stdout))
      assert_equal "state_storage_read_only", payload.fetch("runtime_code")
      assert_equal route, payload.fetch("action")
      refute result.fetch(:events).any? { |event| event.start_with?("activate:true") }
    end
  end

  private

  def run_bootstrap_bin(argv, scenario:, confirmed: false, extra_env: {})
    with_tmp_dir do |root|
      bin_dir = File.join(root, "bin")
      lib_dir = File.join(root, "lib")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.mkdir_p(lib_dir)
      FileUtils.cp(File.expand_path("../../bin/hive", __dir__), File.join(bin_dir, "hive"))
      FileUtils.cp(
        File.expand_path("../support/runtime_bootstrap_hive.rb", __dir__),
        File.join(lib_dir, "hive.rb")
      )
      events = File.join(root, "events")
      env = {
        "HIVE_HOME" => "/state", "BOOTSTRAP_SCENARIO" => scenario,
        "BOOTSTRAP_CONFIRMED" => confirmed ? "1" : "0", "BOOTSTRAP_EVENTS" => events
      }.merge(extra_env)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, File.join(bin_dir, "hive"), *argv)
      {
        stdout: stdout, stderr: stderr, status: status,
        events: File.file?(events) ? File.readlines(events, chomp: true) : []
      }
    end
  end
end
