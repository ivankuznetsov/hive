require "test_helper"
require "hive/attempts/context"
require "hive/implementation_identity/reconstructor"

class ImplementationIdentityReconstructorTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :slug, :id, :project_root, keyword_init: true)
  OWNER = {
    "pid" => Process.pid,
    "start_fingerprint" => "start",
    "session_id" => Process.getsid(0),
    "process_group_id" => Process.getpgrp
  }.freeze

  def test_structured_attempt_identity_wins_over_logged_argv
    with_legacy_attempts do |task, store, current|
      historical = compatibility_attempt(store, "historical-execute", "4-execute", "codex")
      store.checkpoint(
        historical,
        checkpoint: {
          "implementation_identity" => {
            "provider" => "codex", "model" => "gpt-5.6-sol", "effort" => "xhigh"
          }
        },
        now: Time.now.utc
      )
      log_dir = File.join(task.folder, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "execute.log"),
                 "[hive] spawn cmd=[\"claude\",\"--model\",\"claude-fable-5\"]\n")

      selection = with_context(current) do
        described_class(task, store).reconstruct!
      end

      assert_equal "codex", selection.provider
      assert_equal "gpt-5.6-sol", selection.model
      assert_equal "historical-execute", selection.originating_attempt
      event = journal(task).find { |record| record["event_type"] == "implementation_identity_backfilled" }
      assert_equal "structured", event.dig("provenance", "recovery")
    end
  end

  def test_config_fallback_warns_and_backfills_once
    with_legacy_attempts do |task, store, current|
      reconstructor = described_class(task, store)
      first = with_context(current) { reconstructor.reconstruct! }
      second = with_context(current) { described_class(task, store).reconstruct! }

      assert_equal first.to_h, second.to_h
      types = journal(task).map { |record| record["event_type"] }
      assert_equal 1, types.count("implementation_identity_fallback")
      assert_equal 1, types.count("implementation_identity_backfilled")
      assert_equal "legacy_backfill", first.source
    end
  end

  def test_structured_history_is_bound_to_project_task_and_generation
    with_legacy_attempts do |task, store, current|
      matching = compatibility_attempt(store, "matching-execute", "4-execute", "codex")
      store.checkpoint(
        matching,
        checkpoint: {
          "implementation_identity" => {
            "provider" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
          }
        },
        now: Time.now.utc
      )
      foreign = compatibility_attempt(
        store, "foreign-execute", "4-execute", "claude", project: "other"
      )
      store.checkpoint(
        foreign,
        checkpoint: {
          "implementation_identity" => {
            "provider" => "claude", "model" => "claude-fable-5", "effort" => "high"
          }
        },
        now: Time.now.utc
      )

      selection = with_context(current) { described_class(task, store).reconstruct! }

      assert_equal "codex", selection.provider
      assert_equal "matching-execute", selection.originating_attempt
    end
  end

  def test_missing_history_never_uses_merged_claude_default_implicitly
    with_legacy_attempts(explicit_execute: false) do |task, store, current|
      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        with_context(current) { described_class(task, store).reconstruct! }
      end

      assert_match(/not explicitly configured/, error.message)
      assert_empty journal(task)
    end
  end

  def test_logged_codex_argv_recovers_model_and_reasoning_effort
    with_legacy_attempts do |task, store, current|
      historical = compatibility_attempt(store, "historical-execute", "4-execute", "codex")
      log_dir = File.join(task.folder, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(
        File.join(log_dir, "execute.log"),
        '[hive] spawn cmd=["codex","exec","--model","gpt-5.6-sol","-c",' \
          '"model_reasoning_effort=xhigh"]' + "\n"
      )

      selection = with_context(current) { described_class(task, store).reconstruct! }

      assert_equal "codex", selection.provider
      assert_equal "gpt-5.6-sol", selection.model
      assert_equal "xhigh", selection.effective_effort
      assert_equal historical.attempt_id, selection.originating_attempt
      event = journal(task).find { |record| record["event_type"] == "implementation_identity_backfilled" }
      assert_equal "logged_argv", event.dig("provenance", "recovery")
    end
  end

  def test_missing_current_attempt_fails_before_recovery
    with_tmp_dir do |root|
      task = TaskStub.new(
        folder: root, state_file: File.join(root, "pr.md"), slug: "legacy-task",
        id: 42, project_root: root
      )
      projection = Struct.new(:value) { def read = value }.new({ "implementation_identity" => {} })
      attempt_store = Struct.new(:unused) { def fetch(*) = nil }.new
      subject = Hive::ImplementationIdentity::Reconstructor.new(
        task: task, cfg: config(root), attempt_store: attempt_store,
        projection_store: projection
      )

      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        with_attempt_context(
          attempt_id: "missing", task_generation: 0, ownership_generation: "owner-0"
        ) { subject.reconstruct! }
      end
      assert_match(/durable attempt "missing" is unavailable/, error.message)
    end
  end

  def test_log_recovery_skips_unreadable_logs_and_rejects_untrusted_argv_shapes
    with_legacy_attempts do |task, store, current|
      log_dir = File.join(task.folder, "logs")
      FileUtils.mkdir_p(log_dir)
      path = File.join(log_dir, "execute.log")
      File.write(path, "unreadable")
      subject = described_class(task, store)
      original = File.method(:readlines)

      with_replaced_singleton_method(File, :readlines, lambda { |candidate, **kwargs|
        raise Errno::EACCES, candidate if candidate == path

        original.call(candidate, **kwargs)
      }) do
        assert_nil subject.send(:logged_argv_components, current)
      end

      assert_nil subject.send(:parse_logged_argv, "cmd=[not-json]")
      assert_nil subject.send(:parse_logged_argv, "cmd=#{"[" + ("x" * (33 * 1024)) + "]"}")
      assert_nil subject.send(:parse_logged_argv, "cmd=[1]")
      assert_nil subject.send(:codex_effort, [ "codex", "--model", "gpt" ])
      refute subject.send(:usable_components?, "provider" => "codex", "model" => "default")
    end
  end

  def test_log_path_discovery_degrades_when_metadata_is_unreadable
    with_legacy_attempts do |task, store, _current|
      log_dir = File.join(task.folder, "logs")
      FileUtils.mkdir_p(log_dir)
      path = File.join(log_dir, "execute.log")
      File.write(path, "log")

      with_replaced_singleton_method(File, :mtime, ->(_candidate) { raise Errno::EACCES, path }) do
        assert_equal [], described_class(task, store).send(:log_paths)
      end
    end
  end

  def test_projected_routed_identity_reconstructs_typed_arguments_without_live_models
    with_tmp_dir do |root|
      task = TaskStub.new(
        folder: root, state_file: File.join(root, "task.md"), slug: "legacy-task",
        id: 42, project_root: root
      )
      identity = {
        "stage" => "execute", "provider" => "codex", "model" => "gpt-5.6-sol",
        "profile_name" => "codex", "launcher_identity" => "codex-cli/v1",
        "source" => "persisted_execute", "generation" => 2,
        "originating_attempt" => "execute-2", "requested_effort" => "xhigh",
        "effective_effort" => "xhigh", "effort_supported" => true,
        "model_pinned" => true,
        "routing" => {
          "stage" => "execute_implementation",
          "model" => "gpt-5.6-sol",
          "effort" => "xhigh",
          "provenance" => {
            "model" => { "kind" => "exact", "key" => "execute_implementation" },
            "effort" => { "kind" => "coarse", "key" => "execute" }
          }
        }
      }
      projection = Struct.new(:value) do
        def read = value
      end.new({ "implementation_identity" => { "execute" => identity } })
      subject = Hive::ImplementationIdentity::Reconstructor.new(
        task: task, cfg: config(root), attempt_store: Object.new,
        projection_store: projection
      )

      selection = with_attempt_context(
        attempt_id: "retry", task_generation: 2, ownership_generation: "owner-2"
      ) { subject.reconstruct! }
      arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:codex))

      assert_empty selection.native_arguments
      assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh" ],
                   arguments.global_arguments
    end
  end

  def test_projected_legacy_identity_without_routing_keeps_flat_arguments
    with_tmp_dir do |root|
      task = TaskStub.new(
        folder: root, state_file: File.join(root, "task.md"), slug: "legacy-task",
        id: 42, project_root: root
      )
      identity = {
        "stage" => "execute", "provider" => "codex", "model" => "gpt-5.6-sol",
        "profile_name" => "codex", "launcher_identity" => "codex-cli/v1",
        "source" => "persisted_execute", "generation" => 2,
        "originating_attempt" => "execute-2", "requested_effort" => "xhigh",
        "effective_effort" => "xhigh", "effort_supported" => true,
        "model_pinned" => true
      }
      projection = Struct.new(:value) do
        def read = value
      end.new({ "implementation_identity" => { "execute" => identity } })
      subject = Hive::ImplementationIdentity::Reconstructor.new(
        task: task, cfg: config(root), attempt_store: Object.new,
        projection_store: projection
      )

      selection = with_attempt_context(
        attempt_id: "retry", task_generation: 2, ownership_generation: "owner-2"
      ) { subject.reconstruct! }

      assert_nil selection.routing
      assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh" ],
                   selection.native_arguments
    end
  end

  private

  def described_class(task, store)
    Hive::ImplementationIdentity::Reconstructor.new(
      task: task, cfg: config(task.project_root), attempt_store: store
    )
  end

  def with_legacy_attempts(explicit_execute: true)
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        folder: folder, state_file: File.join(folder, "pr.md"), slug: "legacy-task",
        id: 42, project_root: root
      )
      File.write(task.state_file, "body")
      @explicit_execute = explicit_execute
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      current = compatibility_attempt(store, "current-open-pr", "5-open-pr", "claude")
      yield task, store, current
    ensure
      @explicit_execute = nil
    end
  end

  def compatibility_attempt(store, id, stage, provider, project: "demo", input_epoch: 0)
    store.create_compatibility_running(
      attempt_id: id, task_id: "42", project: project, task_slug: "legacy-task",
      intended_stage: stage, task_generation: "owner-0", ownership_generation: "owner-0",
      task_input_epoch: input_epoch, progress_token: "progress-#{id}", owner: OWNER,
      provider: provider, starting_revision: nil, now: Time.now.utc
    )
  end

  def with_context(attempt, &block)
    with_attempt_context(
      attempt_id: attempt.attempt_id, task_generation: 0,
      ownership_generation: attempt.ownership_generation, &block
    )
  end

  def config(root)
    fields = @explicit_execute ? { "agent" => "codex", "model" => "gpt-5.6-sol" }.freeze : {}.freeze
    {
      "project_root" => root,
      "execute" => { "agent" => "claude" }.merge(fields),
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => fields, "open_pr" => {}, "review.fix" => {}, "review.ci" => {}
      }.freeze
    }
  end

  def journal(task)
    Hive::TaskProjection.read_journal(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
  end
end
