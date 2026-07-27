require "test_helper"
require "fileutils"
require "json"
require "open3"
require "stringio"
require_relative "../../packaging/release_candidate/cli"

class ReleaseCandidateCliTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__).freeze
  SHA = Open3.capture2("git", "-C", ROOT, "rev-parse", "HEAD").first.strip.freeze

  def setup
    @old_runs_root = ENV["HIVE_RELEASE_CANDIDATES_ROOT"]
    @runs_root = File.join(
      ROOT, "tmp", "release-candidates",
      "cli-test-#{Process.pid}-#{object_id}"
    )
    ENV["HIVE_RELEASE_CANDIDATES_ROOT"] = @runs_root
  end

  def teardown
    FileUtils.rm_rf(@runs_root)
    if @old_runs_root
      ENV["HIVE_RELEASE_CANDIDATES_ROOT"] = @old_runs_root
    else
      ENV.delete("HIVE_RELEASE_CANDIDATES_ROOT")
    end
  end

  def test_no_verb_defaults_to_read_only_plan_with_committed_input_blocks
    before = tree_snapshot(@runs_root)

    code, out, err = call_cli("--json")
    result = JSON.parse(out)

    assert_equal 0, code
    assert_empty err
    assert_equal "hive-release-candidate-plan", result.fetch("schema")
    assert_equal SHA, result.fetch("candidate_sha")
    assert_equal "0.6.9", result.fetch("candidate_version")
    assert_equal "qa_blocked", result.fetch("qa_status")
    assert_includes result.fetch("blockers"), "remote_validation_required"
    if result["baseline_version"]
      assert_includes result.fetch("blockers"), "candidate_not_newer"
    else
      assert_includes result.fetch("blockers"), "baseline_catalog_missing_or_invalid"
    end
    assert_empty result.fetch("release_actions")
    refute_includes out, "release create"
    refute_includes out, "git tag"
    assert_equal before, tree_snapshot(@runs_root), "plan must not create candidate state"
  end

  def test_human_plan_is_derived_from_the_same_result_fields
    json_code, json_out, = call_cli("plan", "--sha", SHA, "--json")
    human_code, human_out, human_err = call_cli("plan", "--sha", SHA)
    result = JSON.parse(json_out)

    assert_equal 0, json_code
    assert_equal 0, human_code
    assert_empty human_err
    assert_includes human_out, result.fetch("candidate_sha")
    assert_includes human_out, result.fetch("candidate_version")
    assert_includes human_out, result.fetch("qa_status")
    result.fetch("blockers").each { |blocker| assert_includes human_out, blocker }
  end

  def test_help_succeeds_and_json_usage_errors_remain_one_json_document
    code, out, err = call_cli("--help")
    assert_equal 0, code
    assert_includes out, "Usage:"
    assert_empty err

    code, out, err = call_cli("run", "--json", "--sha")
    error = JSON.parse(out)
    assert_equal 64, code
    assert_empty err
    assert_equal "hive-release-candidate-error", error.fetch("schema")
    assert_equal "usage", error.fetch("error_kind")
    assert_equal 64, error.fetch("exit_code")
  end

  def test_local_verbs_reject_remote_or_irrelevant_options
    [
      [ "plan", "--workflow-run", "42" ],
      [ "list", "--sha", SHA, "--gate", "artifact_integrity" ],
      [ "inspect", "--sha", SHA, "--attempt", "current", "--wait" ],
      [ "resume", "--sha", SHA, "--attempt", "current", "--missing" ]
    ].each do |argv|
      code, out, err = call_cli(*argv, "--json")
      error = JSON.parse(out)

      assert_equal 64, code, argv.join(" ")
      assert_empty err
      assert_equal "usage", error.fetch("error_kind")
    end
  end

  def test_rerun_requires_exactly_one_selector_mode
    code, out, err = call_cli(
      "rerun", "--sha", SHA, "--attempt", "20260727T120000Z-aaaaaaaaaaaa",
      "--failed", "--missing", "--json"
    )

    assert_equal 64, code
    assert_empty err
    assert_includes JSON.parse(out).fetch("message"), "exactly one"
  end

  def test_dispatch_and_collect_route_only_explicit_remote_verbs
    fake = Object.new
    calls = []
    fake.define_singleton_method(:dispatch) do |**options|
      calls << [ :dispatch, options ]
      {
        "schema" => "hive-release-candidate-dispatch",
        "status" => "dispatched_unresolved",
        "remote_write_performed" => true,
        "release_action_performed" => false
      }
    end
    fake.define_singleton_method(:collect) do |**options|
      calls << [ :collect, options ]
      {
        "schema" => "hive-release-candidate-collect",
        "status" => "queued",
        "remote_write_performed" => false,
        "release_action_performed" => false
      }
    end

    code, out, err = call_cli("dispatch", "--sha", SHA, "--json", runner: fake)
    assert_equal 0, code
    assert_empty err
    assert_equal "dispatched_unresolved", JSON.parse(out).fetch("status")
    assert_equal [ :dispatch, { ref: SHA } ], calls.shift

    code, out, err = call_cli("collect", "--workflow-run", "42", "--attempt", "2",
                              "--json", runner: fake)
    assert_equal 0, code
    assert_empty err
    assert_equal "queued", JSON.parse(out).fetch("status")
    assert_equal [
      :collect,
      { workflow_run: "42", request: nil, attempt: "2", wait: false, timeout: nil }
    ], calls.shift
  end

  def test_list_is_observational_and_missing_inspect_is_unavailable
    code, out, err = call_cli("list", "--sha", SHA, "--json")
    assert_equal 0, code
    assert_empty err
    assert_equal [], JSON.parse(out).fetch("attempts")

    code, out, err = call_cli("inspect", "--sha", SHA, "--attempt", "current", "--json")
    error = JSON.parse(out)
    assert_equal 69, code
    assert_empty err
    assert_equal "unavailable", error.fetch("error_kind")
  end

  private

  def call_cli(*argv, runner: nil)
    out = StringIO.new
    err = StringIO.new
    code = HiveReleaseCandidate::CLI.new(
      argv: argv,
      repo_root: ROOT,
      stdout: out,
      stderr: err,
      runner: runner
    ).call
    [ code, out.string, err.string ]
  end

  def tree_snapshot(root)
    return [] unless File.exist?(root) || File.symlink?(root)

    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      [ path.delete_prefix("#{root}/"), File.lstat(path).ftype, File.lstat(path).size ]
    end
  end
end
