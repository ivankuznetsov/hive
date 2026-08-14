require "test_helper"
require "hive/commands/evidence"

class CommandsEvidenceTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Data.define(
    :folder, :slug, :project_root, :project_name, :state_file
  )

  def test_recover_requires_the_exact_blocked_marker_and_advances_one_epoch
    with_tmp_dir do |dir|
      task = fake_task(dir)
      pointer = blocked_package(task)
      Hive::Markers.set(
        task.state_file, :error,
        reason: "outcome_evidence_capability_blocked",
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest")
      )

      command = Hive::Commands::Evidence.new(
        "recover", task.slug,
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest"),
        task_resolver: -> { task }
      )
      out, = capture_io { command.call }

      assert_includes out, "recovery epoch advanced to 1"
      marker = Hive::Markers.current(task.state_file)
      assert_equal "outcome_evidence_recovery_ready", marker.attrs.fetch("reason")
      assert_equal "1", marker.attrs.fetch("recovery_epoch")

      stale = Hive::Commands::Evidence.new(
        "recover", task.slug,
        generation: pointer.fetch("generation"), recovery_digest: "a" * 64,
        task_resolver: -> { task }
      )
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { stale.call }
    end
  end

  def test_recover_revalidates_the_complete_blocked_package_before_advancing
    with_tmp_dir do |dir|
      task = fake_task(dir)
      pointer = blocked_package(task)
      Hive::Markers.set(
        task.state_file, :error,
        reason: "outcome_evidence_capability_blocked",
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest")
      )
      current_path = File.join(task.folder, "outcome-evidence", "current.json")
      tampered = JSON.parse(File.read(current_path))
      tampered["failed_claims"] = [ "claim-other" ]
      File.write(current_path, JSON.generate(tampered) << "\n")
      command = Hive::Commands::Evidence.new(
        "recover", task.slug,
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest"),
        task_resolver: -> { task }
      )

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { command.call }
      refute File.exist?(File.join(task.folder, "outcome-evidence", "recovery.json"))
      marker = Hive::Markers.current(task.state_file)
      assert_equal "outcome_evidence_capability_blocked", marker.attrs.fetch("reason")
    end
  end

  private

  def fake_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-task")
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "artifact.md")
    File.write(state_file, "")
    FakeTask.new(
      folder: folder, slug: "demo-task", project_root: dir,
      project_name: "demo", state_file: state_file
    )
  end

  def blocked_package(task)
    paths = [ "lib/feature.rb" ]
    identity = {
      "repository" => nil, "branch" => "demo", "implementation_base" => "a" * 40,
      "merge_base" => "a" * 40, "implementation_head" => "b" * 40,
      "changed_paths" => paths,
      "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
    }
    store = Hive::Artifacts::OutcomeEvidence::Store.new(
      task: task, project: "demo",
      controller_binding: -> { { "task_generation" => "3", "recovery_epoch" => 0 } }
    )
    requirement = store.open_generation!(
      identity: identity,
      claims: [
        {
          "id" => "claim-feature", "statement" => "The feature exposes its new user outcome clearly.",
          "proof_kind" => "document", "changed_paths" => paths
        }
      ],
      exclusions: [],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    )
    store.publish_blocked!(
      generation: requirement.fetch("generation"), reason: "capability_blocked",
      failed_claims: [ "claim-feature" ],
      reviewer_reasons: [ "The configured reviewer cannot inspect the required proof kind." ],
      attempt_ids: []
    )
  end
end
