require "test_helper"
require "hive/artifacts/outcome_evidence/rework"

class OutcomeEvidenceReworkTest < Minitest::Test
  include HiveTestHelper

  Rework = Hive::Artifacts::OutcomeEvidence::Rework
  FakeTask = Data.define(:folder, :slug)
  NOW = Time.utc(2026, 8, 30, 3, 15, 0)

  def test_records_two_exact_reworks_idempotently_and_then_stops
    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"),
        project: "demo", clock: -> { NOW }
      )
      first_package = package(generation: "a" * 64, digest: "b" * 64)

      first = rework.record!(
        package: first_package,
        expected_generation: "a" * 64,
        expected_digest: "b" * 64
      )
      assert_equal 1, first.fetch("sequence")
      assert_equal first, rework.record!(
        package: first_package,
        expected_generation: "a" * 64,
        expected_digest: "b" * 64
      )

      second_package = package(generation: "c" * 64, digest: "d" * 64)
      second = rework.record!(
        package: second_package,
        expected_generation: "c" * 64,
        expected_digest: "d" * 64
      )
      assert_equal 2, second.fetch("sequence")
      assert_equal 2, rework.records.length

      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        rework.record!(
          package: package(generation: "e" * 64, digest: "f" * 64),
          expected_generation: "e" * 64,
          expected_digest: "f" * 64
        )
      end
      assert_match(/rework limit/, error.message)
    end
  end

  def test_execution_context_binds_feedback_and_controller_owned_paths
    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      current = package
      receipt = rework.record!(
        package: current,
        expected_generation: current.dig("current", "generation"),
        expected_digest: current.dig("current", "recovery_digest")
      )

      context = rework.execution_context(package: current)

      assert_equal receipt.fetch("generation"), context.dig("feedback", "reviewed_generation")
      assert_equal [ "claim-feature" ], context.dig("feedback", "failed_targets")
      assert_equal "b" * 40, context.dig("feedback", "implementation_head")
      assert_equal(
        [
          "media/capture-manifest.json",
          "outcome-evidence/current.json",
          "outcome-evidence/generations/#{'a' * 64}/attempts/attempt-01.json",
          "outcome-evidence/generations/#{'a' * 64}/implementation.diff",
          "outcome-evidence/generations/#{'a' * 64}/requirement.json",
          "outcome-evidence/generations/#{'a' * 64}/retained/attempt-01/entry-01/original.png",
          "outcome-evidence/generations/#{'a' * 64}/retained/attempt-01/entry-01/review.png",
          "outcome-evidence/reworks/rework-01.json",
          "outcome-evidence/reworks/rework-02.json"
        ],
        context.fetch("protected_paths")
      )

      accepted = Marshal.load(Marshal.dump(current))
      accepted.fetch("current")["status"] = "accepted"
      assert_nil rework.execution_context(package: accepted).fetch("feedback")

      stale = package(generation: "c" * 64, digest: "d" * 64)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        rework.execution_context(package: stale)
      end
    end
  end

  def test_execution_context_protects_empty_future_receipt_slots
    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )

      context = rework.execution_context(package: nil, records: [])

      assert_nil context.fetch("feedback")
      assert_equal(
        [
          "outcome-evidence/reworks/rework-01.json",
          "outcome-evidence/reworks/rework-02.json"
        ],
        context.fetch("protected_paths")
      )
      assert File.directory?(File.join(dir, "outcome-evidence", "reworks"))
    end
  end

  def test_records_the_contract_maximum_feedback_without_wedging_rework
    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      maximum = package
      maximum.fetch("current")["failed_targets"] = Array.new(21) do |index|
        format("claim-%02d", index)
      end
      maximum.fetch("current")["reviewer_reasons"] = Array.new(21) do |index|
        ("A" * 1020) + format("%04d", index)
      end

      receipt = rework.record!(
        package: maximum, expected_generation: "a" * 64,
        expected_digest: "b" * 64
      )
      path = File.join(dir, "outcome-evidence", "reworks", "rework-01.json")

      assert_equal 21, receipt.fetch("failed_targets").length
      assert_equal 21, receipt.fetch("reviewer_reasons").length
      assert_operator File.size(path), :>, 16 * 1024
      assert_operator File.size(path), :<=, Rework::MAX_BYTES
    end
  end

  def test_rejects_stale_observations_and_malformed_or_symlinked_receipts
    with_tmp_dir do |dir|
      task = FakeTask.new(folder: dir, slug: "demo-task")
      rework = Rework.new(task: task, project: "demo")
      current = package

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        rework.record!(
          package: current, expected_generation: "c" * 64,
          expected_digest: current.dig("current", "recovery_digest")
        )
      end

      rework.record!(
        package: current,
        expected_generation: current.dig("current", "generation"),
        expected_digest: current.dig("current", "recovery_digest")
      )
      path = File.join(dir, "outcome-evidence", "reworks", "rework-01.json")
      File.write(path, "{}\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { rework.records }

      FileUtils.rm_f(path)
      outside = File.join(dir, "outside.json")
      File.write(outside, "{}\n")
      File.symlink(outside, path)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { rework.records }
      assert_equal "{}\n", File.read(outside)
    end
  end

  def test_rejects_every_malformed_rework_package_shape
    mutations = [
      ->(value) { value.fetch("current")["status"] = "blocked" },
      ->(value) { value.fetch("requirement")["generation"] = "c" * 64 },
      ->(value) { value.delete("current") },
      ->(value) { value.fetch("current")["failed_targets"] = [] },
      ->(value) { value.fetch("current")["reviewer_reasons"] = [ "" ] },
      lambda do |value|
        reason = value.dig("current", "reviewer_reasons", 0)
        value.fetch("current")["reviewer_reasons"] = [ reason, reason ]
      end
    ]

    mutations.each do |mutate|
      with_tmp_dir do |dir|
        rework = Rework.new(
          task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
        )
        malformed = Marshal.load(Marshal.dump(package))
        mutate.call(malformed)

        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          rework.record!(
            package: malformed, expected_generation: "a" * 64,
            expected_digest: "b" * 64
          )
        end
      end
    end

    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      rework.record!(
        package: package, expected_generation: "a" * 64,
        expected_digest: "b" * 64
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        rework.execution_context(package: {})
      end
    end
  end

  def test_rejects_invalid_receipt_inventory_and_append_only_rewrites
    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      root = File.join(dir, "outcome-evidence", "reworks")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "rework-02.json"), "{}\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { rework.records }
    end

    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      root = File.join(dir, "outcome-evidence", "reworks")
      FileUtils.mkdir_p(File.dirname(root))
      File.write(root, "not a directory\n")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { rework.records }
    end

    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      root = File.join(dir, "outcome-evidence", "reworks")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "unexpected.json"), "{}\n")
      assert_empty rework.records
    end

    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      root = File.join(dir, "outcome-evidence", "reworks")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "rework-01.json"), "{")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { rework.records }
    end

    with_tmp_dir do |dir|
      rework = Rework.new(
        task: FakeTask.new(folder: dir, slug: "demo-task"), project: "demo"
      )
      receipt = rework.record!(
        package: package, expected_generation: "a" * 64,
        expected_digest: "b" * 64
      )
      path = File.join(dir, "outcome-evidence", "reworks", "rework-01.json")
      assert_equal receipt, rework.send(:write_once, path, receipt)
      changed = receipt.merge("recorded_at" => (NOW + 1).iso8601(6))
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        rework.send(:write_once, path, changed)
      end
    end
  end

  private

  def package(generation: "a" * 64, digest: "b" * 64)
    {
      "current" => {
        "status" => "rework", "reason" => "implementation_rework",
        "generation" => generation, "recovery_digest" => digest,
        "failed_targets" => [ "claim-feature" ],
        "reviewer_reasons" => [
          "The implementation must move the attachment rail outside the selected region."
        ],
        "attempts" => [
          { "attempt_id" => "attempt-01", "attempt_sha256" => "e" * 64 }
        ]
      },
      "requirement" => {
        "generation" => generation,
        "implementation" => {
          "implementation_base" => "a" * 40,
          "implementation_head" => "b" * 40
        }
      },
      "attempts" => [
        {
          "attempt_id" => "attempt-01",
          "evidence" => [
            {
              "source" => {
                "type" => "project_provider",
                "manifest_path" => "media/capture-manifest.json"
              },
              "representations" => %w[original review].map do |role|
                {
                  "path" =>
                    "outcome-evidence/generations/#{generation}/retained/" \
                    "attempt-01/entry-01/#{role}.png"
                }
              end
            }
          ]
        }
      ]
    }
  end
end
