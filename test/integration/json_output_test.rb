require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/status"

# Pin the agent-callable JSON contracts emitted by `hive status --json` and
# `hive run --json`. Schema versions are checked explicitly so a future
# breaking change to either payload fails this test instead of silently
# breaking downstream parsers.
class JsonOutputTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def test_status_json_is_a_single_parseable_document_with_schema_header
    with_tmp_global_config do
      out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
      assert_equal 1, out.lines.count, "JSON output must be a single line on stdout (no stray puts)"
      payload = JSON.parse(out)
      assert_equal "hive-status", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal [], payload["projects"], "empty registry must surface as projects:[]"
      assert payload["generated_at"].match?(/\A\d{4}-\d{2}-\d{2}T/), "generated_at must be ISO-8601"
    end
  end

  def test_status_json_emits_task_records_with_stable_keys
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "json status probe").call }

        out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
        payload = JSON.parse(out)
        proj = payload["projects"].find { |p| p["name"] == project }
        refute_nil proj, "registered project should appear in JSON output"
        task = proj["tasks"].first
        refute_nil task

        %w[stage slug folder state_file marker attrs mtime age_seconds claude_pid claude_pid_alive]
          .each { |k| assert task.key?(k), "JSON task record must include '#{k}'" }
        assert_equal "1-inbox", task["stage"]
        assert_equal "waiting", task["marker"], "fresh idea.md is in WAITING state"
        assert_kind_of Integer, task["age_seconds"]
        assert_nil task["claude_pid"], "no claude_pid until an agent has run"
      end
    end
  end

  def test_run_json_emits_marker_and_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json run probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        # Fake claude writes a WAITING brainstorm.md so report() sees that marker.
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1.\n### A1.\n<!-- WAITING -->\n"

        out, _err = capture_io { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        assert_equal 1, out.lines.count, "JSON output must be a single line on stdout (no stray puts)"
        payload = JSON.parse(out)
        assert_equal "hive-run", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal "brainstorm", payload["stage"]
        assert_equal 2, payload["stage_index"]
        assert_equal slug, payload["slug"]
        assert_equal "waiting", payload["marker"]

        next_action = payload["next_action"]
        refute_nil next_action
        assert_equal "edit", next_action["kind"]
        assert next_action["target"].end_with?("/brainstorm.md")
        assert_includes next_action["rerun_with"], "hive run"
      end
    end
  end

  def test_run_json_on_complete_marker_returns_approve_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json complete probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Requirements\n- foo\n<!-- COMPLETE -->\n"

        out, _err = capture_io { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        payload = JSON.parse(out)
        assert_equal "complete", payload["marker"]

        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::APPROVE, next_action["kind"]
        assert_equal slug, next_action["slug"]
        assert_equal "2-brainstorm", next_action["from_stage"]
        assert_equal "3-plan", next_action["to_stage"]
        assert_equal "hive approve #{slug} --from 2-brainstorm", next_action["command"]
        # Back-compat fields kept for callers that parsed the old MV shape.
        assert next_action["to"].end_with?("3-plan/")
        assert_equal brainstorm_dir, next_action["from"]
      end
    end
  end

  # Pin the JSON-mode :error contract: a dual signal where the JSON document
  # carries the marker + attrs AND the process exits with TASK_IN_ERROR (3).
  # A future refactor that drops the post-puts raise (or wraps it in a
  # rescue) would silently regress to exit 0; this test catches that.
  def test_run_json_on_error_marker_emits_no_op_and_exits_three
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json error probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1" # forces Agent#handle_exit to set :error

        out, _err, status = with_captured_exit { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "JSON mode must still exit 3 on :error (the JSON document is emitted before the raise)"

        payload = JSON.parse(out)
        assert_equal "error", payload["marker"]
        assert_equal Hive::Schemas::NextActionKind::NO_OP, payload["next_action"]["kind"]
        assert_equal "exit_code", payload["attrs"]["reason"]
        assert_equal "exit_code", payload["next_action"]["error"]["reason"]
      end
    end
  end

  # Defensive pin: every emitted next_action.kind must be in the closed
  # NextActionKind::ALL set. Drives THREE distinct producer arms (waiting,
  # complete, error) so a typo in any one of them is caught — the round-1
  # version of this test only exercised :waiting.
  def test_every_emitted_next_action_kind_is_in_the_closed_enum
    fixtures = [
      { content: "## Round 1\n<!-- WAITING -->\n",
        env: {},
        expected_kind: Hive::Schemas::NextActionKind::EDIT },
      { content: "## Requirements\n- foo\n<!-- COMPLETE -->\n",
        env: {},
        expected_kind: Hive::Schemas::NextActionKind::APPROVE },
      { content: nil,                       # exit 1 → :error marker
        env: { "HIVE_FAKE_CLAUDE_EXIT" => "1" },
        expected_kind: Hive::Schemas::NextActionKind::NO_OP }
    ]

    fixtures.each_with_index do |fixture, i|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          capture_io { Hive::Commands::New.new(File.basename(dir), "kind probe #{i}").call }
          slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
          brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
          FileUtils.mkdir_p(File.dirname(brainstorm_dir))
          FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

          fixture[:env].each { |k, v| ENV[k] = v }
          if fixture[:content]
            ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
            ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = fixture[:content]
          end

          out, _err, _status = with_captured_exit do
            Hive::Commands::Run.new(brainstorm_dir, json: true).call
          end
          payload = JSON.parse(out)
          kind = payload["next_action"]["kind"]
          assert_includes Hive::Schemas::NextActionKind::ALL, kind,
                          "fixture #{i}: kind=#{kind.inspect} is outside the closed NextActionKind enum"
          assert_equal fixture[:expected_kind], kind,
                       "fixture #{i}: producer arm emitted unexpected kind"
        end
      end
    end
  end
end
