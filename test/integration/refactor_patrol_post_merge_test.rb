require "test_helper"
require "json"
require "open3"
require "shellwords"
require "hive/daemon/patrol_scheduler"
require "hive/gh"
require "hive/refactor_patrol/post_merge_state_store"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"

class RefactorPatrolPostMergeIntegrationTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 15, 12, 0, 0)

  Snapshot = Struct.new(:root_realpath, :branch, :default_branch, :head_sha, keyword_init: true) do
    def release; end
  end

  class Guard
    def initialize(root)
      @root = root
    end

    def acquire!
      Snapshot.new(root_realpath: File.realpath(@root), branch: "main", default_branch: "main", head_sha: "head")
    end

    def assert_unchanged!(_snapshot)
      true
    end
  end

  Scope = Struct.new(:base) do
    def runnable? = true
    def reason = nil
    def evidence = {}
    def arguments = [ "--changed-since", base, "--path", "lib" ]
    def to_h = { "kind" => "path", "values" => [ "lib" ], "fallback" => true }
  end

  def test_active_batch_drains_distinct_pr_reports_and_keeps_ordinary_state_separate
    with_tmp_dir do |dir|
      entry = { "name" => "hive", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      cfg = Hive::Config.deep_merge(
        Hive::Config.deep_dup(Hive::Config::DEFAULTS),
        "default_branch" => "main",
        "patrol" => { "enabled" => true, "trigger" => "new_commits" },
        "refactor_patrol" => { "enabled" => true }
      )
      ordinary_path = File.join(dir, ".hive-state", "patrol", "state.json")
      FileUtils.mkdir_p(File.dirname(ordinary_path))
      File.write(ordinary_path, "#{JSON.pretty_generate('last_scanned_sha' => 'head')}\n")
      ordinary_before = File.binread(ordinary_path)

      store = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "hive")
      store.initialize_at!(head_sha: "base", now: T0)
      store.open_batch!(
        head_sha: "head",
        merges: [
          { "pr_number" => 10, "merge_sha" => "merge-10", "base_sha" => "base",
            "subject" => "One (#10)", "changed_paths" => [ "lib/one.rb" ] },
          { "pr_number" => 11, "merge_sha" => "head", "base_sha" => "merge-10",
            "subject" => "Two (#11)", "changed_paths" => [ "lib/two.rb" ] }
        ],
        now: T0 + 1
      )
      guard = Guard.new(dir)
      scheduler = scheduler(entry, cfg, store, guard)

      first = scheduler.tick(now: T0 + 2).fetch(0)
      assert_includes first.fetch(:command), "--changed-since base"
      write_thesis(dir, "thesis-10", "fp-10", "lib/one.rb")
      scheduler.complete(
        project: "hive", exit_code: 0, stage: first.fetch(:stage), slug: first.fetch(:slug),
        envelope: envelope(dir, "thesis-10"), now: T0 + 3
      )

      second = scheduler.tick(now: T0 + 4).fetch(0)
      assert_includes second.fetch(:command), "--changed-since merge-10"
      refute_equal first.fetch(:slug), second.fetch(:slug)
      write_thesis(dir, "thesis-11", "fp-11", "lib/two.rb")
      scheduler.complete(
        project: "hive", exit_code: 0, stage: second.fetch(:stage), slug: second.fetch(:slug),
        envelope: envelope(dir, "thesis-11"), now: T0 + 5
      )

      reports = Dir.glob(File.join(store.root, "reports", "*.json")).sort
      assert_equal 2, reports.size
      assert_equal [ 10, 11 ], reports.map { |path| JSON.parse(File.read(path)).fetch("pr_number") }
      assert_equal "head", store.state.fetch("checkpoint_sha")
      assert_empty store.owed_merges
      assert_equal ordinary_before, File.binread(ordinary_path)
    end
  end

  def test_local_subprocess_smoke_discovers_retries_and_reports_without_github
    with_tmp_git_repo do |repo|
      executable = install_fake_hive(repo)
      baseline = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      store = Hive::RefactorPatrol::PostMergeStateStore.new(repo, project: "hive")
      store.initialize_at!(head_sha: baseline, now: T0)

      FileUtils.mkdir_p(File.join(repo, "lib"))
      File.write(File.join(repo, "lib", "one.rb"), "one\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "First architecture change (#10)", "--quiet")
      first_merge = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      File.write(File.join(repo, "lib", "two.rb"), "two\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "Second architecture change (#11)", "--quiet")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      ordinary_path = File.join(repo, ".hive-state", "patrol", "state.json")
      FileUtils.mkdir_p(File.dirname(ordinary_path))
      File.write(ordinary_path, JSON.generate("last_scanned_sha" => baseline))
      entry = { "name" => "hive", "path" => repo, "hive_state_path" => File.join(repo, ".hive-state") }
      cfg = Hive::Config.deep_merge(
        Hive::Config.deep_dup(Hive::Config::DEFAULTS),
        "default_branch" => "master",
        "patrol" => { "enabled" => true, "trigger" => "new_commits" },
        "refactor_patrol" => { "enabled" => true }
      )
      completion = lambda do |token:, state_store:, now:, **|
        state_store.complete!(
          token.fetch("identity"), report: architecture_report(token, now), emission_digests: {}, now: now
        )
      end
      scheduler = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { cfg },
        architecture_store_factory: ->(_entry) { store },
        capability_probe_factory: ->(_entry, _config) do
          Hive::RefactorPatrol::CapabilityProbe.new(executable: executable)
        end,
        scope_factory: ->(_entry, _config) do
          Object.new.tap do |selector|
            selector.define_singleton_method(:select) { |base_sha:, **| Scope.new(base_sha) }
          end
        end,
        fingerprint_loader: ->(_root) { {} }, architecture_completion: completion
      )

      with_replaced_singleton_method(Hive::Gh, :capture3, ->(*) { raise "GitHub must not be called" }) do
        assert_equal [ "hive patrol hive --json" ], scheduler.tick(now: T0 + 1).map { |item| item.fetch(:command) }
        scheduler.complete(project: "hive", exit_code: 0, now: T0 + 2)

        first = scheduler.tick(now: T0 + 3).fetch(0)
        assert_includes first.fetch(:command), "--changed-since #{baseline}"
        _out, _err, status = run_child(first, repo)
        refute status.success?, "the first local child attempt is deliberately interrupted"
        scheduler.complete(project: "hive", exit_code: status.exitstatus, stage: first.fetch(:stage),
                           slug: first.fetch(:slug), now: T0 + 4)

        retry_dispatch = scheduler.tick(now: T0 + 5).fetch(0)
        out, _err, status = run_child(retry_dispatch, repo)
        assert status.success?
        scheduler.complete(project: "hive", exit_code: 0, stage: retry_dispatch.fetch(:stage),
                           slug: retry_dispatch.fetch(:slug), envelope: JSON.parse(out), now: T0 + 6)

        second = scheduler.tick(now: T0 + 7).fetch(0)
        assert_includes second.fetch(:command), "--changed-since #{first_merge}"
        out, _err, status = run_child(second, repo)
        assert status.success?
        scheduler.complete(project: "hive", exit_code: 0, stage: second.fetch(:stage),
                           slug: second.fetch(:slug), envelope: JSON.parse(out), now: T0 + 8)
      end

      assert_equal head, store.state.fetch("checkpoint_sha")
      reports = Dir.glob(File.join(store.root, "reports", "*.json"))
      assert_equal [ 10, 11 ], reports.map { |path| JSON.parse(File.read(path)).fetch("pr_number") }.sort
      first_record = store.merge_record(store.identity_for(10, first_merge))
      assert_equal %w[failed processed], first_record.fetch("attempts").map { |attempt| attempt.fetch("status") }
    end
  end

  private

  def scheduler(entry, cfg, store, guard)
    git = Struct.new(:sha) do
      def default_branch(_root, cfg:) = cfg["default_branch"]
      def rev_parse(_root, _ref) = sha
      def ancestor?(_root, _ancestor, _head) = true
    end.new("head")
    capability = Struct.new(:ok?, :reason, :evidence, :executable).new(true, nil, {}, "/tmp/hive-local")
    Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      git: git,
      architecture_store_factory: ->(_entry) { store },
      checkout_guard_factory: ->(_entry, _config) { guard },
      capability_probe_factory: ->(_entry, _config) { Struct.new(:result) { def call(_root) = result }.new(capability) },
      merge_catalog_factory: ->(_entry) { raise "active batch must not rediscover without a due decision" },
      scope_factory: ->(_entry, _config) do
        Object.new.tap do |selector|
          selector.define_singleton_method(:select) { |base_sha:, **| Scope.new(base_sha) }
        end
      end,
      fingerprint_loader: ->(root) { Hive::RefactorPatrol::StateStore.new(root).fingerprints }
    )
  end

  def envelope(root, thesis_id)
    {
      "schema" => "hive-refactor-patrol",
      "schema_version" => 1,
      "ok" => true,
      "project" => "hive",
      "project_root" => File.realpath(root),
      "dry_run" => false,
      "features_mapped" => 1,
      "theses" => 1,
      "ranked" => [ { "id" => thesis_id } ],
      "flagged_theses" => [],
      "suppressed" => [],
      "last_scanned_sha" => "head"
    }
  end

  def write_thesis(root, id, fingerprint, path)
    Hive::RefactorPatrol::StateStore.new(root).write_thesis(
      Hive::RefactorPatrol::Thesis.new(
        id: id, feature_id: "feature", feature: "Feature", problem: "Problem #{id}",
        cost: "Cost", evidence: [ { "file" => path } ], proposed_refactor: "Extract #{id}",
        feature_boundary: { "owned_files" => [ path ], "entrypoints" => [ path ] },
        expected_leverage: { "score" => 1.0, "breakdown" => { "churn" => 1.0 } },
        confidence: "high", risk: { "flags" => [], "advisories" => [] },
        required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "" },
        admissible: true, admissibility_reason: "evidence-backed",
        follow_up_approval_state: "pending", fingerprint: fingerprint
      )
    )
  end

  def install_fake_hive(repo)
    path = File.join(repo, "bin", "hive")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "fileutils"
      require "json"
      if ARGV[0] == "help"
        puts "hive refactor-patrol PROJECT"
        exit 0
      end
      marker = File.join(Dir.pwd, ".hive-state", "post-merge-smoke-failed-once")
      unless File.exist?(marker)
        FileUtils.mkdir_p(File.dirname(marker))
        File.write(marker, "failed\n")
        exit 75
      end
      puts JSON.generate("schema" => "hive-refactor-patrol", "ok" => true,
                         "project" => ARGV[1], "project_root" => Dir.pwd)
    RUBY
    FileUtils.chmod(0o755, path)
    run!("git", "-C", repo, "add", "bin/hive")
    run!("git", "-C", repo, "commit", "-m", "add local patrol capability", "--quiet")
    path
  end

  def run_child(dispatch, root)
    Open3.capture3(*Shellwords.split(dispatch.fetch(:command)), chdir: root)
  end

  def architecture_report(token, now)
    {
      "completion_status" => "success", "analysis_sha" => token.fetch("pinned_head"),
      "changed_paths" => token.fetch("changed_paths"), "scope" => token.fetch("scope"),
      "totals" => { "accepted" => 0, "flagged" => 0, "suppressed" => 0 },
      "flagged_theses" => [], "emitted_delta" => [], "started_at" => token.fetch("started_at"),
      "completed_at" => now.utc.iso8601
    }
  end
end
