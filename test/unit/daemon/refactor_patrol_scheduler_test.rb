require "test_helper"
require "json"
require "hive/daemon/refactor_patrol_scheduler"

class HiveDaemonRefactorPatrolSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  class Guard
    def initialize(sha: "head")
      @sha = sha
    end

    def validate_and_snapshot!(merge_sha:)
      raise "missing merge" if merge_sha.to_s.empty?

      { "analysis_sha" => @sha }
    end
  end

  def test_reserves_oldest_due_job_with_stable_identity_and_durable_manifest_command
    with_project do |dir, entry, store|
      enqueue(store, job_id: "new", number: 8, merged_at: T0 + 60)
      enqueue(store, job_id: "old", number: 7, merged_at: T0)
      scheduler = scheduler(entry, store)

      candidates = scheduler.candidates(now: T0 + 120)
      assert_equal %w[old new], candidates.map { |item| item.fetch(:job_id) }
      dispatch = scheduler.reserve(candidates.first, now: T0 + 120)

      assert_equal "refactor-patrol-old", dispatch.fetch(:slug)
      assert_equal "refactor-patrol", dispatch.fetch(:stage)
      assert_includes dispatch.fetch(:command), "--job-manifest"
      refute_includes dispatch.fetch(:command), " --pr "
      assert_equal "old", dispatch.dig(:dispatch_token, :job_id)
      assert_equal "head", store.read_job("old").fetch("analysis_sha")
    end
  end

  def test_duplicate_enabled_repository_registrations_block_with_both_identities_and_backoff
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "one"), entry(second_dir, "two") ]
      first_store = Hive::RefactorPatrol::JobStore.new(first_dir)
      enqueue(first_store, registration: "one")
      stores = { first_dir => first_store, second_dir => Hive::RefactorPatrol::JobStore.new(second_dir) }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(path) { stores.fetch(path) },
        repository_resolver: ->(_entry, _cfg) { "Acme/Demo" },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)
      blocked = first_store.read_job("job-7")
      evidence = blocked.fetch("attempts").last.fetch("evidence")
      assert_equal %w[one two], evidence.fetch("registrations").map { |item| item.fetch("name") }
      assert_empty scheduler.candidates(now: T0 + 30), "durable backoff must avoid per-tick identity work"
    end
  end

  def test_completion_checkpoints_only_exit_zero_schema_valid_exact_complete_envelope
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      valid = complete_zero_envelope(entry)
      failures = [
        [ 0, { "schema" => "hive-refactor-patrol" } ],
        [ 1, valid ],
        [ 0, valid.merge("complete" => false, "zero_reason" => nil) ],
        [ 0, valid.merge("job_id" => "wrong-job") ],
        [ 0, valid.merge("source_pr" => valid.fetch("source_pr").merge("repository" => "acme/wrong")) ]
      ]
      now = T0
      failures.each_with_index do |(exit_code, envelope), index|
        dispatch = scheduler.reserve(scheduler.candidates(now: now).first, now: now)
        scheduler.spawned(
          dispatch, pid: 1234 + index, process_start_time: "boot-#{index}",
          pgid: 1234 + index, now: now + 1
        )
        result = scheduler.complete(
          dispatch_token: dispatch.fetch(:dispatch_token), exit_code: exit_code,
          envelope: envelope, now: now + 2
        )
        assert_equal :retry, result.fetch(:status)
        refute store.read_job("job-7").fetch("complete")
        assert_empty store.read_job("job-7").dig("dispositions", "accepted")
        now += 63
      end

      retry_dispatch = scheduler.reserve(scheduler.candidates(now: now).first, now: now)
      scheduler.spawned(retry_dispatch, pid: 2235, process_start_time: "boot-final", pgid: 2235, now: now + 1)
      completed = scheduler.complete(
        dispatch_token: retry_dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: valid, now: now + 2
      )
      assert_equal :closed, completed.fetch(:status)
      assert store.read_job("job-7").fetch("complete")
      assert_empty scheduler.candidates(now: T0 + 3600), "completed zero must be terminal exactly once"
    end
  end

  def test_stale_generation_cannot_complete_the_current_claim
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
      stale = dispatch.fetch(:dispatch_token).merge(generation: dispatch.dig(:dispatch_token, :generation) + 1)

      result = scheduler.complete(
        dispatch_token: stale, exit_code: 0, envelope: complete_zero_envelope(entry), now: T0 + 2
      )

      assert_equal :stale, result.fetch(:status)
      assert_equal "analyzing", store.read_job("job-7").fetch("state")
      assert_equal :closed, scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: complete_zero_envelope(entry), now: T0 + 3
      ).fetch(:status)
    end
  end

  def test_dry_run_leaves_authoritative_job_bytes_unchanged
    with_project do |dir, entry, store|
      enqueue(store)
      path = File.join(store.root, "jobs", "job-7.json")
      before = File.binread(path)
      dry_scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { "acme/demo" },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a", dry_run: true
      )

      dispatch = dry_scheduler.reserve(dry_scheduler.candidates(now: T0).first, now: T0)
      dry_scheduler.spawned(dispatch, pid: -1, process_start_time: nil, pgid: nil, now: T0 + 1)
      result = dry_scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0, envelope: nil, now: T0 + 2
      )

      assert_equal :dry_run, result.fetch(:status)
      assert_equal before, File.binread(path)
      refute File.exist?(File.join(dir, "patrol_arbiter.json"))
    end
  end

  def test_process_group_resolver_fails_closed_on_unverified_or_wrong_pgid_identity
    resolver = Hive::Daemon::RefactorPatrolScheduler::ProcessGroupResolver.new
    assert_equal :unresolved, resolver.call(
      "pid" => 999_999, "pgid" => 999_999, "process_start_time" => ""
    )
    assert_equal :resolved, resolver.call(
      "pid" => 999_999, "pgid" => 999_999, "process_start_time" => "recorded"
    )
    assert_equal :resolved, resolver.call(
      "pid" => nil, "owner_pid" => 999_999, "owner_process_start_time" => "recorded"
    )

    live_start = Hive::Lock.process_start_time(Process.pid)
    skip "process start identity unavailable" if live_start.to_s.empty?
    assert_equal :unresolved, resolver.call(
      "pid" => nil, "owner_pid" => Process.pid, "owner_process_start_time" => live_start
    )
    assert_equal :unresolved, resolver.call(
      "pid" => Process.pid, "pgid" => Process.getpgid(Process.pid) + 1,
      "process_start_time" => live_start
    )
  end

  private

  def with_project
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      yield dir, entry, Hive::RefactorPatrol::JobStore.new(dir)
    end
  end

  def scheduler(entry, store)
    Hive::Daemon::RefactorPatrolScheduler.new(
      registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
      job_store_factory: ->(_path) { store },
      repository_resolver: ->(_entry, _cfg) { "acme/demo" },
      checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
      claim_resolver: ->(_attempt) { :resolved }
    )
  end

  def entry(dir, name)
    { "name" => name, "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def enabled_cfg
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      "default_branch" => "main",
      "daemon" => { "enabled" => true },
      "refactor_patrol" => { "enabled" => true }
    )
  end

  def enqueue(store, job_id: "job-7", number: 7, merged_at: T0, registration: "demo")
    manifest = manifest(job_id: job_id, number: number, merged_at: merged_at, registration: registration)
    publish_manifest(store.project_root, manifest)
    store.enqueue_manifest!(
      manifest,
      policy: { "discovery" => true, "auto_fix" => false, "issue_filing" => false },
      now: T0
    )
  end

  def manifest(job_id:, number:, merged_at:, registration:)
    {
      "schema" => "hive-refactor-patrol-pr-manifest", "schema_version" => 2,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/#{number}", "number" => number,
        "repository" => "acme/demo", "registration" => registration,
        "base_branch" => "main", "base_sha" => "base", "merge_sha" => "merge-#{number}",
        "merged_at" => merged_at.utc.iso8601
      },
      "files" => [ { "path" => "lib/demo.rb", "status" => "modified" } ],
      "changed_paths" => [ "lib/demo.rb" ], "manifest_checksum" => "a" * 64
    }
  end

  def publish_manifest(dir, manifest)
    root = File.join(dir, ".hive-state", "refactor_patrol", "v2", "manifests")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "#{manifest.fetch('job_id')}.json"), JSON.generate(manifest))
  end

  def complete_zero_envelope(entry)
    aggregate = Hive::RefactorPatrol::JobStore.new(entry.fetch("path")).read_job("job-7")
    {
      "schema" => "hive-refactor-patrol", "schema_version" => 2, "ok" => true,
      "job_id" => "job-7", "project" => entry.fetch("name"), "project_root" => entry.fetch("path"),
      "dry_run" => false, "source_pr" => aggregate.fetch("source"), "analysis_sha" => "head",
      "complete" => true, "features_mapped" => 1,
      "accepted" => [], "flagged" => [], "suppressed" => [], "review_errors" => [],
      "zero_reason" => "no_theses", "attempts" => [], "actions" => []
    }
  end
end
