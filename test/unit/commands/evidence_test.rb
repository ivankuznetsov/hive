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
    requests = []
    response = {
      "ok" => true, "status" => 0,
      "payload" => {
        "status" => "captured", "exit_status" => 0,
        "representations" => [
          { "role" => "original", "path" => "work/demo.cast" },
          { "role" => "review", "path" => "work/demo.txt" }
        ]
      }
    }
    with_capture_mailbox(->(request) { requests << request; response }) do |environment|
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
      assert_equal "terminal", requests.first.fetch("operation")
      assert_equal "demo", requests.first.fetch("name")
      assert_equal [ RbConfig.ruby, "-e", "puts 'captured'" ],
                   requests.first.fetch("argv")
    end
  end

  def test_terminal_capture_validates_names_and_prints_plain_output
    response = {
      "ok" => true, "status" => 0,
      "payload" => {
        "status" => "captured", "exit_status" => 0,
        "representations" => [
          { "role" => "original", "path" => "work/plain.cast" },
          { "role" => "review", "path" => "work/plain.txt" }
        ]
      }
    }
    with_capture_mailbox(->(_request) { response }) do |environment|
      out, = capture_io do
        Hive::Commands::Evidence.new(
          "terminal", "plain", command: [ "true" ],
          environment: environment
        ).call
      end
      assert_includes out, "recorded terminal evidence"
      assert_includes out, "review:"
      assert_includes out, "exit: 0"
    end

    assert_raises(Hive::UsageError) do
      Hive::Commands::Evidence.new(
        "terminal", "../bad", command: [ "true" ], environment: {}
      ).call
    end
  end

  def test_project_server_is_controller_scoped_and_returns_readiness
    requests = []
    response = {
      "ok" => true, "status" => 0,
      "payload" => {
        "driver" => "hive-project-server", "status" => "ready",
        "app_port" => 45_678, "app_endpoint" => "http://127.0.0.1:45678"
      }
    }
    with_capture_mailbox(->(request) { requests << request; response }) do |environment|
      command = Hive::Commands::Evidence.new(
        "server", "bin/rails", json: true,
        command: [ "server", "-p", "45678" ], environment: environment
      )

      out, = capture_io { command.call }
      payload = JSON.parse(out)

      assert_equal "ready", payload.fetch("status")
      assert_equal "server", requests.first.fetch("operation")
      assert_equal [ "bin/rails", "server", "-p", "45678" ],
                   requests.first.fetch("argv")

      plain = Hive::Commands::Evidence.new(
        "server", "bin/rails", command: [ "server", "-p", "45678" ],
        environment: environment
      )

      out, = capture_io { plain.call }

      assert_includes out, "ready at http://127.0.0.1:45678"
    end

    assert_raises(Hive::UsageError) do
      Hive::Commands::Evidence.new("server", nil, environment: {}).call
    end
  end

  def test_terminal_and_browser_runtime_failures_are_usage_errors
    failed = ->(_request) do
      { "ok" => false, "status" => 64, "error" => "capture failed" }
    end
    with_capture_mailbox(failed) do |environment|
      error = assert_raises(Hive::UsageError) do
        Hive::Commands::Evidence.new(
          "terminal", "failed", command: [ "true" ], environment: environment
        ).call
      end
      assert_match(/capture failed/, error.message)

      error = assert_raises(Hive::UsageError) do
        Hive::Commands::Evidence.new(
          "browser", "snapshot", environment: environment
        ).call
      end
      assert_match(/capture failed/, error.message)
    end

    assert_raises(Hive::UsageError) do
      Hive::Commands::Evidence.new(
        "browser", "snapshot", environment: {}
      ).call
    end
  end

  def test_browser_gateway_response_is_bounded_complete_and_successful
    oversized = ->(_request) do
      { "ok" => true, "status" => 0, "stdout" => "x" * (600 * 1024), "stderr" => "" }
    end
    with_capture_mailbox(oversized) do |environment|
      error = assert_raises(Hive::UsageError) do
        Hive::Commands::Evidence.new(
          "browser", "snapshot", environment: environment
        ).call
      end
      assert_match(/oversized/, error.message)
    end

    incomplete = ->(_request) { { "ok" => true } }
    with_capture_mailbox(incomplete) do |environment|
      error = assert_raises(Hive::UsageError) do
        Hive::Commands::Evidence.new(
          "browser", "snapshot", environment: environment
        ).call
      end
      assert_match(/browser gateway is unavailable/, error.message)
    end

    success = ->(request) do
      assert_equal [ "snapshot", "-i" ], request.fetch("argv")
      { "ok" => true, "status" => 0, "stdout" => "ready\n", "stderr" => "" }
    end
    with_capture_mailbox(success) do |environment|
      out, = capture_io do
        Hive::Commands::Evidence.new(
          "browser", "snapshot", command: [ "-i" ], environment: environment
        ).call
      end
      assert_equal "ready\n", out
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

  def with_capture_mailbox(handler)
    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: handler).start!
    yield({ "HIVE_EVIDENCE_CAPTURE_MAILBOX" => mailbox.root })
  ensure
    mailbox&.close
  end
end
