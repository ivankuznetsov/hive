require "test_helper"
require "hive/daemon/pr_merge_watcher"
require "hive/daemon/status_consumer"
require "hive/task_meta"

class HiveDaemonPrMergeWatcherTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 25, 12)

  class FakeGh
    attr_accessor :state, :reachable, :head_oid, :error
    attr_reader :fact_calls

    def initialize(state: "OPEN")
      @state = state
      @reachable = true
      @head_oid = "b" * 40
      @fact_calls = []
    end

    def repository_identity(*, **)
      { "host" => "github.com", "repository" => "acme/app" }
    end

    def closure_default_branch(**)
      "main"
    end

    def ensure_authenticated!(*)
      true
    end

    def closure_pr_facts(host:, repository:, number:, **kwargs)
      @fact_calls << {
        host: host, repository: repository, number: number,
        timeout_sec: kwargs[:timeout_sec]
      }
      raise error if error

      {
        "repository" => repository,
        "number" => number,
        "url" => "https://#{host}/#{repository}/pull/#{number}",
        "state" => state,
        "merged_at" => state == "MERGED" ? T0.iso8601 : "",
        "merge_oid" => state == "MERGED" ? "a" * 40 : "",
        "head_oid" => head_oid,
        "base_ref_name" => "main",
        "reachable_from_default" => state == "MERGED" && reachable
      }
    end

    def closure_commit_facts(oid:, default_branch:, **)
      {
        "oid" => oid,
        "default_branch" => default_branch,
        "comparison" => reachable ? "ahead" : "diverged",
        "reachable_from_default" => reachable
      }
    end
  end

  class FakeClosure
    attr_accessor :error
    attr_reader :calls

    def initialize
      @calls = []
    end

    def reconcile_remote_merge!(**kwargs)
      @calls << kwargs
      raise error if error

      { "receipt_digest" => Digest::SHA256.hexdigest(kwargs.fetch(:pr_url)) }
    end
  end

  class FakeIntake
    attr_accessor :outcomes, :error
    attr_reader :calls

    def initialize
      @outcomes = []
      @calls = []
    end

    def ingest(**kwargs)
      @calls << kwargs
      raise error if error

      outcomes.empty? ? { "job_id" => "job-1", "manifest_digest" => "m" * 64 } : outcomes.shift
    end
  end

  Row = Struct.new(
    :project, :slug, :id, :stage, :workflow, :marker, :marker_attrs, :folder,
    :state_file_mtime, :pr_url, :blocked, :admission_error,
    :condition_task_generation, :commit_generation,
    keyword_init: true
  )

  def test_held_row_does_not_starve_healthy_task
    with_merge_project(stages: %w[6-review 7-artifacts]) do |tasks, _|
      gh = FakeGh.new
      watcher = build_watcher(gh: gh)
      rows = tasks.map { |task| row_for(task) }
      rows.first.blocked = true
      watcher.observe(rows, now: T0)
      assert_equal tasks.last.slug, watcher.tick(now: T0).first[:slug]
      assert watcher.recovery_blocked?(project: "app", slug: tasks.first.slug)
      refute watcher.recovery_blocked?(project: "app", slug: tasks.last.slug)
      assert_equal 1, gh.fact_calls.size
    end
  end

  def test_failure_does_not_starve_siblings_and_is_retried_without_eviction
    with_merge_project(stages: %w[6-review 7-artifacts]) do |tasks, _|
      gh = FakeGh.new
      gh.error = Hive::GhError.new("offline")
      watcher = build_watcher(gh: gh)
      watcher.observe(tasks.map { |task| row_for(task) }, now: T0)
      assert_equal :failed, watcher.tick(now: T0).first[:status]
      assert_equal tasks.last.slug, watcher.tick(now: T0 + 1).first[:slug]
      gh.error = nil
      assert_equal :open, watcher.tick(now: T0 + 2).first[:status]
    end
  end

  def test_restart_rediscovers_task_repolls_github_and_replays_intake_after_closure_failure
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      closure.error = Hive::ConcurrentRunError.new("busy")
      intake = FakeIntake.new
      watcher = build_watcher(gh: gh, task_closure: closure, merge_intake: intake)
      watcher.observe([ row_for(tasks.first) ], now: T0)
      assert_equal :blocked, watcher.tick(now: T0).first[:status]
      closure.error = nil
      restarted = build_watcher(gh: gh, task_closure: closure, merge_intake: intake)
      restarted.observe([ row_for(tasks.first) ], now: T0 + 1)
      assert restarted.recovery_blocked?(project: "app", slug: tasks.first.slug)
      assert_equal :archived, restarted.tick(now: T0 + 1).first[:status]
      assert_equal 2, gh.fact_calls.size
      assert_equal 2, intake.calls.size
      assert_equal 2, closure.calls.size
    end
  end

  def test_restart_resumes_real_closure_receipt_after_crash_before_archive
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      task = tasks.first
      prepare_test_runtime_project(task.project_root, state_home: Hive::Paths.state_home)
      gh = FakeGh.new(state: "MERGED")
      crashing = Object.new
      crashing.define_singleton_method(:reconcile_remote_merge!) do |**kwargs|
        service = Hive::TaskClosure.new(gh: kwargs.delete(:gh), now: kwargs.delete(:now))
        service.define_singleton_method(:transition!) { |*| raise Hive::ConcurrentRunError, "crash before archive" }
        service.reconcile_remote_merge!(**kwargs)
      end
      watcher = build_watcher(gh: gh, task_closure: crashing)
      watcher.observe([ row_for(task) ], now: T0)
      result = watcher.tick(now: T0).first
      assert_equal :failed, result[:status], result.inspect
      assert_includes result[:reason], "crash before archive"
      original = Hive::TaskClosure.read(task, project: "app")
      assert original.valid?

      restarted = build_watcher(gh: gh, task_closure: Hive::TaskClosure)
      restarted.observe([ row_for(task) ], now: T0 + 1)
      assert_equal :archived, restarted.tick(now: T0 + 1).first[:status]
      archived = Hive::TaskResolver.new(task.slug, project_filter: "app").resolve
      assert_equal "9-done", stage_dir(archived)
      assert_equal original.receipt.fetch("receipt_digest"),
                   Hive::TaskClosure.read(archived, project: "app").receipt.fetch("receipt_digest")
    end
  end

  def test_poll_cadence_and_state_are_process_local
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      gh = FakeGh.new
      watcher = build_watcher(gh: gh, poll_interval_sec: 60)
      rows = [ row_for(tasks.first) ]
      watcher.observe(rows, now: T0)
      assert_equal :open, watcher.tick(now: T0).first[:status]
      watcher.observe(rows, now: T0 + 1)
      assert_empty watcher.tick(now: T0 + 1)
      assert_equal "OPEN", watcher.state_for(project: "app", slug: tasks.first.slug)
      gh.state = "CLOSED"
      assert_equal :closed_unmerged, watcher.tick(now: T0 + 60).first[:status]
      refute watcher.recovery_blocked?(project: "app", slug: tasks.first.slug)
      watcher.observe([], now: T0 + 61, projects: [ "app" ])
      assert_nil watcher.state_for(project: "app", slug: tasks.first.slug)
    end
  end

  def test_current_durable_pr_binding_replaces_historical_observation
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      task = tasks.first
      gh = FakeGh.new(state: "MERGED")
      watcher = build_watcher(gh: gh)
      watcher.observe([ row_for(task) ], now: T0)
      path = File.join(task.folder, "pr.md")
      File.write(path, File.read(path).sub("b" * 40, "c" * 40))
      assert_equal :blocked, watcher.tick(now: T0).first[:status]
      gh.head_oid = "c" * 40
      watcher.observe([ row_for(task) ], now: T0 + 1)
      assert_equal :archived, watcher.tick(now: T0 + 1).first[:status]
    end
  end

  def test_open_pr_head_drift_is_polled_and_releases_orphaned_review_recovery
    assert_unmerged_head_drift_releases_recovery("OPEN", :open)
  end

  def test_closed_unmerged_pr_head_drift_releases_orphaned_review_recovery
    assert_unmerged_head_drift_releases_recovery("CLOSED", :closed_unmerged)
  end

  def test_merged_pr_local_head_drift_never_archives
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      task = tasks.first
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      intake = FakeIntake.new
      watcher = build_watcher(gh: gh, task_closure: closure, merge_intake: intake)
      watcher.observe([ row_for(task) ], now: T0)
      with_replaced_singleton_method(Hive::TaskClosure, :local_pr_head_binding, ->(*, **) { "c" * 40 }) do
        result = watcher.tick(now: T0).first
        assert_equal :blocked, result[:status]
        assert_includes result[:reason], "head changed before archival"
      end
      assert_equal 1, gh.fact_calls.length
      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      assert_empty closure.calls
      assert_empty intake.calls
    end
  end

  def test_open_pr_error_before_metadata_creation_is_not_merge_fenced
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _|
      task = tasks.first
      row = row_for(task)
      File.unlink(File.join(task.folder, "pr.md"))
      gh = FakeGh.new
      watcher = build_watcher(gh: gh)
      watcher.observe([ row ], now: T0)
      refute watcher.recovery_blocked?(project: "app", slug: task.slug)
      assert_empty watcher.tick(now: T0)
      Hive::Markers.set(task.state_file, :error, "reason" => "publication failed")
      2.times do |tick|
        results = watcher.observe([ row_for(task) ], now: T0 + tick)
        refute results.any? { |result| result[:status] == :blocked }, results.inspect
        refute watcher.recovery_blocked?(project: "app", slug: task.slug)
        assert_empty watcher.tick(now: T0 + tick)
      end
      assert_empty gh.fact_calls
    end
  end

  def test_existing_invalid_or_unreadable_open_pr_metadata_stays_fenced
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _|
      task = tasks.first
      row = row_for(task)
      watcher = build_watcher
      path = File.join(task.folder, "pr.md")
      File.write(path, "---\npr_url: nonsense\n---\n")
      assert_equal :blocked, watcher.observe([ row ], now: T0).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      File.write(path, "---\npr_url: [\n---\n")
      capture_io do
        assert_equal :blocked, watcher.observe([ row ], now: T0).first[:status]
      end
      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      File.unlink(path)
      Dir.mkdir(path)
      assert_equal :blocked, watcher.observe([ row ], now: T0 + 1).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      assert_empty watcher.tick(now: T0 + 1)
    end
  end

  def test_missing_review_pr_metadata_stays_fenced
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      task = tasks.first
      File.unlink(File.join(task.folder, "pr.md"))
      watcher = build_watcher
      assert_equal :blocked, watcher.observe([ row_for(task) ], now: T0).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      assert_empty watcher.tick(now: T0)
    end
  end

  def test_head_mismatch_missing_binding_and_unreachable_merge_never_archive
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      watcher = build_watcher(gh: gh, task_closure: closure)
      gh.head_oid = "c" * 40
      watcher.observe([ row_for(tasks.first) ], now: T0)
      assert_equal :blocked, watcher.tick(now: T0).first[:status]
      gh.head_oid = "b" * 40
      gh.reachable = false
      assert_equal :failed, watcher.tick(now: T0 + 1).first[:status]
      remove_pr_head(tasks.first)
      watcher.observe([ row_for(tasks.first) ], now: T0 + 2)
      assert_equal :blocked, watcher.tick(now: T0 + 2).first[:status]
      assert_empty closure.calls
    end
  end

  def test_unknown_remote_state_keeps_recovery_fenced
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      watcher = build_watcher(gh: FakeGh.new(state: "MYSTERY"))
      watcher.observe([ row_for(tasks.first) ], now: T0)
      assert_equal :failed, watcher.tick(now: T0).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: tasks.first.slug)
    end
  end

  def test_invalid_pr_metadata_and_project_identity_keep_recovery_fenced
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      watcher = build_watcher(config_lookup: ->(_) { raise Hive::ConfigError, "identity unavailable" })
      assert_equal :blocked, watcher.observe([ row_for(tasks.first) ], now: T0).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: tasks.first.slug)
      assert_empty watcher.tick(now: T0)
      File.write(File.join(tasks.first.folder, "pr.md"), "---\npr_url: nonsense\n---\n")
      watcher = build_watcher
      assert_equal :blocked, watcher.observe([ row_for(tasks.first) ], now: T0).first[:status]
      assert watcher.recovery_blocked?(project: "app", slug: tasks.first.slug)
      refute watcher.recovery_blocked?(project: "app", slug: "missing")
    end
  end

  def test_architecture_pending_blocked_and_failed_intake_defer_closure
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      intake = FakeIntake.new
      closure = FakeClosure.new
      watcher = build_watcher(gh: FakeGh.new(state: "MERGED"), merge_intake: intake, task_closure: closure)
      watcher.observe([ row_for(tasks.first) ], now: T0)
      intake.outcomes = [
        :deferred, { "classification" => { "status" => "pending" } },
        { "classification" => { "status" => "blocked", "occurrence_id" => "x", "snapshot_digest" => "y", "reason" => "no" } }
      ]
      assert_equal :deferred, watcher.tick(now: T0).first[:status]
      assert_equal :deferred, watcher.tick(now: T0 + 1).first[:status]
      assert_equal :blocked, watcher.tick(now: T0 + 2).first[:status]
      assert_empty closure.calls
      intake.error = Hive::Error.new("offline")
      assert_equal :deferred, watcher.tick(now: T0 + 3).first[:status]
      intake.error = nil
      assert_equal :archived, watcher.tick(now: T0 + 4).first[:status]
    end
  end

  def test_dry_run_never_archives
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      closure = FakeClosure.new
      watcher = build_watcher(gh: FakeGh.new(state: "MERGED"), task_closure: closure, dry_run: true)
      watcher.observe([ row_for(tasks.first) ], now: T0)
      assert_equal :dry_run, watcher.tick(now: T0).first[:status]
      assert_empty closure.calls
    end
  end

  def test_real_remote_merge_closure_archives_stage_five_through_eight
    with_merge_project(stages: Hive::Daemon::PrMergeWatcher::SUPPORTED_STAGES) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      watcher = build_watcher(gh: gh, task_closure: Hive::TaskClosure)
      rows = tasks.map { |task| row_for(task) }
      prepare_test_runtime_project(tasks.first.project_root, state_home: Hive::Paths.state_home)
      watcher.observe(rows, now: T0)
      tasks.length.times do |index|
        result = watcher.tick(now: T0 + index).first
        assert_equal :archived, result.fetch(:status), result.inspect
      end

      tasks.each do |task|
        archived = Hive::TaskResolver.new(task.slug, project_filter: "app").resolve
        assert_equal "9-done", stage_dir(archived)
        receipt = JSON.parse(File.read(File.join(archived.folder, "closure.json")))
        assert_equal "daemon", receipt.dig("confirmed_by", "channel")
        assert_equal "remote_merge", receipt.fetch("authority")
      end
    end
  end

  def test_non_github_identity_is_skipped_without_remote_observation
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      gh = FakeGh.new
      gh.define_singleton_method(:repository_identity) do |*, **|
        raise "local registrations must not inspect a GitHub remote"
      end
      [ nil, "local:/tmp/app" ].each do |repository_identity|
        lookup = lambda do |_project|
          registration_for(tasks.first.project_root).merge(
            "repository_identity" => repository_identity
          )
        end
        watcher = build_watcher(gh: gh, config_lookup: lookup)
        result = watcher.observe([ row_for(tasks.first) ], now: T0).first
        assert_equal :skipped, result.fetch(:status)
        assert_match(/not applicable/, result.fetch(:reason))
      end
    end
  end

  def test_constructor_validation
    assert_raises(ArgumentError) { build_watcher(poll_interval_sec: -1) }
    assert_raises(ArgumentError) { build_watcher(poll_timeout_sec: 0) }
  end

  private

  def assert_unmerged_head_drift_releases_recovery(remote_state, expected_status)
    with_merge_project(stages: [ "6-review" ]) do |tasks, _|
      task = tasks.first
      Hive::Markers.set(task.state_file, :review_error,
                        "phase" => "reviewers", "pass" => "1", "reason" => "review_orphaned")
      gh = FakeGh.new(state: remote_state)
      gh.head_oid = "c" * 40
      watcher = build_watcher(gh: gh, poll_interval_sec: 60)
      with_replaced_singleton_method(Hive::TaskClosure, :local_pr_head_binding, ->(*, **) { "c" * 40 }) do
        watcher.observe([ row_for(task) ], now: T0)
        assert watcher.recovery_blocked?(project: "app", slug: task.slug)
        assert_equal expected_status, watcher.tick(now: T0).first[:status]
        refute watcher.recovery_blocked?(project: "app", slug: task.slug)
        watcher.observe([ row_for(task) ], now: T0 + 1)
        refute watcher.recovery_blocked?(project: "app", slug: task.slug)
        assert_empty watcher.tick(now: T0 + 1)
        assert_equal 1, gh.fact_calls.length
      end
    end
  end

  def build_watcher(gh: FakeGh.new, task_closure: FakeClosure.new,
                    merge_intake: nil, poll_interval_sec: 0,
                    poll_timeout_sec: 7, config_lookup: nil, dry_run: false)
    Hive::Daemon::PrMergeWatcher.new(
      poll_interval_sec: poll_interval_sec, poll_timeout_sec: poll_timeout_sec,
      merge_intake: merge_intake, gh: gh,
      config_lookup: config_lookup || Hive::Config.method(:find_project),
      task_closure: task_closure, dry_run: dry_run
    )
  end

  def row_for(task)
    marker = Hive::Markers.current(task.state_file)
    projection = Hive::TaskProjection::Reader.new(task_folder: task.folder).read(marker: marker)
    projection_data = projection.to_h
    Row.new(
      project: "app",
      slug: task.slug,
      id: task.id,
      stage: stage_dir(task),
      workflow: task.workflow.id.to_s,
      marker: marker.name.to_s,
      marker_attrs: marker.attrs,
      folder: task.folder,
      state_file_mtime: File.mtime(task.state_file),
      pr_url: Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"],
      condition_task_generation: projection_data.dig("identity", "task_generation"),
      commit_generation: projection_data.dig("identity", "commit_generation"),
      blocked: false,
      admission_error: nil
    )
  end

  def identity_for(project)
    registration = registration_for(project)
    {
      "registration" => "app",
      "project_path" => project,
      "hive_state_path" => registration.fetch("hive_state_path"),
      "host" => "github.com",
      "repository" => "acme/app",
      "default_branch" => "main"
    }
  end

  def registration_for(project)
    {
      "name" => "app",
      "path" => project,
      "hive_state_path" => File.join(project, ".hive-state"),
      "repository_identity" => "github.com/acme/app"
    }
  end

  def stage_dir(task)
    "#{task.stage_index}-#{task.stage_name}"
  end

  def remove_pr_head(task)
    path = File.join(task.folder, "pr.md")
    File.write(path, File.read(path).sub(/^head_oid:.*\n/, ""))
  end

  def with_merge_project(stages:)
    with_tmp_global_config do |home|
      project = File.join(home, "app")
      FileUtils.mkdir_p(project)
      run!("git", "-C", project, "init", "-b", "main", "--quiet")
      run!("git", "-C", project, "config", "user.email", "test@example.com")
      run!("git", "-C", project, "config", "user.name", "Test")
      run!("git", "-C", project, "config", "commit.gpgsign", "false")
      File.write(File.join(project, "README.md"), "app\n")
      run!("git", "-C", project, "add", "README.md")
      run!("git", "-C", project, "commit", "-m", "initial", "--quiet")
      Hive::GitOps.new(project).hive_state_init
      hive_state = File.join(project, ".hive-state")
      File.write(
        File.join(hive_state, "config.yml"),
        {
          "default_branch" => "main",
          "default_workflow" => "coding",
          "worktree_root" => File.join(home, "worktrees")
        }.to_yaml
      )
      tasks = stages.each_with_index.map do |stage, index|
        slug = "merge-task-#{index}"
        folder = File.join(hive_state, "stages", stage, slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: index + 1, slug: slug, display_name: "Merge #{index}")
        task = Hive::Task.new(folder)
        File.write(task.state_file, "# #{slug}\n")
        File.write(
          File.join(folder, "pr.md"),
          <<~MD
            ---
            pr_url: https://github.com/acme/app/pull/#{index + 40}
            head_oid: #{"b" * 40}
            ---

            Pull request
          MD
        )
        Hive::Markers.set(task.state_file, index.odd? ? :error : :complete,
                          "reason" => "dogfood")
        Hive::TaskProjection::Reader.new(task_folder: folder).read(
          marker: Hive::Markers.current(task.state_file)
        )
        task
      end
      run!("git", "-C", hive_state, "add", ".")
      run!("git", "-C", hive_state, "commit", "-m", "seed merge tasks", "--quiet")
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ registration_for(project) ] }.to_yaml
      )
      yield tasks, home
    end
  end
end
