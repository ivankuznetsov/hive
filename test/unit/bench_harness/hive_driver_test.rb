# frozen_string_literal: true

require "support/bench_harness"
require "tmpdir"
require "fileutils"
require "open3"
require "sqlite3"
require "lib/hive_driver"
require "profiles/candidates"

# Real git for the repo setup/seeding; the container run is the injected seam.
class BenchHarnessHiveDriverTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hb-hivedriver")
    @source = File.join(@root, "source")
    @base = build_source_repo
    @out = File.join(@root, "out")
    @work = File.expand_path(File.join(@out, "target"))
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def sh!(*, chdir:)
    _o, e, s = Open3.capture3(*, chdir: chdir)
    raise "git failed: #{e}" unless s.success?
  end

  def build_source_repo
    FileUtils.mkdir_p(@source)
    sh!("git", "init", "-q", "-b", "main", chdir: @source)
    sh!("git", "config", "user.email", "t@e.c", chdir: @source)
    sh!("git", "config", "user.name", "T", chdir: @source)
    File.write(File.join(@source, "app.rb"), "def greet = 'v1'\n")
    sh!("git", "add", ".", chdir: @source)
    sh!("git", "commit", "-qm", "base", chdir: @source)
    Open3.capture2("git", "rev-parse", "HEAD", chdir: @source).first.strip
  end

  def entry
    dir = File.join(@root, "entry")
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "idea.md"), "idea\n")
    File.write(File.join(dir, "spec", "brainstorm.md"), "brainstorm\n")
    { "task_id" => "add-i-key", "entry_dir" => dir, "checkout_source" => @source,
      "source" => { "base_commit" => @base, "repo" => "ivankuznetsov/hive", "reference_pr" => 123 },
      "spec" => { "idea" => "spec/idea.md", "brainstorm" => "spec/brainstorm.md" } }
  end

  def candidate = HiveBench::Candidates.by_id("all-opus-4.8")

  def fake_hive_runtime(build_sha: nil)
    { root: @source, gem_home: @root, version: "0.7.2", build_sha: }.compact
  end

  def hive_driver(hive_runtime: fake_hive_runtime, **kwargs)
    HiveBench::HiveDriver.new(hive_runtime:, **kwargs).tap do |instance|
      instance.define_singleton_method(:auth_mounts) { |*_args| [] }
    end
  end

  OK_STDOUT = "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_DONE\nHB_EXIT rc=0\n"

  def driver(stdout: OK_STDOUT, patch: "diff --git a/app.rb b/app.rb\n", log_lines: [], **options)
    seen = @seen_cmd = []
    work = @work
    runner = lambda do |cmd|
      seen.concat(cmd)
      File.write(File.join(work, "candidate.patch"), patch) if patch
      # .hb always contains DIRECTORIES too (bin/ for the gh shim, origin.git/)
      # — the answer-key scan must skip them (regression: EISDIR).
      FileUtils.mkdir_p(File.join(work, ".hb", "bin"))
      unless log_lines.empty?
        dir = File.join(work, ".hive-state", "logs", "add-i-key")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "execute-1.log"), log_lines.join("\n"))
      end
      stdout
    end
    hive_driver(
      runner: runner, reuse_existing: false, reuse_unverified: false, **options
    )
  end

  def test_generated_cell_with_api_equivalent_cost
    usage = '[stream] 2026-01-01T00:00:00Z {"message":{"usage":{"input_tokens":1000,' \
            '"output_tokens":2000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":500}}}'
    reported = '[stream] 2026-01-01T00:00:01Z {"type":"result","total_cost_usd":9.99}'
    cell = driver(log_lines: [usage, reported]).call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "generated", cell.status
    assert_equal 1000, cell.telemetry["input_tokens"]
    # tokens x usual-tier anthropic rates, NOT the CLI's self-reported figure;
    # cache WRITES count as input-rate tokens (dropping them undercosts claude).
    expected = (((1000 + 500) * 5) + (2000 * 25) + (1_000_000 * 0.5)) / 1_000_000.0

    assert_in_delta expected, cell.telemetry["cost_usd"], 0.0001
    assert_in_delta 9.99, cell.telemetry["cost_usd_reported"], 0.001
  end

  def test_completed_artifact_is_recovered_without_rerunning_hive
    original = driver.call(entry: entry, candidate: candidate, out_dir: @out)
    FileUtils.mkdir_p(File.join(@work, ".hb"))
    File.write(File.join(@work, ".hb", "stages.out"), OK_STDOUT)
    no_rerun = hive_driver(runner: ->(_cmd) { flunk "completed artifact must not be regenerated" },
                            reuse_existing: true, reuse_unverified: false)

    cell = no_rerun.call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "generated", cell.status
    assert_equal original.generation_id, cell.generation_id
    assert cell.telemetry["recovered_artifact"]
    assert_equal "verified", cell.telemetry["artifact_provenance"]
    assert_equal 0.0, cell.telemetry["wall_clock_sec"], "persisted measured wall time survives recovery"
  end

  def test_legacy_artifact_requires_explicit_unverified_recovery
    driver.call(entry: entry, candidate: candidate, out_dir: @out)
    FileUtils.mkdir_p(File.join(@work, ".hb"))
    File.write(File.join(@work, ".hb", "stages.out"), OK_STDOUT)
    FileUtils.rm_f(File.join(@out, "generation-attempt.json"))
    FileUtils.rm_f(File.join(@work, ".hb", HiveBench::HiveDriver::GENERATION_IDENTITY))
    no_rerun = hive_driver(runner: ->(_cmd) { flunk "explicit legacy recovery must reuse the artifact" },
                            reuse_existing: true, reuse_unverified: true)

    cell = no_rerun.call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "generated", cell.status
    assert_equal "legacy-unverified", cell.telemetry["artifact_provenance"]
    assert_nil cell.generation_id
  end

  def test_unfinalized_attempt_recovers_and_promotes_artifacts_under_retained_identity
    original = driver.call(entry: entry, candidate: candidate, out_dir: @out)
    manifest = HiveBench::GenerationProvenance.load(@out)
    manifest.delete("artifact_binding")
    manifest["state"] = "started"
    HiveBench::GenerationProvenance.persist(@out, manifest)
    File.write(File.join(@work, "candidate-execute.patch"), "recovered patch")
    FileUtils.rm_f(File.join(@work, "candidate.patch"))
    File.write(File.join(@work, ".hb", "stages.out"),
               "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_EXIT rc=124\n")
    cell = hive_driver(runner: ->(*) { flunk "recovery must not regenerate" }, reuse_existing: true, reuse_unverified: false)
           .call(entry: entry, candidate: candidate, out_dir: @out)
    assert_equal original.generation_id, cell.generation_id
    assert_equal HiveBench::GenerationProvenance.digest("recovered patch"), cell.artifact_binding.fetch("patch_sha256")
    assert_equal "recovery-finalized", HiveBench::GenerationProvenance.load(@out).fetch("state")
  end

  def test_changed_candidate_identity_refuses_to_destroy_existing_artifact
    driver.call(entry: entry, candidate: candidate, out_dir: @out)
    FileUtils.mkdir_p(File.join(@work, ".hb"))
    File.write(File.join(@work, ".hb", "stages.out"), OK_STDOUT)
    changed = candidate.with(model_version: "changed-model")
    no_rerun = hive_driver(runner: ->(_cmd) { flunk "mismatched artifact must not be deleted" },
                            reuse_existing: true, reuse_unverified: false)

    error = assert_raises(HiveBench::HiveDriver::ArtifactProvenanceMismatch) do
      no_rerun.call(entry: entry, candidate: changed, out_dir: @out)
    end

    assert_match(/--no-reuse-existing-artifacts/, error.message)
    assert_path_exists File.join(@work, "candidate.patch")
  end

  def test_incomplete_artifact_is_not_recovered
    driver.call(entry: entry, candidate: candidate, out_dir: @out)
    FileUtils.mkdir_p(File.join(@work, ".hb"))
    File.write(File.join(@work, ".hb", "stages.out"), "HB_STAGE plan rc=0\nHB_EXIT rc=1\n")
    reran = false
    fresh = hive_driver(runner: lambda do |_cmd|
      reran = true
      File.write(File.join(@work, "candidate.patch"), "diff --git a/app.rb b/app.rb\n")
      OK_STDOUT
    end, reuse_existing: true, reuse_unverified: false)

    cell = fresh.call(entry: entry, candidate: candidate, out_dir: @out)

    assert reran
    refute cell.telemetry["recovered_artifact"]
  end

  def test_timeout_after_develop_promotes_execute_patch_for_judging
    execute_patch = "diff --git a/app.rb b/app.rb\n"
    runner = lambda do |_cmd|
      File.write(File.join(@work, "candidate-execute.patch"), execute_patch)
      "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_STAGE open-pr rc=0\nHB_EXIT rc=124\n"
    end
    timed_review = hive_driver(runner:, reuse_existing: false, reuse_unverified: false)

    cell = timed_review.call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "generated", cell.status
    assert_equal execute_patch, File.read(File.join(@work, "candidate.patch"))
    assert cell.telemetry["stage_timed_out"]
    assert_equal "timed_out", cell.telemetry["review_status"]
  end

  def test_timeout_after_develop_is_recovered_without_replacing_target
    driver.call(entry: entry, candidate: candidate, out_dir: @out)
    sentinel = File.join(@work, "resume-sentinel")
    File.write(sentinel, "keep")
    File.write(File.join(@work, "candidate-execute.patch"), "diff --git a/app.rb b/app.rb\n")
    FileUtils.rm_f(File.join(@work, "candidate.patch"))
    File.write(
      File.join(@work, ".hb", "stages.out"),
      "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_STAGE open-pr rc=0\nHB_EXIT rc=124\n"
    )
    no_rerun = hive_driver(
      runner: ->(_cmd) { flunk "timed-out review artifact must not be regenerated" },
      reuse_existing: true, reuse_unverified: false
    )

    cell = no_rerun.call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "generated", cell.status
    assert_path_exists sentinel
    assert cell.telemetry["recovered_artifact"]
    assert_equal "verified", cell.telemetry["artifact_provenance"]
  end

  def test_codex_transport_failure_resumes_identity_verified_execute_in_place
    mixed = HiveBench::Candidates.by_id("opus-plan->codex-exec-xhigh")
    driver.call(entry: entry, candidate: mixed, out_dir: @out)
    sentinel = File.join(@work, "resume-sentinel")
    File.write(sentinel, "keep")
    task = File.join(@work, ".hive-state", "stages", "4-execute", "add-i-key")
    FileUtils.mkdir_p(task)
    File.write(File.join(task, "task.md"),
               "<!-- ERROR reason=implementer_failed status=error marker_id=abc123 -->\n")
    logs = File.join(@work, ".hive-state", "logs", "add-i-key")
    FileUtils.mkdir_p(logs)
    File.write(File.join(logs, "execute-1.log"),
               "{\"type\":\"turn.failed\",\"error\":{\"message\":\"stream disconnected before completion: " \
               "error sending request for url (https://chatgpt.com/backend-api/codex/responses)\"}}\n")
    File.write(File.join(@work, ".hb", "stages.out"),
               "HB_STAGE plan rc=0\nHB_STAGE develop rc=3\nHB_EXIT rc=0\n")

    seen = nil
    resumed = hive_driver(runner: lambda do |cmd|
      seen = cmd

      assert_path_exists sentinel, "resume must not replace the persisted target"
      File.write(File.join(@work, "candidate.patch"), "diff --git a/app.rb b/app.rb\n")
      "HB_STAGE resume-clear rc=0\nHB_STAGE plan rc=0\nHB_NOTE plan_reused\n" \
        "HB_NOTE execute_resumed\nHB_STAGE develop rc=0\nHB_DONE\nHB_EXIT rc=0\n"
    end, reuse_existing: true, reuse_unverified: false)

    previous_id = HiveBench::GenerationProvenance.load(@out).fetch("generation_id")
    cell = resumed.call(entry: entry, candidate: mixed, out_dir: @out)

    assert_equal "generated", cell.status
    refute_equal previous_id, cell.generation_id
    assert cell.telemetry["execute_resumed"]
    assert_includes seen.each_cons(2).to_a, ["-e", "HB_RESUME_EXECUTE=1"]
    assert_includes seen.each_cons(2).to_a, ["-e", "HB_RESUME_MARKER_ID=abc123"]
  end

  def test_timeout_is_timed_out_not_plan_failed
    cell = driver(stdout: "HB_STAGE plan rc=0\nHB_EXIT rc=124\n", patch: nil)
           .call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "timed_out", cell.status
    assert_match(/HB_HIVE_TIMEOUT/, cell.reason)
  end

  def test_nonzero_stage_runner_exit_rejects_an_existing_patch
    stdout = "HB_STAGE plan rc=0\nHB_STAGE develop rc=0\nHB_NOTE final_patch_failed\nHB_EXIT rc=4\n"
    cell = driver(stdout: stdout, patch: "diff --git a/polluted b/polluted\n")
           .call(entry: entry, candidate: candidate, out_dir: @out)

    assert_equal "execute_failed", cell.status
    assert_match(/trustworthy capture/, cell.reason)
  end

  def test_execute_limit_still_parks_generation_despite_nonzero_runner_exit
    stdout = "HB_STAGE plan rc=3\nHB_STAGE develop rc=4\nHB_EXIT rc=4\n"
    FileUtils.mkdir_p(File.join(@work, ".hb"))
    File.write(File.join(@work, ".hb", "stage.err"), "You've hit your session limit\n")

    status, = hive_driver(reuse_existing: true, reuse_unverified: false)
                                   .send(:classify, stdout, @work, "diff --git a/app.rb b/app.rb\n")

    assert_equal "limit_hit", status
  end


end
