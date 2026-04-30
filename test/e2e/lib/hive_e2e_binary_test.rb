require_relative "../../test_helper"
require "json"
require "open3"
require_relative "paths"

class E2EBinaryTest < Minitest::Test
  def hive_e2e
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e")
  end

  def test_list_json_emits_parseable_envelope_with_schema_version_1
    out, err, status = Open3.capture3(hive_e2e, "list", "--json")
    assert status.success?, "bin/hive-e2e list --json should exit 0, stderr was: #{err}"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-scenarios", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_kind_of Array, payload["scenarios"], "envelope should carry a scenarios array"
    assert payload["scenarios"].any?, "at least one scenario should be inventoried"
    sample = payload["scenarios"].first
    %w[name tags description path steps_count].each do |key|
      assert sample.key?(key), "scenario summary should expose #{key.inspect}"
    end
  end

  def test_clean_json_emits_deleted_and_kept_counts
    out, err, status = Open3.capture3(hive_e2e, "clean", "--json")
    assert status.success?, "bin/hive-e2e clean --json should exit 0, stderr was: #{err}"

    payload = JSON.parse(out)
    assert_equal "hive-e2e-clean", payload["schema"]
    assert_equal 1, payload["schema_version"]
    assert_kind_of Integer, payload["deleted"]
    assert_kind_of Integer, payload["kept"]
  end

  def test_version_short_flag_prints_hive_version
    out, _err, status = Open3.capture3(hive_e2e, "--version")
    assert status.success?
    assert_equal "#{Hive::VERSION}\n", out
  end

  # Thor's default for unknown commands is to print a deprecation warning
  # and exit 0; we override `exit_on_failure?` to true so wrappers / CI
  # see a non-zero status instead. Pin the contract here.
  def test_unknown_command_exits_non_zero
    _out, _err, status = Open3.capture3(hive_e2e, "no-such-command")
    refute_equal 0, status.exitstatus,
                 "bin/hive-e2e should exit non-zero on unknown commands (got #{status.exitstatus.inspect})"
  end
end
