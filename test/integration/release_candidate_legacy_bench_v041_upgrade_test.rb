require_relative "release_candidate_latest_stable_upgrade_test"

class ReleaseCandidateLegacyBenchV041UpgradeTest < ReleaseCandidateLatestStableUpgradeTest
  def test_requires_real_v041_producer_v042_observer_and_preserves_legacy_task
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", "0.4.1",
          "596f8e9018a2a7d419ca1758344ed64b617d1edb5679a25e8d86684ecb15ee36"
        ),
        "observer" => target(
          dir, "observer", "0.4.2",
          "df7e1599621db2fe4710dcd676d11be6b7f0a8a050fcda3b28030e943143a356"
        ),
        "candidate" => target(dir, "candidate", "0.6.9", "6" * 64)
      }
      phases = []
      before = legacy_state
      after = Marshal.load(Marshal.dump(before))
      after["legacy_descriptor"] = { "status" => "archived", "path" => "bench.legacy.yml.disabled" }
      after["legacy_instructions"] = { "status" => "archived", "path" => "bench.legacy" }
      after["builtin_runtime"] = { "status" => "installed" }
      after["install_identity"]["gem_sha256"] = "6" * 64
      executor = lambda do |target:, phase:, **|
        phases << [ target.role, phase ]
        snapshot = phase == "before" || phase == "observer" ? before : after
        {
          "status" => phase == "observer" ? "expected_failure_observed" : "passed",
          "reason" => phase == "observer" ? "legacy_workflow_collision" : nil,
          "observation" => phase == "observer" ? {
            "outcome" => "expected_failure",
            "code" => "workflow_id_collision:bench"
          } : nil,
          "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => Marshal.load(Marshal.dump(snapshot)),
          "stdout" => phase.to_s, "stderr" => "", "processes" => [], "services" => [],
          "task_continuation" => phase == "after"
        }
      end
      channel = lambda do |**|
        {
          "status" => "passed", "channel" => "linux-bash",
          "candidate_gem_sha256" => "6" * 64, "stale_files" => [],
          "wrapper_role" => "candidate", "sidecars_current" => true,
          "dependencies_current" => true
        }
      end

      result = runner(dir, targets, executor, channel).run(
        row_id: "legacy-bench-v041", platform: "linux-x86_64"
      )

      assert_equal "passed", result.fetch("status")
      assert_equal(
        [
          %w[baseline before],
          %w[observer observer],
          %w[candidate candidate_transition],
          %w[candidate after],
          %w[candidate idempotency]
        ],
        phases
      )
      assert_equal "legacy_workflow_collision", result.dig("phases", 1, "reason")
      assert result.dig("phases", 3, "task_continuation")
    end
  end

  def test_observer_is_required_and_incompatibility_is_not_skipped
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", "0.4.1",
          "596f8e9018a2a7d419ca1758344ed64b617d1edb5679a25e8d86684ecb15ee36"
        ),
        "candidate" => target(dir, "candidate", "0.6.9", "6" * 64)
      }
      executor = ->(**) { raise "must not start without observer" }

      result = runner(dir, targets, executor, ->(**) { {} }).run(
        row_id: "legacy-bench-v041", platform: "linux-x86_64"
      )

      assert_equal "unavailable", result.fetch("status")
      assert_equal "required_observer_target_unavailable", result.fetch("reason")
      refute_equal "skipped", result.fetch("status")
    end
  end

  private

  def legacy_state
    latest_state.merge(
      "default_workflow" => "bench",
      "tasks" => {
        "task-7" => {
          "id" => 7, "slug" => "legacy-campaign-260714-abcd",
          "stage" => "3-generate", "contents" => "legacy body"
        }
      },
      "legacy_descriptor" => {
        "status" => "active", "path" => "workflows/bench.yml",
        "sha256" => "7" * 64
      },
      "legacy_instructions" => {
        "status" => "active", "path" => "workflows/bench",
        "sha256" => "8" * 64
      },
      "builtin_runtime" => { "status" => "absent" },
      "install_identity" => { "gem_sha256" => "4" * 64 }
    )
  end
end
