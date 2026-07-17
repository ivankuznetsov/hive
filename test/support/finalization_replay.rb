require "digest"
require "fileutils"
require "json"
require "set"
require "time"
require "yaml"
require "hive/babysitter/job_runner"
require "hive/babysitter/job_store"
require "hive/babysitter/project_tick"
require "hive/finalization/archive_cleanup"
require "hive/finalization/reconciler"
require "hive/git_ops"
require "hive/task"
require "hive/task_journal/envelope"
require "hive/task_meta"
require "hive/worktree"

module HiveTestSupport
  # Deterministic, offline replay of the sanitized PR 295 lifecycle. The
  # helper drives the production registry, runner, journal, reconciler, and
  # cleanup classes; only GitHub reads are replaced by checked-in snapshots.
  class FinalizationReplay
    SCHEMA_VERSION = 1
    STEPS = %i[
      finalized ready_a crashed_claim head_b list_disappearance merged
      archive_ready stage_moved cleanup
    ].freeze

    class InvalidFixture < StandardError; end

    Result = Data.define(:projection, :records, :jobs, :task_folder, :performed, :stage_moves)

    attr_reader :bundle_path, :project_root, :manifest, :handoff, :responses

    def initialize(bundle_path, project_root:, terminal_response: "merged_head_b")
      @bundle_path = File.expand_path(bundle_path)
      @project_root = File.expand_path(project_root)
      @manifest = read_json("manifest.json")
      validate_fixture!
      @handoff = read_json(manifest.fetch("handoff"))
      @responses = read_json(manifest.fetch("github_responses"))
      @expected_registry = read_json(manifest.fetch("expected_registry"))
      @terminal_response = terminal_response
      unless responses.key?(@terminal_response)
        raise InvalidFixture, "unknown terminal response #{@terminal_response.inspect}"
      end
      @authority_now = Time.now.utc
      @store = Hive::Babysitter::JobStore.new(project_root: project_root, clock: -> { @authority_now })
    end

    def run(until_step: nil, crash_after_cleanup: nil)
      unless until_step.nil? || STEPS.include?(until_step.to_sym)
        raise ArgumentError, "unknown replay step #{until_step.inspect}"
      end
      target = until_step&.to_sym
      performed = []
      stage_moves = 0

      setup_handoff! unless current_job
      performed << :finalized
      return result(performed, stage_moves) if target == :finalized

      if projection.fetch("head_generation") == 1 && projection.fetch("state") != "merge_ready"
        run_exact_job!("ready_head_a", at: response_time("ready_head_a"), owner: "daemon-before-restart")
        performed << :ready_a
      end
      assert_not_archivable!
      return result(performed, stage_moves) if target == :ready_a

      if projection.fetch("head_generation") == 1
        reserve_crashed_claim! unless live_claim(current_job)
        performed << :crashed_claim
      end
      return result(performed, stage_moves) if target == :crashed_claim

      if projection.fetch("head_generation") == 1
        run_exact_job!("new_head_b", at: response_time("new_head_b"), owner: "daemon-after-restart")
        performed << :head_b
      end
      assert_not_archivable!
      return result(performed, stage_moves) if target == :head_b

      if projection.fetch("state") == "babysitter_active"
        run_missing_list_tick!
        performed << :list_disappearance
      end
      assert_not_archivable!
      return result(performed, stage_moves) if target == :list_disappearance

      unless %w[merged blocked archive_ready].include?(projection.fetch("state"))
        run_exact_job!(@terminal_response, at: response_time(@terminal_response), owner: "daemon-terminal")
        performed << :merged if projection.fetch("state") == "merged"
      end
      return result(performed, stage_moves) if target == :merged || projection.fetch("state") == "blocked"

      if projection.fetch("state") == "merged"
        @authority_now = response_time(@terminal_response) + 1
        Hive::Finalization::Reconciler.new(task_folder: current_task_folder,
                                           clock: -> { @authority_now }).reconcile
        performed << :archive_ready
      end
      return result(performed, stage_moves) if target == :archive_ready

      if File.directory?(finalize_folder)
        FileUtils.mkdir_p(File.dirname(done_folder))
        FileUtils.mv(finalize_folder, done_folder)
        stage_moves += 1
        performed << :stage_moved
      end
      return result(performed, stage_moves) if target == :stage_moved

      cleanup = Hive::Finalization::ArchiveCleanup.new(
        task: Hive::Task.new(done_folder), clock: -> { @authority_now },
        after_step: lambda do |step|
          raise "injected cleanup crash after #{step}" if crash_after_cleanup&.to_sym == step
        end
      )
      cleanup.call
      performed << :cleanup
      validate_final_registry!
      result(performed, stage_moves)
    end

    private

    def validate_fixture!
      unless manifest.fetch("schema_version") == SCHEMA_VERSION
        raise InvalidFixture, "fixture schema_version must be #{SCHEMA_VERSION}"
      end
      %w[
        incident source sanitization handoff github_responses journal_inputs
        expected_registry provenance merge_timestamp files
      ].each do |key|
        raise InvalidFixture, "fixture missing #{key}" unless manifest.key?(key)
      end
      manifest.fetch("files").each do |relative, expected|
        path = File.join(bundle_path, relative)
        raise InvalidFixture, "fixture file missing: #{relative}" unless File.file?(path)
        actual = ::Digest::SHA256.file(path).hexdigest
        raise InvalidFixture, "fixture digest mismatch for #{relative}" unless actual == expected
      end
    end

    def setup_handoff!
      FileUtils.mkdir_p(finalize_folder)
      configure_babysitter!
      Hive::TaskMeta.write(finalize_folder, id: handoff.fetch("task_id"),
                           slug: handoff.fetch("task_slug"), display_name: "Sanitized PR 295 replay")
      File.write(File.join(finalize_folder, "pr.md"), <<~MD)
        ---
        pr_url: #{handoff.fetch('pr_url')}
        ---

        <!-- COMPLETE pr_url=#{handoff.fetch('pr_url')} is_draft=false -->
      MD
      File.write(File.join(finalize_folder, "summary.md"), "# Sanitized finalized handoff\n")
      worktree = Hive::Worktree.new(project_root, handoff.fetch("task_slug"))
      unless worktree.exists?
        worktree.create!(handoff.fetch("branch"), default_branch: Hive::GitOps.new(project_root).default_branch)
      end
      worktree.write_pointer!(finalize_folder, handoff.fetch("branch"))

      @authority_now = Time.iso8601(handoff.fetch("finalized_at"))
      job = @store.reserve!(
        project: handoff.fetch("project"), task_id: handoff.fetch("task_id"),
        task_slug: handoff.fetch("task_slug"), task_generation: handoff.fetch("task_generation"),
        repository: handoff.fetch("repository"), pr_number: handoff.fetch("pr_number"),
        pr_url: handoff.fetch("pr_url"), branch: handoff.fetch("branch"),
        head_sha: handoff.fetch("initial_head_sha"), head_generation: 1,
        finalize_attempt_id: handoff.fetch("finalize_attempt_id"),
        task_folder: finalize_folder, now: @authority_now
      )
      event = finalized_event(job)
      File.write(File.join(finalize_folder, "events.jsonl"), "#{JSON.generate(event)}\n")
      @store.activate!(job.fetch("job_id"), handoff_event_id: event.fetch("event_id"),
                       finalize_attempt_id: handoff.fetch("finalize_attempt_id"), now: @authority_now)
    end

    def finalized_event(job)
      time = Time.iso8601(handoff.fetch("finalized_at")).utc.iso8601(6)
      Hive::TaskJournal::Envelope.authoritative({
        event_id: "#{job.fetch('job_id')}:finalized",
        event_type: "finalized", occurred_at: time, observed_at: time,
        task: { "id" => handoff.fetch("task_id"), "slug" => handoff.fetch("task_slug") },
        workflow: "coding", stage: "8-finalize",
        attempt_id: handoff.fetch("finalize_attempt_id"),
        task_generation: handoff.fetch("task_generation"),
        ownership_generation: "sanitized-finalize-owner", reason: "durable finalized handoff",
        producer: { "kind" => "finalize_attempt", "attempt_id" => handoff.fetch("finalize_attempt_id") },
        evidence: [ { "kind" => "sanitized_incident_fixture", "incident" => manifest.fetch("incident") } ],
        provenance: { "source" => "sanitized-incident-replay", "synthetic" => true },
        payload: coordinates(job)
      })
    end

    def configure_babysitter!
      path = File.join(project_root, ".hive-state", "config.yml")
      config = File.file?(path) ? YAML.safe_load(File.read(path)) : {}
      config = {} unless config.is_a?(Hash)
      config["babysitter"] = {
        "enabled" => true, "budget_minutes" => 5,
        "labels_ignore" => [], "max_concurrent_prs" => 5
      }
      File.write(path, config.to_yaml)
    end

    def run_exact_job!(response_key, at:, owner:)
      @authority_now = at
      snapshot = snapshot_for(responses.fetch(response_key))
      with_offline_github(snapshot: snapshot) do
        Hive::Babysitter::JobRunner.run(
          job: current_job, store: @store, project: project_entry,
          cfg: { "babysitter" => { "budget_minutes" => 5 } },
          dry_run: false, logger: nil, inflight: Set.new, now: at, owner: owner
        )
      end
    end

    def run_missing_list_tick!
      response = responses.fetch("missing_from_open_list")
      snapshot = snapshot_for(response.fetch("exact_pr"))
      @authority_now = Time.iso8601(snapshot.observed_at)
      with_offline_github(snapshot: snapshot, open_prs: response.fetch("open_prs")) do
        Hive::Babysitter::ProjectTick.run(
          project_entry, dry_run: false, logger: nil_logger, inflight: Set.new,
          job_store: @store, now: @authority_now
        )
      end
    end

    def with_offline_github(snapshot:, open_prs: nil)
      expected_url = handoff.fetch("pr_url")
      exact = lambda do |url, **_kwargs|
        raise InvalidFixture, "unexpected exact PR URL #{url.inspect}" unless url == expected_url
        snapshot
      end
      list = ->(*_args, **_kwargs) { open_prs.nil? ? raise(InvalidFixture, "unexpected PR-list read") : open_prs }
      forbidden = ->(*_args, **_kwargs) { raise InvalidFixture, "fixture attempted an unrecorded GitHub operation" }
      with_singleton(Hive::Gh, :exact_pr_snapshot, exact) do
        with_singleton(Hive::Gh, :list_open_prs, list) do
          with_singleton(Hive::Gh, :pr_status_rollup, forbidden) do
            with_singleton(Hive::Babysitter::PrFixer, :run, forbidden) { yield }
          end
        end
      end
    end

    def with_singleton(receiver, name, replacement)
      original = receiver.method(name)
      receiver.define_singleton_method(name, &replacement)
      yield
    ensure
      receiver.define_singleton_method(name, &original) if original
    end

    def reserve_crashed_claim!
      @authority_now = Time.utc(2026, 7, 16, 22, 59, 0)
      token = @store.claim!(current_job.fetch("job_id"), owner: "daemon-crashed",
                            now: @authority_now, lease_sec: 30)
      raise InvalidFixture, "could not reserve the simulated crashed claim" unless token
    end

    def live_claim(job)
      job.fetch("claims").reverse_each.find { |claim| claim["state"] == "active" }
    end

    def assert_not_archivable!
      return if %w[merged archive_ready].include?(projection.fetch("state"))

      result = Hive::Finalization::Reconciler.new(
        task_folder: current_task_folder, clock: -> { @authority_now }
      ).reconcile
      return if result.status == :not_eligible

      raise InvalidFixture, "weak replay evidence unexpectedly became archive eligible"
    end

    def validate_final_registry!
      jobs = @store.jobs
      job = jobs.fetch(0)
      actual = {
        "stable_job_count" => jobs.length,
        "final_state" => job.fetch("state"),
        "final_head_generation" => job.fetch("head_generation"),
        "final_head_sha" => job.fetch("head_sha"),
        "claim_fences" => job.fetch("claims").map { |claim| claim.fetch("claim_fence") },
        "claim_outcomes" => job.fetch("claims").map { |claim| claim.fetch("outcome") }
      }
      expected = @expected_registry.slice(*actual.keys)
      raise InvalidFixture, "final registry does not match sanitized expectation" unless actual == expected
    end

    def result(performed, stage_moves)
      Result.new(
        projection: projection,
        records: Hive::TaskProjection.read_journal(File.join(current_task_folder, "events.jsonl")),
        jobs: @store.jobs,
        task_folder: current_task_folder,
        performed: performed.freeze,
        stage_moves: stage_moves
      )
    end

    def projection
      records = Hive::TaskProjection.read_journal(File.join(current_task_folder, "events.jsonl"))
      Hive::Finalization::Projection.project(records: records)
    end

    def current_job
      @store.current_job(task_slug: handoff.fetch("task_slug"),
                         task_generation: handoff.fetch("task_generation"))
    end

    def coordinates(job)
      identity = job.fetch("identity")
      {
        "job_id" => job.fetch("job_id"), "repository" => identity.fetch("repository"),
        "pr_number" => identity.fetch("pr_number"), "pr_url" => job.fetch("pr_url"),
        "head_sha" => job.fetch("head_sha"), "head_generation" => job.fetch("head_generation"),
        "finalize_attempt_id" => job.fetch("finalize_attempt_id")
      }
    end

    def snapshot_for(data)
      Hive::Gh::PrSnapshot.new(
        repository: data.fetch("repository"), number: data.fetch("number"), url: data.fetch("url"),
        state: data.fetch("state"), head_sha: data.fetch("head_sha"),
        head_branch: data.fetch("head_branch"), base_branch: data.fetch("base_branch"),
        merged_at: data["merged_at"], observed_at: data.fetch("observed_at"),
        mergeable: data["mergeable"], merge_state_status: data["merge_state_status"],
        review_decision: data["review_decision"], status_check_rollup: data["status_check_rollup"]
      )
    end

    def response_time(key)
      Time.iso8601(responses.fetch(key).fetch("observed_at"))
    end

    def project_entry
      { "name" => handoff.fetch("project"), "path" => project_root,
        "hive_state_path" => File.join(project_root, ".hive-state") }
    end

    def nil_logger
      @nil_logger ||= Object.new.tap do |logger|
        logger.define_singleton_method(:event) { |*_args, **_kwargs| nil }
      end
    end

    def finalize_folder
      File.join(project_root, ".hive-state", "stages", "8-finalize", handoff.fetch("task_slug"))
    end

    def done_folder
      File.join(project_root, ".hive-state", "stages", "9-done", handoff.fetch("task_slug"))
    end

    def current_task_folder
      File.directory?(done_folder) ? done_folder : finalize_folder
    end

    def read_json(relative)
      JSON.parse(File.read(File.join(bundle_path, relative)))
    rescue JSON::ParserError, Errno::ENOENT => e
      raise InvalidFixture, "invalid fixture file #{relative}: #{e.message}"
    end
  end
end
