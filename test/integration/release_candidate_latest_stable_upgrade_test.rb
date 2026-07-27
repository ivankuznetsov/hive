require "test_helper"
require "digest"
require "json"
require_relative "../../packaging/release_candidate/baseline_catalog"
require_relative "../../packaging/release_candidate/installed_target"
require_relative "../../packaging/release_candidate/upgrade_survivor"

class ReleaseCandidateLatestStableUpgradeTest < Minitest::Test
  include HiveTestHelper
  ROOT = File.expand_path("../..", __dir__).freeze
  CATALOG = File.join(ROOT, "packaging/release_candidate/baselines.yml").freeze

  def test_runs_latest_stable_named_phases_and_channel_oracle
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", "0.6.9",
          "9e9d065f67ccf3381b263f9a5ca44afb79b3122309b1b87c2477ddb6b2fba7a1"
        ),
        "candidate" => target(dir, "candidate", "0.6.9", "b" * 64)
      }
      phases = []
      state = latest_state
      executor = lambda do |target:, phase:, **|
        phases << [ target.role, phase ]
        snapshot = Marshal.load(Marshal.dump(state))
        snapshot["install_identity"]["gem_sha256"] = "b" * 64 unless phase == "before"
        {
          "status" => "passed", "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot, "stdout" => "#{phase}\n", "stderr" => "",
          "processes" => [], "services" => []
        }
      end
      channel = lambda do |**|
        {
          "status" => "passed", "channel" => "linux-bash",
          "candidate_gem_sha256" => "b" * 64, "stale_files" => [],
          "wrapper_role" => "candidate", "sidecars_current" => true,
          "dependencies_current" => true
        }
      end

      result = runner(dir, targets, executor, channel).run(
        row_id: "latest-stable", platform: "linux-x86_64"
      )

      assert_equal "passed", result.fetch("status")
      assert_equal(
        [
          %w[baseline before],
          %w[candidate candidate_transition],
          %w[candidate after],
          %w[candidate idempotency]
        ],
        phases
      )
      assert_equal "qa_blocked", result.fetch("qa_status")
      assert_includes result.fetch("blockers"), "remote_validation_required"
      assert_equal "passed", result.dig("channel", "status")
      assert_equal "passed", result.dig("teardown", "status")
    end
  end

  def test_rejects_task_change_non_idempotency_stale_channel_and_fixture_substitution
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", "0.6.9",
          "9e9d065f67ccf3381b263f9a5ca44afb79b3122309b1b87c2477ddb6b2fba7a1"
        ),
        "candidate" => target(dir, "candidate", "0.6.9", "b" * 64)
      }
      state = latest_state
      executor = lambda do |target:, phase:, **|
        snapshot = Marshal.load(Marshal.dump(state))
        snapshot["install_identity"]["gem_sha256"] = "b" * 64 unless phase == "before"
        snapshot["tasks"]["task-7"]["contents"] = "lost" if phase == "after"
        snapshot["configuration"]["second_run"] = true if phase == "idempotency"
        {
          "status" => "passed",
          "producer_kind" => phase == "before" ? "fixture" : "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot, "stdout" => "", "stderr" => "",
          "processes" => [], "services" => []
        }
      end
      channel = ->(**) { { "status" => "failed", "reason" => "stale_channel_files" } }

      result = runner(dir, targets, executor, channel).run(
        row_id: "latest-stable", platform: "linux-x86_64"
      )

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("reasons"), "fixture_cannot_substitute_for_real_producer"
      assert_includes result.fetch("reasons"), "invariant_mismatch"
      assert_includes result.fetch("reasons"), "second_run_not_idempotent"
      assert_includes result.fetch("reasons"), "stale_channel_files"
    end
  end

  def test_unavailable_cache_or_sandbox_never_begins_the_producer
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", "0.6.9",
          "9e9d065f67ccf3381b263f9a5ca44afb79b3122309b1b87c2477ddb6b2fba7a1"
        ),
        "candidate" => target(dir, "candidate", "0.6.9", "b" * 64)
      }
      calls = 0
      executor = ->(**) { calls += 1 }
      unavailable = HiveReleaseCandidate::UpgradeSurvivor.new(
        catalog: HiveReleaseCandidate::BaselineCatalog.load(CATALOG),
        targets: targets, run_root: File.join(dir, "run"),
        sandbox_contract: {
          "status" => "unavailable", "reason" => "no_engine"
        },
        cache_contract: {
          "status" => "missing", "release_assets_sha256" => nil,
          "verified_dependency_closure_sha256" => nil
        },
        candidate_manifest: {
          "candidate_sha" => "a" * 40,
          "hive_version" => "0.6.9",
          "files" => {
            "hive-cli-0.6.9.gem" => {
              "kind" => "gem", "sha256" => "b" * 64
            }
          }
        },
        phase_executor: executor, channel_executor: ->(**) { calls += 1 }
      ).run(row_id: "latest-stable", platform: "linux-x86_64")

      assert_equal "unavailable", unavailable.fetch("status")
      assert_equal "disposable_sandbox_unavailable", unavailable.fetch("reason")
      assert_equal 0, calls
      assert_equal(
        [ "bin/hive-release-candidate", "dispatch", "--sha", "a" * 40 ],
        unavailable.fetch("next_action_argv")
      )
    end
  end

  def test_channel_prefix_oracle_rejects_digest_and_stale_file_substitution
    with_tmp_dir do |dir|
      candidate = target(dir, "candidate", "0.6.9", "b" * 64)
      prefix = File.join(dir, "prefix")
      FileUtils.mkdir_p(File.join(prefix, "bin"))
      File.write(File.join(prefix, "bin/hive"), "candidate wrapper\n")
      files = {
        "bin/hive" => {
          "size" => File.size(File.join(prefix, "bin/hive")),
          "sha256" => Digest::SHA256.file(File.join(prefix, "bin/hive")).hexdigest
        }
      }
      manifest = {
        "platform" => "linux-x86_64", "channel" => "linux-bash",
        "candidate_gem_sha256" => "b" * 64, "wrapper_role" => "candidate",
        "sidecars_current" => true, "dependencies_current" => true,
        "stale_files" => [], "files" => files
      }
      File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
      oracle = HiveReleaseCandidate::ChannelPrefixOracle.new

      assert_equal "passed", oracle.verify(
        prefix: prefix, platform: "linux-x86_64", candidate_target: candidate
      ).fetch("status")

      File.write(File.join(prefix, "stale-baseline"), "old")
      error = assert_raises(HiveReleaseCandidate::Error) do
        oracle.verify(prefix: prefix, platform: "linux-x86_64", candidate_target: candidate)
      end
      assert_includes error.message, "stale or substituted"

      FileUtils.rm_f(File.join(prefix, "stale-baseline"))
      manifest["candidate_gem_sha256"] = "f" * 64
      File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
      error = assert_raises(HiveReleaseCandidate::Error) do
        oracle.verify(prefix: prefix, platform: "linux-x86_64", candidate_target: candidate)
      end
      assert_includes error.message, "digest mismatch"
    end
  end

  def test_default_channel_executor_clones_baseline_before_reviewed_update
    with_tmp_dir do |dir|
      baseline = target(dir, "baseline", "0.6.9", "a" * 64)
      candidate = target(dir, "candidate", "0.6.9", "b" * 64)
      File.write(File.join(baseline.root, "baseline-only"), "retire me")
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedChannelExecutor.new(
        targets: { "baseline" => baseline, "candidate" => candidate }
      )
      run_root = File.join(dir, "run")
      FileUtils.mkdir_p(run_root)

      receipt = executor.call(
        row: nil, platform: "linux-x86_64", candidate_target: candidate,
        run_root: run_root
      )

      assert_equal "passed", receipt.fetch("status")
      assert_equal(
        "linux-bash-hive-update",
        receipt.dig("update", "seam")
      )
      assert receipt.fetch("baseline_prefix_files").key?("baseline-only")
      assert_path_exists File.join(receipt.dig("update", "retired_baseline_prefix"), "baseline-only")
      refute_path_exists File.join(run_root, "channel-prefix", "baseline-only")
    end
  end

  private

  def runner(dir, targets, executor, channel)
    HiveReleaseCandidate::UpgradeSurvivor.new(
      catalog: HiveReleaseCandidate::BaselineCatalog.load(CATALOG),
      targets: targets, run_root: File.join(dir, "run"),
      sandbox_contract: {
        "status" => "available", "kind" => "container",
        "network_after_staging" => "none"
      },
      cache_contract: {
        "status" => "available", "release_assets_sha256" => "d" * 64,
        "verified_dependency_closure_sha256" => "e" * 64
      },
      candidate_manifest: {
        "candidate_sha" => "a" * 40,
        "hive_version" => targets.fetch("candidate").manifest.fetch("version"),
        "files" => {
          "hive-cli-0.6.9.gem" => {
            "kind" => "gem",
            "sha256" => targets.fetch("candidate").manifest.fetch("gem_sha256")
          }
        }
      },
      phase_executor: executor, channel_executor: channel
    )
  end

  def target(dir, role, version, digest)
    root = File.join(dir, role)
    FileUtils.mkdir_p(File.join(root, "bin"))
    body = if role == "candidate"
             <<~BASH
               #!/usr/bin/env bash
               set -euo pipefail
               if [[ "${1:-}" == "update" ]]; then
                 exec "${HIVE_RC_CONTROL_ROOT:?}/channel_update_fixture.sh" \
                   "--prefix=${HIVE_RC_CHANNEL_PREFIX:?}"
               fi
               exit 0
             BASH
           else
             "#!/bin/sh\nexit 0\n"
           end
    File.write(File.join(root, "bin/hive"), body)
    File.chmod(0o755, File.join(root, "bin/hive"))
    File.write(File.join(root, "target.json"), JSON.generate(
      "schema" => "hive-release-candidate-installed-target",
      "schema_version" => 1, "role" => role, "version" => version,
      "gem_sha256" => digest, "executable" => "bin/hive",
      "skills" => { "archive_sha256" => "c" * 64, "import_root" => "skills" }
    ))
    HiveReleaseCandidate::InstalledTarget.new(
      role: role, root: root, state_root: File.join(dir, "state")
    )
  end

  def latest_state
    {
      "global_registry" => { "projects" => [ "project" ] },
      "project_registry" => { "path" => "/run/project" },
      "configuration" => { "daemon" => false },
      "default_workflow" => "coding",
      "tasks" => {
        "task-7" => {
          "id" => 7, "slug" => "representative-260727-abcd",
          "stage" => "4-execute", "contents" => "keep"
        }
      },
      "dependencies" => { "task-7" => [] },
      "markers" => { "task-7" => "WAITING" },
      "durable_attempts" => { "attempt-1" => "terminal" },
      "dispatch_receipts" => { "attempt-1" => "accepted" },
      "channel_sidecars" => { "channel" => "linux-bash" },
      "managed_web_data" => { "database" => "keep" },
      "service_definitions" => { "hive-web" => "inert" },
      "status_json" => { "schema" => "hive-status", "tasks" => 1 },
      "doctor_json" => { "schema" => "hive-doctor", "healthy" => true },
      "install_identity" => { "gem_sha256" => "a" * 64 }
    }
  end
end
