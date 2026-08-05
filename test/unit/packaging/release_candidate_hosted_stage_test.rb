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

  def test_install_rebinds_legacy_closure_roots_to_the_consumer_cache_namespace
    with_tmp_dir do |dir|
      run_root = File.join(dir, "run")
      source_cache = File.join(dir, "runner-cache")
      consumer_cache = File.join(dir, "container-cache")
      dependency_fixture = File.join(
        ROOT, "test/e2e/sample-project/vendor/cache/rake-13.4.2.gem"
      )
      dependency = {
        "filename" => File.basename(dependency_fixture),
        "size" => File.size(dependency_fixture),
        "sha256" => Digest::SHA256.file(dependency_fixture).hexdigest
      }
      row_root = File.join(consumer_cache, "closures", "legacy-bench-v041", "gems")
      candidate_root = File.join(consumer_cache, "closures", "candidate", "gems")
      [ row_root, candidate_root ].each do |root|
        FileUtils.mkdir_p(root)
        FileUtils.cp(dependency_fixture, File.join(root, dependency.fetch("filename")))
      end
      staged_path = write_staged_inputs(
        run_root,
        row_id: "legacy-bench-v041",
        closures: {
          "baseline" => closure(
            "baseline", File.join(source_cache, "closures/legacy-bench-v041/gems"), dependency
          ),
          "observer" => closure(
            "observer", File.join(source_cache, "closures/legacy-bench-v041/gems"), dependency
          ),
          "candidate" => closure(
            "candidate", File.join(source_cache, "closures/candidate/gems"), dependency
          )
        }
      )
      staged_bytes = File.binread(staged_path)
      installed_closures = nil
      installed_dependencies = nil
      stage = HiveReleaseCandidate::HostedStage.new(
        repo_root: ROOT, cache_root: consumer_cache, run_root: run_root
      )
      stage.define_singleton_method(:stage_targets) do |_row, _manifest, closures|
        installed_closures = closures
        installed_dependencies = closures.transform_values do |closure|
          installable_dependencies(closure)
        end
      end

      stage.install(
        row_id: "legacy-bench-v041", platform: "linux-x86_64", candidate_sha: SHA
      )

      assert_equal row_root, installed_closures.dig("baseline", "root")
      assert_equal row_root, installed_closures.dig("observer", "root")
      assert_equal candidate_root, installed_closures.dig("candidate", "root")
      assert_equal [ File.join(row_root, dependency.fetch("filename")) ],
                   installed_dependencies.fetch("baseline")
      assert_equal [ File.join(row_root, dependency.fetch("filename")) ],
                   installed_dependencies.fetch("observer")
      assert_equal [ File.join(candidate_root, dependency.fetch("filename")) ],
                   installed_dependencies.fetch("candidate")
      assert_equal staged_bytes, File.binread(staged_path)
    end
  end

  def test_install_rejects_an_unexpected_staged_closure_role
    with_tmp_dir do |dir|
      run_root = File.join(dir, "run")
      write_staged_inputs(
        run_root,
        closures: {
          "baseline" => closure("baseline", "/staged/closures/latest-stable/gems"),
          "candidate" => closure("candidate", "/staged/closures/candidate/gems"),
          "observer" => closure("observer", "/staged/closures/latest-stable/gems")
        }
      )
      stage = HiveReleaseCandidate::HostedStage.new(
        repo_root: ROOT, cache_root: File.join(dir, "cache"), run_root: run_root
      )

      error = assert_raises(HiveReleaseCandidate::Error) do
        stage.install(row_id: "latest-stable", platform: "linux-x86_64", candidate_sha: SHA)
      end
      assert_includes error.message, "closure role set mismatch"
    end
  end

  def test_install_rejects_a_staged_closure_role_identity_mismatch
    with_tmp_dir do |dir|
      run_root = File.join(dir, "run")
      write_staged_inputs(
        run_root,
        closures: {
          "baseline" => closure("observer", "/staged/closures/latest-stable/gems"),
          "candidate" => closure("candidate", "/staged/closures/candidate/gems")
        }
      )
      stage = HiveReleaseCandidate::HostedStage.new(
        repo_root: ROOT, cache_root: File.join(dir, "cache"), run_root: run_root
      )

      error = assert_raises(HiveReleaseCandidate::Error) do
        stage.install(row_id: "latest-stable", platform: "linux-x86_64", candidate_sha: SHA)
      end
      assert_includes error.message, "closure identity mismatch"
    end
  end

  def test_hosted_upgrade_entrypoint_maps_terminal_statuses_to_process_codes
    lane = HiveReleaseCandidate::HostedUpgradeLane

    assert_equal 0, lane.exit_code_for("status" => "passed")
    assert_equal 1, lane.exit_code_for("status" => "failed")
    assert_equal 69, lane.exit_code_for("status" => "unavailable")
    assert_equal 1, lane.exit_code_for("status" => "unexpected")
  end

  private

  def closure(role, root, dependency = nil)
    value = { "role" => role, "root" => root, "sha256" => role[0] * 64 }
    value["gems"] = [ dependency ] if dependency
    value
  end

  def write_staged_inputs(run_root, row_id: "latest-stable", platform: "linux-x86_64",
                          closures:)
    candidate_manifest = {
      "candidate_sha" => SHA, "hive_version" => "0.7.0", "files" => {}
    }
    candidate_root = File.join(run_root, "candidate")
    FileUtils.mkdir_p(candidate_root)
    File.write(File.join(candidate_root, "manifest.json"), JSON.generate(candidate_manifest))
    path = File.join(run_root, "staged-inputs.json")
    File.write(path, JSON.pretty_generate(
      "row_id" => row_id,
      "platform" => platform,
      "candidate_sha" => SHA,
      "candidate_manifest_sha256" => Digest::SHA256.hexdigest(JSON.generate(candidate_manifest)),
      "release_assets" => [ { "role" => "baseline", "sha256" => "a" * 64 } ],
      "closures" => closures
    ))
    path
  end
end
