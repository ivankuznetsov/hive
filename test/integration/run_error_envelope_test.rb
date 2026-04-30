require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

# Pin the agent-callable error contract emitted by `hive run --json`.
# Every Hive::Error subclass that surfaces in a Run.call path must produce
# a parseable ErrorPayload on stdout, validate against schemas/hive-run.v1.json,
# and preserve the existing dual-signal SuccessPayload write on :error markers.
class RunErrorEnvelopeTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    @schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    )
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  # When report_json wrote the SuccessPayload before raising TaskInErrorState,
  # the rescue must NOT add a second envelope — that would break JSON.parse(stdout).
  # This is the load-bearing test for the @stdout_written guard.
  def test_dual_signal_emits_exactly_one_json_document
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "dual signal probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)
        ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1" # forces :error marker

        out, _err, status = with_captured_exit { Hive::Commands::Run.new(brainstorm_dir, json: true).call }

        nonblank = out.lines.reject { |l| l.strip.empty? }
        assert_equal 1, nonblank.length,
                     "dual-signal must emit exactly one JSON document on stdout (the SuccessPayload), not two"
        payload = JSON.parse(nonblank.first)
        assert_equal "error", payload["marker"], "the SuccessPayload must be the one emitted, not an ErrorPayload"
        refute payload.key?("ok"), "SuccessPayload arm doesn't carry an ok key (only ErrorPayload does)"
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "exit code 3 (TASK_IN_ERROR) must still fire after the SuccessPayload write"
      end
    end
  end

  # ConcurrentRunError raises before report_json runs, so the envelope is the
  # only thing on stdout.
  def test_concurrent_run_error_emits_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "concurrent probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        # Plant a fresh stale lock — a live PID owned by us so Lock treats it as a
        # genuine concurrent runner rather than a stale lock to recover.
        File.write(File.join(brainstorm_dir, ".lock"),
                   { "pid" => Process.pid, "slug" => slug, "stage" => "brainstorm",
                     "started_at" => Time.now.utc.iso8601 }.to_yaml)

        out, err, status = with_captured_exit { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        assert_equal Hive::ExitCodes::TEMPFAIL, status, "ConcurrentRunError must exit 75"
        payload = JSON.parse(out)
        assert_equal "hive-run", payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "concurrent_run", payload["error_kind"]
        assert_equal "ConcurrentRunError", payload["error_class"]
        assert_equal Hive::ExitCodes::TEMPFAIL, payload["exit_code"]
        refute_empty payload["message"], "envelope must surface a non-empty message"
        assert_includes err, "hive:", "human-path stderr message must still fire (raise was preserved)"
        assert @schemer.valid?(payload),
               "ErrorPayload must validate against schemas/hive-run.v1.json (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
      end
    end
  end

  # AmbiguousSlug auto-extras `candidates`. The case-statement ordering puts
  # AmbiguousSlug before InvalidTaskPath fallthroughs (AmbiguousSlug <
  # InvalidTaskPath); without that ordering this test surfaces invalid_task_path.
  def test_ambiguous_slug_emits_envelope_with_candidates
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        # Seed two folders sharing the same slug across two stages.
        slug = "ambig-260430-aaaa"
        a = File.join(dir, ".hive-state", "stages", "1-inbox", slug)
        b = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(a)
        FileUtils.mkdir_p(b)
        File.write(File.join(a, "idea.md"), "<!-- WAITING -->\n")
        File.write(File.join(b, "brainstorm.md"), "<!-- WAITING -->\n")

        out, _err, status = with_captured_exit do
          Hive::Commands::Run.new(slug, json: true).call
        end
        assert_equal Hive::ExitCodes::USAGE, status, "AmbiguousSlug inherits InvalidTaskPath exit_code (USAGE=64)"
        payload = JSON.parse(out)
        assert_equal "ambiguous_slug", payload["error_kind"],
                     "AmbiguousSlug must NOT shadow into invalid_task_path or generic"
        assert_kind_of Array, payload["candidates"]
        assert_equal 2, payload["candidates"].length, "candidates auto-extra must be populated"
      end
    end
  end

  # WrongStage: running on 1-inbox raises WrongStage (Stages::Inbox.run! is
  # an inert capture zone). The case-statement must surface "wrong_stage",
  # not the generic fallthrough. Since FinalStageReached < WrongStage, both
  # share this branch — testing WrongStage is sufficient.
  def test_wrong_stage_matches_wrong_stage_kind
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "wrong stage probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        inbox_dir = File.join(dir, ".hive-state", "stages", "1-inbox", slug)

        out, _err, status = with_captured_exit do
          Hive::Commands::Run.new(inbox_dir, json: true).call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status, "WrongStage exits 4"
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "wrong_stage", payload["error_kind"],
                     "WrongStage (and its subclass FinalStageReached) must surface as wrong_stage, not generic"
        assert_equal "WrongStage", payload["error_class"]
        assert @schemer.valid?(payload),
               "WrongStage envelope must validate (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
      end
    end
  end

  # ConfigError: stub the resolver to raise ConfigError so the kind mapping
  # is exercised deterministically. Production raise sites are in
  # Hive::Config / Hive::Stages::Base; the kind dispatch is the contract here.
  def test_config_error_emits_config_kind_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "config probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        cmd = Hive::Commands::Run.new(brainstorm_dir, json: true)
        cmd.define_singleton_method(:pick_runner) { |_task| raise Hive::ConfigError, "bad config" }

        out, _err, status = with_captured_exit { cmd.call }
        assert_equal Hive::ExitCodes::CONFIG, status, "ConfigError exits 78"
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "config", payload["error_kind"]
        assert_equal "ConfigError", payload["error_class"]
        assert_equal Hive::ExitCodes::CONFIG, payload["exit_code"]
        assert @schemer.valid?(payload),
               "ConfigError envelope must validate (errors: #{@schemer.validate(payload).map { |e| e['error'] }.inspect})"
      end
    end
  end

  # StandardError → wrapped to InternalError, kind "internal", exit 70.
  def test_standard_error_wraps_to_internal_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "internal probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        # Force a synthetic RuntimeError mid-run by stubbing pick_runner.
        cmd = Hive::Commands::Run.new(brainstorm_dir, json: true)
        cmd.define_singleton_method(:pick_runner) { |_task| raise RuntimeError, "boom from test" }

        out, _err, status = with_captured_exit { cmd.call }
        assert_equal Hive::ExitCodes::SOFTWARE, status, "InternalError exits SOFTWARE (70)"
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "internal", payload["error_kind"]
        assert_equal "InternalError", payload["error_class"]
        assert_includes payload["message"], "RuntimeError",
                        "wrapped message must preserve the original class for debugging"
      end
    end
  end

  # R3 regression: without --json, error path is unchanged (stderr text + exit code,
  # no JSON on stdout).
  def test_human_path_no_json_unchanged_on_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "human probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)
        File.write(File.join(brainstorm_dir, ".lock"),
                   { "pid" => Process.pid, "slug" => slug, "stage" => "brainstorm" }.to_yaml)

        out, err, status = with_captured_exit { Hive::Commands::Run.new(brainstorm_dir, json: false).call }
        assert_equal Hive::ExitCodes::TEMPFAIL, status
        assert_empty out.strip, "no --json must mean no JSON on stdout"
        assert_includes err, "hive:", "stderr human message must still fire"
        refute(begin
          !!JSON.parse(out)
        rescue StandardError
          false
        end, "stdout must not be parseable as JSON without --json")
      end
    end
  end
end
