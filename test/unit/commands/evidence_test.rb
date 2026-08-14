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
      tampered["failed_targets"] = [ "claim-other" ]
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

  def test_recover_validates_arguments_resolves_normally_and_emits_json
    digest = "a" * 64
    invalid = [
      [ "unknown", "demo-task", digest, digest ],
      [ "recover", nil, digest, digest ],
      [ "recover", "demo-task", "short", digest ],
      [ "recover", "demo-task", digest, "short" ]
    ]
    invalid.each do |subcommand, target, generation, recovery_digest|
      command = Hive::Commands::Evidence.new(
        subcommand, target, generation: generation, recovery_digest: recovery_digest,
        task_resolver: -> { flunk "invalid arguments must fail before task resolution" }
      )
      assert_raises(Hive::UsageError) { command.call }
    end

    with_tmp_dir do |dir|
      task = fake_task(dir)
      pointer = blocked_package(task)
      Hive::Markers.set(
        task.state_file, :error,
        reason: "outcome_evidence_capability_blocked",
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest")
      )
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { task }
      calls = []
      factory = lambda do |target, project_filter:, stage_filter:|
        calls << [ target, project_filter, stage_filter ]
        resolver
      end
      command = Hive::Commands::Evidence.new(
        "recover", task.slug, project: "demo", stage: "7-artifacts", json: true,
        generation: pointer.fetch("generation"),
        recovery_digest: pointer.fetch("recovery_digest")
      )

      out, = with_replaced_singleton_method(Hive::TaskResolver, :new, factory) do
        capture_io { command.call }
      end
      assert_equal "recovery_ready", JSON.parse(out).fetch("status")
      assert_equal [ [ task.slug, "demo", "7-artifacts" ] ], calls
    end
  end

  def test_recover_rejects_a_nonblocked_current_pointer
    with_tmp_dir do |dir|
      task = fake_task(dir)
      generation = "a" * 64
      recovery_digest = "b" * 64
      Hive::Markers.set(
        task.state_file, :error,
        reason: "outcome_evidence_capability_blocked",
        generation: generation, recovery_digest: recovery_digest
      )
      package = {
        "current" => { "status" => "accepted" },
        "requirement" => { "task_generation" => "1" }
      }
      store = Object.new
      store.define_singleton_method(:package) { package }
      command = Hive::Commands::Evidence.new(
        "recover", task.slug, generation: generation, recovery_digest: recovery_digest,
        task_resolver: -> { task }
      )

      replacement = ->(**) { store }
      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Store, :new, replacement
      ) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { command.call }
      end
    end
  end

  def test_terminal_capture_is_controller_scoped_and_returns_ready_descriptors
    with_tmp_dir do |dir|
      task_root = File.join(dir, "task")
      source_root = File.join(dir, "source")
      writable_root = File.join(task_root, "work")
      FileUtils.mkdir_p([ task_root, source_root, writable_root ])
      environment = {
        "PATH" => ENV.fetch("PATH", ""),
        "HIVE_EVIDENCE_TASK_ROOT" => task_root,
        "HIVE_EVIDENCE_SOURCE_ROOT" => source_root,
        "HIVE_EVIDENCE_WRITE_ROOT" => writable_root,
        "HIVE_EVIDENCE_SOURCE_SHA" => "a" * 40
      }
      command = Hive::Commands::Evidence.new(
        "terminal", "demo", json: true,
        command: [ RbConfig.ruby, "-e", "puts 'captured'" ],
        environment: environment
      )

      out, = capture_io { command.call }
      payload = JSON.parse(out)

      assert_equal "captured", payload.fetch("status")
      assert_equal 0, payload.fetch("exit_status")
      assert_equal %w[original review],
                   payload.fetch("representations").map { |row| row.fetch("role") }
      payload.fetch("representations").each do |row|
        assert_match(/\Awork\/demo\.(?:cast|txt)\z/, row.fetch("path"))
        assert File.file?(File.join(task_root, row.fetch("path")))
      end

      outside = Hive::Commands::Evidence.new(
        "terminal", "demo", command: [ "true" ],
        environment: environment.merge("HIVE_EVIDENCE_WRITE_ROOT" => dir)
      )
      assert_raises(Hive::UsageError) { outside.call }
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
      failed_targets: [ "claim-feature" ],
      reviewer_reasons: [ "The configured reviewer cannot inspect the required proof kind." ],
      attempt_ids: []
    )
  end
end
