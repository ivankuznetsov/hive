require "test_helper"
require "hive/stages/finalize"
require "hive/stages/base"

class StagesFinalizePromptTest < Minitest::Test
  include HiveTestHelper

  def test_finalize_prompt_includes_demo_links_instruction
    prompt = Hive::Stages::Base.render(
      "finalize_prompt.md.erb",
      Hive::Stages::Base::TemplateBindings.new(
        project_name: "demo",
        task_folder: "/tmp/task",
        worktree_path: "/tmp/worktree",
        slug: "demo-260618-abcd",
        branch: "demo-260618-abcd",
        pr_url: "https://github.com/o/r/pull/1",
        plan_text: "plan",
        reviews_summary: "reviews",
        user_supplied_tag: "user-data"
      )
    )

    assert_includes prompt, "media/manifest.json"
    assert_includes prompt, "screenote_url"
    assert_includes prompt, "## Demo"
    assert_includes prompt, "Preserve or re-add"
  end

  def test_exact_snapshot_error_marks_the_task_for_retry
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "draft\n")
      task = Struct.new(:state_file).new(state_file)
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, lambda { |*_args, **_kwargs|
        raise Hive::GhError, "api offline"
      }) do
        snapshot, result = Hive::Stages::Finalize.exact_snapshot_or_error(task, "https://example.test/pr/1", {})
        assert_nil snapshot
        assert_equal :error, result.fetch(:status)
        assert_equal "github_unavailable", Hive::Markers.current(state_file).attrs.fetch("reason")
      end
    end
  end

  def test_changed_pr_uses_serialized_replacement_protocol
    current_job = {
      "job_id" => "bsj-v1-#{'a' * 32}",
      "identity" => { "repository" => "github.com/acme/demo", "pr_number" => 12 }
    }
    replacement = current_job.merge(
      "job_id" => "bsj-v1-#{'b' * 32}", "replacement_proof" => { "state" => "CLOSED" }
    )
    finalization = {
      "state" => "finalized", "job_id" => current_job.fetch("job_id"),
      "pr_url" => "https://github.com/acme/demo/pull/12"
    }
    projection_store = Object.new
    projection_store.define_singleton_method(:read) { { "finalization" => finalization } }
    store = Object.new
    store.define_singleton_method(:read) { |_job_id| current_job }
    reservation = nil
    store.define_singleton_method(:reserve_replacement!) { |**attributes| reservation = attributes; replacement }
    store.define_singleton_method(:activate!) { |*_args, **_kwargs| replacement }
    context = Hive::Attempts::Context.new(
      attempt_id: "attempt-2", task_generation: 3, ownership_generation: "owner-2"
    )
    task = Struct.new(:project_root, :folder, :id, :slug, :workflow).new(
      "/tmp/project", "/tmp/task", "42", "task", Struct.new(:id).new(:coding)
    )
    snapshot = pr_snapshot(number: 13, head_sha: "b" * 40)
    old_snapshot = pr_snapshot(number: 12, state: "CLOSED")
    event = { "event_id" => "finalized-2" }
    result = Hive::Stages::Finalize::HandoffResult.new(job: replacement, event: event, projection: {})

    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
      with_replaced_singleton_method(Hive::Babysitter::JobStore, :new, ->(**_kwargs) { store }) do
        with_replaced_singleton_method(Hive::TaskProjection::Store, :new, ->(**_kwargs) { projection_store }) do
          with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, ->(*_args, **_kwargs) { old_snapshot }) do
            with_replaced_singleton_method(Hive::Stages::Finalize, :append_finalize_event!,
                                           ->(*_args, **_kwargs) { event }) do
              with_replaced_singleton_method(Hive::Stages::Finalize, :verified_handoff,
                                             ->(*_args) { result }) do
                assert_equal result,
                             Hive::Stages::Finalize.establish_handoff!(task, {}, snapshot, "feature", now: Time.utc(2026, 7, 17))
              end
            end
          end
        end
      end
    end
    assert_equal current_job.fetch("job_id"), reservation.fetch(:old_job_id)
    assert_equal "CLOSED", reservation.fetch(:remote_state)
  end

  def test_same_attempt_repairs_an_inactive_registry_activation
    with_tmp_dir do |folder|
      event = { "event_id" => "finalized-1" }
      File.write(File.join(folder, "events.jsonl"), "#{JSON.generate(event)}\n")
      task = Struct.new(:folder).new(folder)
      projection_store = Object.new
      projection_store.define_singleton_method(:read) do
        { "finalization" => {
          "finalize_attempt_id" => "attempt-1", "evidence" => { "finalized_event_id" => "finalized-1" }
        } }
      end
      activated = nil
      store = Object.new
      store.define_singleton_method(:activate!) { |*args, **kwargs| activated = [ args, kwargs ] }
      job = { "job_id" => "job-1", "state" => "inactive" }
      context = Hive::Attempts::Context.new(
        attempt_id: "attempt-1", task_generation: 3, ownership_generation: "owner-1"
      )

      returned = Hive::Stages::Finalize.adopt_or_repair_handoff!(
        task, store, projection_store, job, context, pr_snapshot, now: Time.utc(2026, 7, 17)
      )
      assert_equal event, returned
      assert_equal "job-1", activated.first.first
    end
  end

  def test_existing_handoff_event_replays_or_rejects_divergent_content
    with_tmp_dir do |folder|
      task = Struct.new(:folder, :id, :slug, :workflow).new(
        folder, "42", "task", Struct.new(:id).new(:coding)
      )
      context = Hive::Attempts::Context.new(
        attempt_id: "attempt-1", task_generation: 3, ownership_generation: "owner-1"
      )
      job = { "job_id" => "job-1", "head_generation" => 1 }
      snapshot = pr_snapshot
      event_id = Hive::Stages::Finalize.deterministic_handoff_event_id("finalized", "job-1", "attempt-1")
      payload = Hive::Stages::Finalize.handoff_coordinates(job, context, snapshot)
      existing = {
        "event_id" => event_id, "event_type" => "finalized",
        "producer" => { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" },
        "payload" => payload
      }
      File.write(File.join(folder, "events.jsonl"), "#{JSON.generate(existing)}\n")

      assert_equal existing, Hive::Stages::Finalize.append_finalize_event!(
        task, context, snapshot, job, type: "finalized", now: Time.utc(2026, 7, 17)
      )
      File.write(File.join(folder, "events.jsonl"),
                 "#{JSON.generate(existing.merge('payload' => payload.merge('head_sha' => 'b' * 40)))}\n")
      assert_raises(Hive::TaskJournal::EventIdCollision) do
        Hive::Stages::Finalize.append_finalize_event!(
          task, context, snapshot, job, type: "finalized", now: Time.utc(2026, 7, 17)
        )
      end
    end
  end

  def test_verified_handoff_rejects_registry_projection_disagreement
    store = Object.new
    store.define_singleton_method(:read) { |_job_id| { "state" => "inactive", "finalize_attempt_id" => "attempt-1" } }
    projection_store = Object.new
    projection_store.define_singleton_method(:rebuild!) do
      { "finalization" => { "job_id" => "job-1", "finalize_attempt_id" => "attempt-1" } }
    end

    assert_raises(Hive::StageError) do
      Hive::Stages::Finalize.verified_handoff(store, projection_store, "job-1", {})
    end
  end

  private

  def pr_snapshot(number: 12, state: "OPEN", head_sha: "a" * 40)
    Hive::Gh::PrSnapshot.new(
      repository: "github.com/acme/demo", number: number,
      url: "https://github.com/acme/demo/pull/#{number}", state: state,
      head_sha: head_sha, head_branch: "feature", base_branch: "main", merged_at: nil,
      observed_at: "2026-07-17T00:00:00Z", mergeable: nil, merge_state_status: nil,
      review_decision: nil, status_check_rollup: nil
    )
  end
end
