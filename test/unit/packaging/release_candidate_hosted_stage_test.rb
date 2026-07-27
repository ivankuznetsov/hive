require "test_helper"
require "json"
require_relative "../../../packaging/release_candidate/hosted_stage"
require_relative "../../../packaging/release_candidate/hosted_upgrade_lane"

class ReleaseCandidateHostedStageTest < Minitest::Test
  include HiveTestHelper
  ROOT = File.expand_path("../../..", __dir__)
  SHA = "a" * 40

  def test_fetch_and_install_split_keeps_target_install_after_staged_inputs
    with_tmp_dir do |dir|
      run_root = File.join(dir, "run")
      cache_root = File.join(dir, "cache")
      FileUtils.mkdir_p(File.join(run_root, "candidate"))
      File.write(File.join(run_root, "candidate", "manifest.json"), JSON.generate(
        "candidate_sha" => SHA, "hive_version" => "0.7.0", "files" => {}
      ))
      stage = HiveReleaseCandidate::HostedStage.new(
        repo_root: ROOT, cache_root: cache_root, run_root: run_root
      )
      installs = 0
      stage.define_singleton_method(:stage_packages) do |_row|
        [ { "role" => "baseline", "sha256" => "b" * 64 } ]
      end
      stage.define_singleton_method(:stage_dependency_closures) do |_row|
        { "baseline" => { "role" => "baseline", "sha256" => "c" * 64 } }
      end
      stage.define_singleton_method(:stage_candidate_closure) do
        { "role" => "candidate", "sha256" => "d" * 64 }
      end
      stage.define_singleton_method(:stage_targets) do |_row, _manifest, closures|
        installs += 1
        raise "candidate closure missing" unless closures.key?("candidate")
      end

      fetched = stage.fetch(
        row_id: "latest-stable", platform: "linux-x86_64", candidate_sha: SHA
      )
      assert_equal "inputs_staged", fetched.fetch("status")
      assert_equal 0, installs
      assert File.file?(File.join(run_root, "staged-inputs.json"))

      installed = stage.install(
        row_id: "latest-stable", platform: "linux-x86_64", candidate_sha: SHA
      )
      assert_equal "staged", installed.fetch("status")
      assert_equal 1, installs
      assert File.file?(File.join(run_root, "sandbox-attestation.json"))
      assert File.file?(File.join(run_root, "baseline-cache-attestation.json"))
    end
  end

  def test_candidate_closure_fetches_the_exact_bundler_runtime_dependency
    with_tmp_dir do |dir|
      gems_root = File.join(dir, "gems")
      FileUtils.mkdir_p(gems_root)
      stage = HiveReleaseCandidate::HostedStage.new(
        repo_root: ROOT, cache_root: File.join(dir, "cache"),
        run_root: File.join(dir, "run")
      )
      artifacts = stage.instance_variable_get(:@catalog).runtime_closure_artifacts(
        "candidate" => File.binread(File.join(ROOT, "Gemfile.lock"))
      )
      fetches = []
      stage.define_singleton_method(:run!) do |*argv, chdir: nil|
        fetches << argv
        name = argv.fetch(2)
        version = argv.fetch(4)
        platform_index = argv.index("--platform")
        platform = platform_index ? argv.fetch(platform_index + 1) : ""
        artifact = artifacts.find do |row|
          row["name"] == name && row["version"] == version &&
            row["platform"] == platform
        end
        File.write(File.join(chdir, artifact.fetch("filename")), "fixture")
      end

      paths = stage.send(
        :fetch_locked_gems, File.join(ROOT, "Gemfile.lock"), gems_root
      )

      assert_includes fetches,
                      %w[gem fetch bundler --version 2.7.2 --platform ruby]
      assert_includes paths, File.join(gems_root, "bundler-2.7.2.gem")
    end
  end

  def test_hosted_upgrade_entrypoint_maps_terminal_statuses_to_process_codes
    lane = HiveReleaseCandidate::HostedUpgradeLane

    assert_equal 0, lane.exit_code_for("status" => "passed")
    assert_equal 1, lane.exit_code_for("status" => "failed")
    assert_equal 69, lane.exit_code_for("status" => "unavailable")
    assert_equal 1, lane.exit_code_for("status" => "unexpected")
  end
end
