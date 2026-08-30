require "test_helper"
require "digest"
require "json"
require "pty"
require "rbconfig"
require_relative "../../packaging/release_candidate/baseline_catalog"
require_relative "../../packaging/release_candidate/installed_target"
require_relative "../../packaging/release_candidate/upgrade_survivor"

class ReleaseCandidateLatestStableUpgradeTest < Minitest::Test
  include HiveTestHelper
  ROOT = File.expand_path("../..", __dir__).freeze
  CATALOG = File.join(ROOT, "packaging/release_candidate/baselines.yml").freeze
  LATEST_STABLE = HiveReleaseCandidate::BaselineCatalog.load(CATALOG).latest_stable
  BASELINE_VERSION = LATEST_STABLE.version
  BASELINE_GEM_SHA256 = LATEST_STABLE.packages.dig("producer", "artifact", "sha256")
  CANDIDATE_VERSION = Hive::VERSION
  CANDIDATE_GEM_SHA256 = "b" * 64

  def test_runs_latest_stable_named_phases_and_channel_oracle
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", BASELINE_VERSION, BASELINE_GEM_SHA256
        ),
        "candidate" => target(dir, "candidate", CANDIDATE_VERSION, CANDIDATE_GEM_SHA256)
      }
      phases = []
      state = latest_state
      executor = lambda do |target:, phase:, **|
        phases << [ target.role, phase ]
        snapshot = Marshal.load(Marshal.dump(state))
        snapshot["install_identity"]["gem_sha256"] = CANDIDATE_GEM_SHA256 unless phase == "before"
        {
          "status" => "passed", "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot, "stdout" => "#{phase}\n", "stderr" => "",
          "processes" => [], "services" => []
        }
      end
      channel = lambda do |**|
        {
          "status" => "passed", "channel" => "linux-bash",
          "candidate_gem_sha256" => CANDIDATE_GEM_SHA256, "stale_files" => [],
          "wrapper_role" => "candidate", "sidecars_current" => true,
          "dependencies_current" => true
        }
      end

      result = runner(dir, targets, executor, channel).run(
        row_id: "latest-stable", platform: "linux-x86_64"
      )

      assert_equal "passed", result.fetch("status")
      assert_equal(
        [
          %w[baseline before],
          %w[candidate candidate_transition],
          %w[candidate after],
          %w[candidate idempotency]
        ],
        phases
      )
      assert_equal "qa_blocked", result.fetch("qa_status")
      assert_includes result.fetch("blockers"), "remote_validation_required"
      assert_equal "passed", result.dig("channel", "status")
      assert_equal "passed", result.dig("teardown", "status")
    end
  end

  def test_normalizes_phase_diagnostics_before_serializing_evidence
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", BASELINE_VERSION, BASELINE_GEM_SHA256
        ),
        "candidate" => target(dir, "candidate", CANDIDATE_VERSION, CANDIDATE_GEM_SHA256)
      }
      state = latest_state
      executor = lambda do |target:, phase:, **|
        snapshot = Marshal.load(Marshal.dump(state))
        snapshot["install_identity"]["gem_sha256"] = CANDIDATE_GEM_SHA256 unless phase == "before"
        {
          "status" => "passed", "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot, "stdout" => "diagnostic\xFF".b,
          "stderr" => ("e" * 65_535 + "\xE2\x82\xAC").b,
          "processes" => [], "services" => []
        }
      end
      channel = lambda do |**|
        {
          "status" => "passed", "channel" => "linux-bash",
          "candidate_gem_sha256" => CANDIDATE_GEM_SHA256, "stale_files" => [],
          "wrapper_role" => "candidate", "sidecars_current" => true,
          "dependencies_current" => true
        }
      end

      result = runner(dir, targets, executor, channel).run(
        row_id: "latest-stable", platform: "linux-x86_64"
      )

      result.fetch("phases").each do |phase|
        assert_predicate phase.fetch("stdout"), :valid_encoding?
        assert_predicate phase.fetch("stderr"), :valid_encoding?
      end
      assert JSON.generate(result)
    end
  end

  def test_rejects_task_change_non_idempotency_stale_channel_and_fixture_substitution
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", BASELINE_VERSION, BASELINE_GEM_SHA256
        ),
        "candidate" => target(dir, "candidate", CANDIDATE_VERSION, CANDIDATE_GEM_SHA256)
      }
      state = latest_state
      executor = lambda do |target:, phase:, **|
        snapshot = Marshal.load(Marshal.dump(state))
        snapshot["install_identity"]["gem_sha256"] = CANDIDATE_GEM_SHA256 unless phase == "before"
        snapshot["tasks"]["task-7"]["contents"] = "lost" if phase == "after"
        snapshot["configuration"]["second_run"] = true if phase == "idempotency"
        {
          "status" => "passed",
          "producer_kind" => phase == "before" ? "fixture" : "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot, "stdout" => "", "stderr" => "",
          "processes" => [], "services" => []
        }
      end
      channel = ->(**) { { "status" => "failed", "reason" => "stale_channel_files" } }

      result = runner(dir, targets, executor, channel).run(
        row_id: "latest-stable", platform: "linux-x86_64"
      )

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("reasons"), "fixture_cannot_substitute_for_real_producer"
      assert_includes result.fetch("reasons"), "invariant_mismatch"
      assert_includes result.fetch("reasons"), "second_run_not_idempotent"
      assert_includes result.fetch("reasons"), "stale_channel_files"
    end
  end

  def test_unavailable_cache_or_sandbox_never_begins_the_producer
    with_tmp_dir do |dir|
      targets = {
        "baseline" => target(
          dir, "baseline", BASELINE_VERSION, BASELINE_GEM_SHA256
        ),
        "candidate" => target(dir, "candidate", CANDIDATE_VERSION, CANDIDATE_GEM_SHA256)
      }
      calls = 0
      executor = ->(**) { calls += 1 }
      unavailable = HiveReleaseCandidate::UpgradeSurvivor.new(
        catalog: HiveReleaseCandidate::BaselineCatalog.load(CATALOG),
        targets: targets, run_root: File.join(dir, "run"),
        sandbox_contract: {
          "status" => "unavailable", "reason" => "no_engine"
        },
        cache_contract: {
          "status" => "missing", "release_assets_sha256" => nil,
          "verified_dependency_closure_sha256" => nil
        },
        candidate_manifest: {
          "candidate_sha" => "a" * 40,
          "hive_version" => CANDIDATE_VERSION,
          "files" => {
            "hive-cli-#{CANDIDATE_VERSION}.gem" => {
              "kind" => "gem", "sha256" => "b" * 64
            }
          }
        },
        phase_executor: executor, channel_executor: ->(**) { calls += 1 }
      ).run(row_id: "latest-stable", platform: "linux-x86_64")

      assert_equal "unavailable", unavailable.fetch("status")
      assert_equal "disposable_sandbox_unavailable", unavailable.fetch("reason")
      assert_equal 0, calls
      assert_equal(
        [ "bin/hive-release-candidate", "dispatch", "--sha", "a" * 40 ],
        unavailable.fetch("next_action_argv")
      )
    end
  end

  def test_channel_prefix_oracle_rejects_digest_and_stale_file_substitution
    with_tmp_dir do |dir|
      candidate = target(dir, "candidate", "0.6.9", "b" * 64)
      prefix = File.join(dir, "prefix")
      FileUtils.mkdir_p(File.join(prefix, "bin"))
      File.write(File.join(prefix, "bin/hive"), "candidate wrapper\n")
      files = {
        "bin/hive" => {
          "size" => File.size(File.join(prefix, "bin/hive")),
          "sha256" => Digest::SHA256.file(File.join(prefix, "bin/hive")).hexdigest
        }
      }
      manifest = {
        "platform" => "linux-x86_64", "channel" => "linux-bash",
        "candidate_gem_sha256" => "b" * 64, "wrapper_role" => "candidate",
        "sidecars_current" => true, "dependencies_current" => true,
        "stale_files" => [], "files" => files
      }
      File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
      oracle = HiveReleaseCandidate::ChannelPrefixOracle.new

      assert_equal "passed", oracle.verify(
        prefix: prefix, platform: "linux-x86_64", candidate_target: candidate
      ).fetch("status")

      File.write(File.join(prefix, "stale-baseline"), "old")
      error = assert_raises(HiveReleaseCandidate::Error) do
        oracle.verify(prefix: prefix, platform: "linux-x86_64", candidate_target: candidate)
      end
      assert_includes error.message, "stale or substituted"

      FileUtils.rm_f(File.join(prefix, "stale-baseline"))
      manifest["candidate_gem_sha256"] = "f" * 64
      File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
      error = assert_raises(HiveReleaseCandidate::Error) do
        oracle.verify(prefix: prefix, platform: "linux-x86_64", candidate_target: candidate)
      end
      assert_includes error.message, "digest mismatch"
    end
  end

  def test_default_channel_executor_clones_baseline_before_reviewed_update
    with_tmp_dir do |dir|
      baseline = target(dir, "baseline", "0.6.9", "a" * 64)
      candidate = target(dir, "candidate", "0.6.9", "b" * 64)
      File.write(File.join(baseline.root, "baseline-only"), "retire me")
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedChannelExecutor.new(
        targets: { "baseline" => baseline, "candidate" => candidate }
      )
      run_root = File.join(dir, "run")
      FileUtils.mkdir_p(run_root)

      receipt = executor.call(
        row: nil, platform: "linux-x86_64", candidate_target: candidate,
        run_root: run_root
      )

      assert_equal "passed", receipt.fetch("status")
      assert_equal(
        "linux-bash-hive-update",
        receipt.dig("update", "seam")
      )
      assert receipt.fetch("baseline_prefix_files").key?("baseline-only")
      assert_path_exists File.join(receipt.dig("update", "retired_baseline_prefix"), "baseline-only")
      refute_path_exists File.join(run_root, "channel-prefix", "baseline-only")
    end
  end

  def test_default_channel_executor_ignores_the_phase_hive_home_channel_marker
    with_tmp_dir do |dir|
      baseline = target(dir, "baseline", "0.6.9", "a" * 64)
      candidate = target(dir, "candidate", "0.7.0", "b" * 64)
      phase_hive_home = candidate.environment.fetch("HIVE_HOME")
      FileUtils.mkdir_p(phase_hive_home)
      File.write(File.join(phase_hive_home, "install-channel"), "bash\n")
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedChannelExecutor.new(
        targets: { "baseline" => baseline, "candidate" => candidate }
      )
      run_root = File.join(dir, "run")
      FileUtils.mkdir_p(run_root)

      receipt = executor.call(
        row: nil, platform: "linux-x86_64", candidate_target: candidate,
        run_root: run_root
      )

      assert_equal "passed", receipt.fetch("status")
      assert_equal "linux-bash", receipt.fetch("channel")
    end
  end

  def test_extracted_channel_updater_preserves_the_macos_shim_root
    with_tmp_dir do |dir|
      baseline = target(dir, "baseline", "0.6.9", "a" * 64)
      candidate = target(dir, "candidate", "0.6.9", "b" * 64)
      executor = HiveReleaseCandidate::UpgradeSurvivor::FixedChannelExecutor.new(
        targets: { "baseline" => baseline, "candidate" => candidate }
      )
      run_root = File.join(dir, "run")
      FileUtils.mkdir_p(run_root)

      receipt = executor.call(
        row: nil, platform: "macos-arm64", candidate_target: candidate,
        run_root: run_root
      )

      assert_equal "passed", receipt.fetch("status")
      assert_equal "homebrew-local-formula", receipt.fetch("channel")
      assert_equal(
        "macos-homebrew-local-formula-hive-update",
        receipt.dig("update", "seam")
      )
    end
  end

  def test_packaged_previous_update_enters_candidate_confirmation_and_retired_writers_hit_fences
    previous_root = ENV["HIVE_RC_PREVIOUS_RELEASE_TARGET"]
    candidate_root = ENV["HIVE_RC_CANDIDATE_RELEASE_TARGET"]
    skip "CI-only: set both packaged release-candidate target roots" unless
      previous_root && candidate_root

    with_tmp_dir do |dir|
      previous = HiveReleaseCandidate::InstalledTarget.new(
        role: "baseline", root: previous_root, state_root: File.join(dir, "installed-state")
      )
      candidate = HiveReleaseCandidate::InstalledTarget.new(
        role: "candidate", root: candidate_root, state_root: File.join(dir, "installed-state")
      )
      state = File.join(dir, "state")
      data = File.join(dir, "data")
      project = File.join(dir, "project")
      task = File.join(project, ".hive-state", "stages", "1-inbox", "first-task")
      FileUtils.mkdir_p([ state, data, task ])
      File.binwrite(File.join(task, "meta.yml"), "---\nid: 7\nworkflow: coding\n")
      File.binwrite(File.join(task, "idea.md"), "# First task\n")
      projects = [ {
        "name" => "project", "path" => project,
        "hive_state_path" => File.join(project, ".hive-state"),
        "project_id" => "11111111-1111-4111-a111-111111111111",
        "registration_id" => "22222222-2222-4222-a222-222222222222",
        "registered_at" => "2026-08-29T12:00:00.000000Z"
      } ]
      File.binwrite(File.join(state, "config.yml"), YAML.dump("registered_projects" => projects))
      fake_bin = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(fake_bin)
      File.binwrite(File.join(fake_bin, "brew"), "#!/bin/sh\nexit 0\n")
      File.binwrite(File.join(fake_bin, "systemctl"), "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, Dir.glob(File.join(fake_bin, "*")))

      receipt = File.join(dir, "old-update-argv.json")
      driver = <<~RUBY
        require "json"
        require "hive/commands/update"
        calls = []
        begin
          Hive::Commands::Update.new(
            channel: "brew", env: ENV,
            runner: ->(argv) { calls << argv; calls.length == 1 },
            binary_resolver: -> { ENV.fetch("CANDIDATE_HIVE") }
          ).call
        rescue Hive::Error
        end
        File.binwrite(ENV.fetch("ARGV_RECEIPT"), JSON.generate(calls))
        exit(calls.length == 2 ? 0 : 1)
      RUBY
      old_environment = previous.environment.merge(
        "PATH" => "#{fake_bin}:#{previous.environment.fetch('PATH', ENV.fetch('PATH'))}",
        "CANDIDATE_HIVE" => candidate.executable, "ARGV_RECEIPT" => receipt
      )
      _out, error, status = Open3.capture3(
        old_environment, RbConfig.ruby, "-e", driver, unsetenv_others: true
      )
      assert status.success?, error
      old_update_argv = JSON.parse(File.binread(receipt)).last
      assert_equal [ candidate.executable, "migrate", "--all" ], old_update_argv

      environment = candidate.environment.merge(
        "HIVE_HOME" => state, "HOME" => File.join(dir, "home"),
        "PATH" => "#{fake_bin}:#{candidate.environment.fetch('PATH', ENV.fetch('PATH'))}",
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
      )
      FileUtils.mkdir_p(environment.fetch("HOME"))
      _out, refusal, status = Open3.capture3(
        environment, *old_update_argv, unsetenv_others: true
      )
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_includes refusal, "hive migrate --all --yes"

      transcript = ""
      confirmed = false
      exitstatus = nil
      PTY.spawn(environment, *old_update_argv) do |reader, writer, pid|
        begin
          loop do
            transcript << reader.readpartial(4096)
            if !confirmed && transcript.include?("Type 'yes' to continue")
              writer.puts "yes"
              confirmed = true
            end
          end
        rescue EOFError, Errno::EIO
          Process.wait(pid)
          exitstatus = $?.exitstatus
        end
      end
      assert confirmed, transcript
      assert_equal 0, exitstatus, transcript
      assert_path_exists Hive::Paths.runtime_control_plane_path(state)

      inventory = YAML.safe_load_file(
        File.join(ROOT, "test/fixtures/runtime_control_plane/affected_production.yml")
      )
      probes = previous_writer_probes
      fence_paths = previous_writer_fence_paths(state, data, project, task)
      assert_equal inventory.fetch("legacy_writers").sort, probes.keys.sort
      assert_equal probes.keys.sort, fence_paths.keys.sort
      writer_environment = previous.environment.merge(
        "HIVE_HOME" => state, "HOME" => environment.fetch("HOME"),
        "HIVE_ATTEMPT_STORE_ROOT" => File.join(state, "attempts", "v4"),
        "HIVE_USAGE_DB_PATH" => File.join(data, "usage.db"),
        "PROJECT_ROOT" => project, "TASK_FOLDER" => task
      )
      assert_equal inventory.fetch("path_overrides").sort,
                   %w[HIVE_ATTEMPT_STORE_ROOT HIVE_USAGE_DB_PATH].select { |key| writer_environment[key] }.sort
      probes.each do |writer, operation|
        before = release_tree_snapshot(dir)
        stdout, stderr, status = Open3.capture3(
          writer_environment, RbConfig.ruby, "-e", previous_writer_script(operation),
          unsetenv_others: true
        )
        receipt = JSON.parse(stdout.lines.last)
        if status.exitstatus == 77
          assert_equal "Hive::Patrol::LaunchBudget", writer
          assert_equal "LoadError", receipt.fetch("error")
        else
          assert_equal 73, status.exitstatus, "#{writer}: #{stderr}"
          refute_equal "writer unexpectedly completed", receipt.fetch("message")
          refute_match(/(?:ArgumentError|KeyError|LoadError|NameError|NoMethodError)\z/,
                       receipt.fetch("error"), writer)
          assert_match(/\A(?:Errno::[A-Z0-9_]+|(?:Hive::|SQLite3::|Sequel::).*(?:Error|Exception))\z/,
                       receipt.fetch("error"), writer)
          diagnostic = "#{receipt.fetch('message')}\n#{stderr}"
          assert fence_paths.fetch(writer).any? { |path| diagnostic.include?(path) },
                 "#{writer} did not identify a fenced path: #{diagnostic}"
        end
        assert_equal before, release_tree_snapshot(dir), writer
      end
    end
  end

  private

  def previous_writer_script(operation)
    <<~RUBY
      require "json"
      begin
        #{operation}
        raise "writer unexpectedly completed"
      rescue Exception => error
        puts JSON.generate("error" => error.class.name, "message" => error.message)
        exit(error.is_a?(LoadError) ? 77 : 73)
      end
    RUBY
  end

  def previous_writer_probes
    attempt_root = 'ENV.fetch("HIVE_ATTEMPT_STORE_ROOT")'
    {
      "Hive::Attempts::Store" =>
        "require 'hive/attempts/store'; Hive::Attempts::Store.new(root: #{attempt_root})",
      "Hive::Attempts::DecisionIndex" =>
        "require 'hive/attempts/decision_index'; Hive::Attempts::DecisionIndex.new(root: File.join(#{attempt_root}, 'decision-indexes'))",
      "Hive::Attempts::FinalizationMaintenance" => <<~RUBY,
        require 'hive/attempts/finalization_maintenance'
        store = Hive::Attempts::Store.new(root: #{attempt_root}, create_directories: false)
        Hive::Attempts::FinalizationMaintenance.new(store: store).run_if_due
      RUBY
      "Hive::Daemon::DispatchRequestQueue" => <<~RUBY,
        require 'hive/daemon/dispatch_request_queue'
        Hive::Daemon::DispatchRequestQueue.write_request!(project: 'project', slug: 'first-task', argv: ['status'])
      RUBY
      "Hive::Daemon::DispatchResultQueue" => <<~RUBY,
        require 'hive/daemon/dispatch_result_queue'
        Hive::Daemon::DispatchResultQueue.write!(chat_id: '1', project: 'project', slug: 'first-task', request_id: 'r', exit_code: 0, command: 'status')
      RUBY
      "Hive::Daemon::OperationalSnapshot::Store" =>
        "require 'hive/daemon/operational_snapshot'; Hive::Daemon::OperationalSnapshot::Store.new.write({})",
      "Hive::Daemon::PrMergeReconciliationStore" => <<~RUBY,
        require 'hive/daemon/pr_merge_reconciliation_store'
        identity = { 'hive_state_path' => File.join(ENV.fetch('PROJECT_ROOT'), '.hive-state') }
        Hive::Daemon::PrMergeReconciliationStore.new.transaction(identity) { }
      RUBY
      "Hive::ProviderHealth::Store" =>
        "require 'hive/provider_health/store'; Hive::ProviderHealth::Store.new(root: File.join(ENV.fetch('HIVE_HOME'), 'provider-health', 'v1'))",
      "Hive::ProviderRouting::PolicyStore" => <<~RUBY,
        require 'hive/provider_routing/policy_store'
        Hive::ProviderRouting::PolicyStore.new(root: File.join(#{attempt_root}, 'routing-policies')).fetch_snapshot(ownership_generation: 'g', subject: { 'kind' => 'task' })
      RUBY
      "Hive::Lock" =>
        "require 'hive/lock'; Hive::Lock.acquire_task_lock(ENV.fetch('TASK_FOLDER'))",
      "Hive::TaskCounter" =>
        "require 'hive/task_counter'; Hive::TaskCounter.next!",
      "Hive::Patrol::LaunchBudget" => <<~RUBY,
        require 'hive/patrol/launch_budget'
        budget = Hive::Patrol::LaunchBudget.new(ENV.fetch('PROJECT_ROOT'), cfg: { 'patrol' => { 'mode' => 'auto' } }, ledger_path: ENV.fetch('HIVE_USAGE_DB_PATH') + '.patrol-discovery-allowances')
        budget.reserve_discovery!(engine: :ordinary, started_at: Time.now.utc, reservation_id: 'old-writer')
      RUBY
      "Hive::UsageDb" => <<~RUBY
        require 'hive/usage_db'
        ok = Hive::UsageDb.record!(agent: :codex, model: 'old', project_slug: 'project', task_slug: 'first-task', stage: 'execute', started_at: Time.now.utc, ended_at: Time.now.utc, input: 1, output: 1, cached: 0)
        raise Errno::EISDIR, Hive::UsageDb.path unless ok
      RUBY
    }
  end

  def previous_writer_fence_paths(state, data, project, task)
    attempts = File.join(state, "attempts")
    {
      "Hive::Attempts::Store" => [ attempts ],
      "Hive::Attempts::DecisionIndex" => [ attempts ],
      "Hive::Attempts::FinalizationMaintenance" => [ attempts ],
      "Hive::Daemon::DispatchRequestQueue" => [ File.join(state, "dispatch_requests") ],
      "Hive::Daemon::DispatchResultQueue" => [ File.join(state, "dispatch_results") ],
      "Hive::Daemon::OperationalSnapshot::Store" => [ File.join(state, "operational") ],
      "Hive::Daemon::PrMergeReconciliationStore" => [
        File.join(project, ".hive-state", "daemon", "pr-merge-reconciliation.json.lock"),
        File.join(project, ".hive-state", "daemon", "pr-merge-reconciliation.json")
      ],
      "Hive::ProviderHealth::Store" => [ File.join(state, "provider-health") ],
      "Hive::ProviderRouting::PolicyStore" => [ attempts ],
      "Hive::Lock" => [ File.join(task, ".lock.tmp.guard"), File.join(task, ".lock") ],
      "Hive::TaskCounter" => [
        File.join(state, ".task-counter.lock"), File.join(state, "task-counter.yml")
      ],
      "Hive::Patrol::LaunchBudget" => [ File.join(data, "usage.db.patrol-discovery-allowances") ],
      "Hive::UsageDb" => [ File.join(data, "usage.db") ]
    }
  end

  def release_tree_snapshot(root)
    Digest::SHA256.hexdigest(
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next if %w[. ..].include?(File.basename(path))
        relative = path.delete_prefix("#{root}/")
        status = File.lstat(path)
        status.file? ? "f\0#{relative}\0#{status.mode}\0#{File.binread(path)}" :
          "d\0#{relative}\0#{status.mode}"
      end.join("\0")
    )
  end

  def runner(dir, targets, executor, channel)
    HiveReleaseCandidate::UpgradeSurvivor.new(
      catalog: HiveReleaseCandidate::BaselineCatalog.load(CATALOG),
      targets: targets, run_root: File.join(dir, "run"),
      sandbox_contract: {
        "status" => "available", "kind" => "container",
        "network_after_staging" => "none"
      },
      cache_contract: {
        "status" => "available", "release_assets_sha256" => "d" * 64,
        "verified_dependency_closure_sha256" => "e" * 64
      },
      candidate_manifest: {
        "candidate_sha" => "a" * 40,
        "hive_version" => targets.fetch("candidate").manifest.fetch("version"),
        "files" => {
          "hive-cli-#{targets.fetch("candidate").manifest.fetch("version")}.gem" => {
            "kind" => "gem",
            "sha256" => targets.fetch("candidate").manifest.fetch("gem_sha256")
          }
        }
      },
      phase_executor: executor, channel_executor: channel
    )
  end

  def target(dir, role, version, digest)
    root = File.join(dir, role)
    FileUtils.mkdir_p(File.join(root, "bin"))
    body = if role == "candidate"
             <<~BASH
               #!/usr/bin/env bash
               set -euo pipefail
               if [[ "${1:-}" == "update" ]]; then
                 if [[ -f "${HIVE_HOME:?}/install-channel" ]]; then
                   exec "${HIVE_RC_CONTROL_ROOT:?}/channel_update_fixture.sh"
                 fi
                 exec "${HIVE_RC_CONTROL_ROOT:?}/channel_update_fixture.sh" \
                   "--prefix=${HIVE_RC_CHANNEL_PREFIX:?}"
               fi
               exit 0
             BASH
    else
             "#!/bin/sh\nexit 0\n"
    end
    File.write(File.join(root, "bin/hive"), body)
    File.chmod(0o755, File.join(root, "bin/hive"))
    File.write(File.join(root, "target.json"), JSON.generate(
      "schema" => "hive-release-candidate-installed-target",
      "schema_version" => 1, "role" => role, "version" => version,
      "gem_sha256" => digest, "executable" => "bin/hive",
      "skills" => { "archive_sha256" => "c" * 64, "import_root" => "skills" }
    ))
    HiveReleaseCandidate::InstalledTarget.new(
      role: role, root: root, state_root: File.join(dir, "state")
    )
  end

  def latest_state
    {
      "global_registry" => { "projects" => [ "project" ] },
      "project_registry" => { "path" => "/run/project" },
      "configuration" => { "daemon" => false },
      "default_workflow" => "coding",
      "tasks" => {
        "task-7" => {
          "id" => 7, "slug" => "representative-260727-abcd",
          "stage" => "4-execute", "contents" => "keep"
        }
      },
      "dependencies" => { "task-7" => [] },
      "markers" => { "task-7" => "WAITING" },
      "durable_attempts" => { "attempt-1" => "terminal" },
      "dispatch_receipts" => { "attempt-1" => "accepted" },
      "channel_sidecars" => { "channel" => "linux-bash" },
      "managed_web_data" => { "database" => "keep" },
      "service_definitions" => { "hive-web" => "inert" },
      "doctor_json" => { "schema" => "hive-doctor", "healthy" => true },
      "install_identity" => { "gem_sha256" => "a" * 64 }
    }
  end
end
