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

  def test_missing_history_never_uses_merged_claude_default_implicitly
    with_legacy_attempts(explicit_execute: false) do |task, store, current|
      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        with_context(current) { described_class(task, store).reconstruct! }
      end

      assert_match(/not explicitly configured/, error.message)
      assert_empty journal(task)
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

  def compatibility_attempt(store, id, stage, provider)
    store.create_compatibility_running(
      attempt_id: id, task_id: "42", project: "demo", task_slug: "legacy-task",
      intended_stage: stage, task_generation: "owner-0", ownership_generation: "owner-0",
      task_input_epoch: 0, progress_token: "progress-#{id}", owner: OWNER,
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
