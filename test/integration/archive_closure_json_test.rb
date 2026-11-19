require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

# Real-process contract for `hive archive TARGET --reason ... --json`: stdout
# carries exactly one document whatever happens, and bin/hive's human error
# line and the local-context banner stay on stderr. The archive itself is
# exercised end to end in test/unit/task_closure_test.rb.
class ArchiveClosureJsonTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_failures_in_preview_and_apply_modes_print_one_result_document
    with_tmp_global_config do |home|
      {
        [] => "preview",
        [ "--yes" ] => "apply"
      }.each do |extra, mode|
        out, err, status = run_hive(
          home, "archive", "no-such-task", "--reason", "cancelled",
          "--attestation", "Not wanted", "--json", *extra
        )

        assert_equal Hive::ExitCodes::USAGE, status.exitstatus, err
        assert_equal 1, out.lines.length, "stdout must be exactly one JSON document, got: #{out.inspect}"
        payload = JSON.parse(out)
        assert_empty schemer.validate(payload).to_a, payload.inspect
        assert_equal false, payload.fetch("ok")
        assert_equal mode, payload.fetch("mode")
        refute payload.key?("applied")
        assert_includes err, "hive: #{payload.fetch('message')}"
      end
    end
  end

  def test_keyed_json_preview_is_refused_with_one_result_document
    with_tmp_global_config do |home|
      out, err, status = run_hive(
        home, "archive", "task", "--reason", "cancelled", "--attestation", "Not wanted",
        "--idempotency-key", "close-1", "--json"
      )

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus, err
      payload = JSON.parse(out)
      assert_empty schemer.validate(payload).to_a, payload.inspect
      assert_equal "usage", payload.fetch("error_kind")
      assert_includes payload.fetch("message"), "add --yes"
    end
  end

  private

  def run_hive(home, *args)
    Open3.capture3(
      {
        "HIVE_HOME" => home,
        "HOME" => home,
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
      },
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), HIVE_BIN, *args,
      chdir: home
    )
  end

  def schemer
    @schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-closure-result")))
    )
  end
end
