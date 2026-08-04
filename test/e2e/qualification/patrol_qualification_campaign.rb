require "digest"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "time"
require "timeout"
require "tmpdir"
require "yaml"
require "hive/daemon/operational_snapshot"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/process_kill"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/runtime_policy"
require_relative "../lib/background_process"
require_relative "../lib/cli_driver"
require_relative "../lib/gh_stub"
require_relative "../lib/module_scenario_support"
require_relative "../lib/paths"
require_relative "../lib/patrol_public_evidence_collector"
require_relative "../lib/sandbox"

module Hive
  module E2E
    # Explicit, pre-release Patrol qualification. This is intentionally not a
    # default E2E scenario: it runs real CLI children and owned daemon process
    # groups against one isolated repository, then verifies persisted evidence
    # through the U3a public receipt/admission facades.
    class PatrolQualificationCampaign
      CATALOG_PATH =
        "test/e2e/fixtures/patrol_qualification/catalog.json".freeze
      CAMPAIGN_PATH =
        "test/e2e/qualification/patrol_qualification_campaign.rb".freeze
      SOURCE_PATHS = %w[
        lib/hive/modules/adapters/architecture_patrol.rb
        lib/hive/modules/adapters/patrol.rb
        lib/hive/modules/migration/patrols.rb
      ].freeze
      MANIFEST_PATHS = %w[
        modules/architecture-patrol/manifest.yml
        modules/patrol/manifest.yml
      ].freeze
      MODULES = %w[architecture-patrol patrol].freeze
      REPOSITORY_ID = "github.com/acme/hive-e2e".freeze
      REPOSITORY_NAME = "acme/hive-e2e".freeze
      REVIEWER = "hive-e2e/u3b".freeze
      RUN_TIMEOUT = 300.0
      WAIT_TIMEOUT = 30.0
      CLI_TIMEOUT = 20.0
      DAEMON_STOP_GRACE = 3.0
      CLEANUP_TERM_GRACE = 0.5
      MAX_EVIDENCE_BYTES = 512 * 1024
      CATALOG_KEYS = %w[cases schema schema_version].freeze
      CASE_KEYS = %w[decision_class id mode module].freeze

      def run!
        @deadline = monotonic + RUN_TIMEOUT
        candidate_sha = clean_candidate!
        catalog_bytes = committed_control(CATALOG_PATH)
        catalog = parse_catalog(catalog_bytes)

        run_dir = Dir.mktmpdir("hive-patrol-qualification")
        succeeded = false
        begin
          setup(run_dir)
          ordinary = run_ordinary(catalog.fetch("cases").first(10))
          architecture = run_architecture(catalog.fetch("cases").last(10))
          records = ordinary + architecture
          report = qualify!(records, catalog_bytes, candidate_sha)
          proof = proof_for(report, records, candidate_sha)
          @gh_stub.verify!
          verify_fake_agent_isolation!
          succeeded = true
          proof
        ensure
          stop_daemon
          cleanup_run_dir(run_dir) if succeeded
        end
      end

      private

      def setup(run_dir)
        @sandbox = Sandbox.bootstrap(run_dir)
        @project_root = @sandbox.sandbox_dir
        @run_home = @sandbox.run_home
        @project = File.basename(@project_root)
        @cli = CliDriver.new(@project_root, @run_home)
        configure_remote!(run_dir)
        refresh_registered_identity!
        configure_global_daemon!
        configure_project!
        ModuleScenarioSupport.fresh_install!(
          sandbox: @project_root,
          run_home: @run_home,
          configurations: {
            "patrol" => {
              "settings" => {
                "shadow_mode" => true,
                "trigger" => "timer",
                "poll_interval_sec" => 60,
                "dry_run" => false
              },
              "hooks" => { "scheduled-scan" => true }
            },
            "architecture-patrol" => {
              "settings" => { "shadow_mode" => true, "dry_run" => false },
              "hooks" => { "scheduled-discovery" => true }
            }
          },
          project_id: @project_id
        )
        @gh_stub = GhStub.new(@run_home)
      end

      def configure_remote!(run_dir)
        origin = File.join(run_dir, "origin.git")
        run_git("init", "--bare", "--quiet", origin, root: nil)
        @git_ssh_proxy = write_git_ssh_proxy(run_dir, origin)
        run_git("config", "core.sshCommand", @git_ssh_proxy)
        run_git("config", "ssh.variant", "ssh")
        run_git(
          "remote", "add", "origin",
          "git@github.com:acme/hive-e2e.git"
        )
        run_git("push", "-u", "origin", "master", "--quiet")
        unless run_git("remote", "get-url", "origin").strip ==
               "git@github.com:acme/hive-e2e.git"
          raise "qualification repository did not retain its GitHub identity"
        end
      end

      def write_git_ssh_proxy(run_dir, origin)
        path = File.join(run_dir, "ssh")
        escaped = Shellwords.escape(origin)
        body = <<~SH
          #!/bin/sh
          case "$*" in
            *"git-upload-pack 'acme/hive-e2e.git'"*)
              exec git-upload-pack #{escaped}
              ;;
            *"git-receive-pack 'acme/hive-e2e.git'"*)
              exec git-receive-pack #{escaped}
              ;;
          esac
          exit 65
        SH
        File.binwrite(path, body)
        File.chmod(0o700, path)
        path
      end

      # Sandbox bootstrap registers the project before a remote can exist.
      # Refresh only that immutable registry fact after proving the real Git
      # remote above; all later ownership checks still inspect the repository.
      def refresh_registered_identity!
        path = File.join(@run_home, "config.yml")
        config = YAML.safe_load(File.binread(path)) || {}
        rows = config.fetch("registered_projects")
        row = rows.find { |entry| entry.fetch("path") == @project_root }
        raise "qualification project registration is unavailable" unless row

        row["repository_identity"] = REPOSITORY_ID
        @project_id = row.fetch("project_id")
        File.binwrite(path, config.to_yaml)
      end

      def configure_global_daemon!
        path = File.join(@run_home, "config.yml")
        config = YAML.safe_load(File.binread(path)) || {}
        config["daemon"] = (config["daemon"] || {}).merge(
          "poll_interval_sec" => 5,
          "fast_poll_sec" => 1,
          "max_concurrent_runs" => 4,
          "max_concurrent_per_project" => 4,
          "max_concurrent_patrol_scans" => 2,
          "child_timeout_sec" => 20,
          "child_kill_grace_sec" => 1,
          "shutdown_grace_sec" => 1
        )
        File.binwrite(path, config.to_yaml)
      end

      def configure_project!
        update_project_config do |config|
          config["daemon"] ||= {}
          config["daemon"]["enabled"] = true
          config["patrol"] ||= {}
          config["patrol"].merge!(
            "enabled" => true,
            "trigger" => "timer",
            "poll_interval_sec" => 600,
            "max_features_per_cycle" => 5,
            "max_findings_per_feature" => 1,
            "max_fix_attempts_per_cycle" => 1,
            "max_agent_spawns_per_cycle" => 6,
            "max_architecture_review_spawns_per_day" => 20,
            "commands" => { "test" => "bundle exec rake test" }
          )
          config["refactor_patrol"] ||= {}
          config["refactor_patrol"].merge!(
            "enabled" => false,
            "include" => [ "lib/sample.rb" ],
            "max_theses_per_feature" => 1
          )
        end
      end

      def run_ordinary(cases)
        contexts = []
        used_windows = []
        cases.each_with_index do |row, index|
          check_deadline!
          commit_ordinary_window! if index == 5
          configure_ordinary_case!(row, unique_ordinary_interval(used_windows))
          before = comparable_records("patrol").map do |record|
            record.fetch("decision_id")
          end
          start_daemon("ordinary-#{index + 1}")
          wait_for_shadowing!
          record = wait_until("ordinary Patrol comparison") do
            fresh = comparable_records("patrol").reject do |candidate|
              before.include?(candidate.fetch("decision_id"))
            end
            fresh.one? && fresh.first
          end
          stop_daemon
          rationale = record.dig("module_decision", "rationale")
          unless rationale == row.fetch("decision_class")
            raise "ordinary Patrol observed #{rationale.inspect}, expected #{row.fetch('decision_class').inspect}"
          end
          window = record.dig(
            "legacy_capture", "reservation", "window_started_at"
          )
          raise "ordinary Patrol reused a schedule window" if used_windows.include?(window)
          used_windows << window
          contexts << {
            row: row,
            record: record,
            repository_sha: git_head,
            change_window: window,
            fault_steps: ordinary_fault_steps(record)
          }
        ensure
          stop_daemon
        end
        contexts
      end

      def configure_ordinary_case!(row, interval)
        update_project_config do |config|
          patrol = config.fetch("patrol")
          patrol["enabled"] = row.fetch("mode") != "disabled"
          patrol["trigger"] = "timer"
          patrol["poll_interval_sec"] = interval
        end
      end

      def unique_ordinary_interval(used_windows)
        now = Time.now.utc
        horizon = now + WAIT_TIMEOUT + 5
        (600..7_200).find do |interval|
          window = ordinary_window(now, interval)
          window == ordinary_window(horizon, interval) &&
            !used_windows.include?(window)
        end || raise("no stable ordinary Patrol schedule window is available")
      end

      def ordinary_window(time, interval)
        Time.at(time.to_i - (time.to_i % interval)).utc.iso8601(6)
      end

      def commit_ordinary_window!
        path = File.join(@project_root, "lib", "sample.rb")
        File.open(path, "a") do |file|
          file.puts "# qualification ordinary repository window"
        end
        commit_and_push!("test: advance ordinary qualification window")
      end

      def ordinary_fault_steps(record)
        outcome = record.dig("legacy_capture", "outcome") || {}
        if record.dig("legacy_capture", "outcome_class") == "completed" &&
           outcome["ok"] == true && outcome["review_complete"] == true
          [ "daemon_child_completed" ]
        elsif record.dig("legacy_capture", "outcome_class") ==
              "not_dispatched"
          [ "scheduler_negative_finalized" ]
        else
          raise "ordinary Patrol did not produce a terminal public outcome"
        end
      end

      def run_architecture(cases)
        contexts, interactions = prepare_architecture_cases(cases)
        @gh_stub.install(interactions)
        contexts.each_with_index do |context, index|
          update_project_config do |config|
            config.fetch("refactor_patrol")["enabled"] = true
          end
          row = context.fetch(:row)
          if row.fetch("mode") == "retry"
            first = run_architecture_cli(
              context.fetch(:pr_number), output: '{"bad":[]}'
            )
            raise "Architecture Patrol retry control unexpectedly completed" if
              first.fetch("complete")
          end
          final = run_architecture_cli(
            context.fetch(:pr_number), output: '{"theses":[]}'
          )
          raise "Architecture Patrol did not complete" unless final.fetch("complete")

          context[:job_id] = final.fetch("job_id")
          job = show_architecture_job(context.fetch(:job_id))
          attempts = job.fetch("attempts").select do |attempt|
            attempt.fetch("kind") == "discovery_claim"
          end
          released = attempts.any? { |attempt| attempt.fetch("state") == "released" }
          context[:decision_class] = released ? "manual_recovered" : "manual_complete"
          context[:fault_steps] = released ? [ "released_attempt_retried" ] : []
          unless context.fetch(:decision_class) == row.fetch("decision_class")
            raise "Architecture Patrol retry evidence diverged from the catalogue"
          end
          update_project_config do |config|
            config.fetch("refactor_patrol")["enabled"] = false
          end
          start_daemon("architecture-#{index + 1}")
          wait_for_shadowing!
          context[:record] = wait_until("Architecture Patrol comparison") do
            comparable_records("architecture-patrol").find do |record|
              record.dig("legacy_capture", "reservation", "job_id") ==
                context.fetch(:job_id)
            end
          end
          stop_daemon
        end
        contexts
      ensure
        stop_daemon
        update_project_config do |config|
          config.fetch("refactor_patrol")["enabled"] = false
        end if @project_root
      end

      def prepare_architecture_cases(cases)
        contexts = []
        interactions = []
        cases.each_with_index do |row, index|
          base_sha = git_head
          path = File.join(@project_root, "lib", "sample.rb")
          File.open(path, "a") do |file|
            file.puts "# qualification architecture case #{index + 1}"
          end
          commit_and_push!("test: architecture qualification case #{index + 1}")
          merge_sha = git_head
          pr_number = 700 + index + 1
          repeats = row.fetch("mode") == "retry" ? 2 : 1
          repeats.times do
            interactions.concat(
              architecture_interactions(
                pr_number:, base_sha:, merge_sha:, index:
              )
            )
          end
          contexts << {
            row: row,
            pr_number: pr_number,
            repository_sha: merge_sha,
            change_window: "#{base_sha}..#{merge_sha}"
          }
        end
        [ contexts, interactions ]
      end

      def architecture_interactions(pr_number:, base_sha:, merge_sha:, index:)
        metadata = {
          "number" => pr_number,
          "url" => "https://github.com/#{REPOSITORY_NAME}/pull/#{pr_number}",
          "state" => "MERGED",
          "baseRefName" => "master",
          "baseRefOid" => base_sha,
          "mergeCommit" => { "oid" => merge_sha },
          "mergedAt" => (
            ModuleScenarioSupport::START + 86_400 + (index * 60)
          ).iso8601,
          "changedFiles" => 1
        }
        [
          {
            "args" => [ "auth", "status", "--hostname", "github.com" ],
            "stdout" => ""
          },
          {
            "args" => [
              "pr", "view", pr_number.to_s,
              "--repo", REPOSITORY_ID,
              "--json",
              "number,url,state,baseRefName,baseRefOid,mergeCommit,mergedAt,changedFiles"
            ],
            "response" => metadata
          },
          {
            "args" => [
              "api", "repos/#{REPOSITORY_NAME}/pulls/#{pr_number}/files?per_page=100",
              "--hostname", "github.com", "--paginate", "--slurp"
            ],
            "response" => [
              [ { "filename" => "lib/sample.rb", "status" => "modified" } ]
            ]
          }
        ]
      end

      def run_architecture_cli(pr_number, output:)
        agent_output = JSON.generate("type" => "result", "result" => output)
        result = @cli.call(
          [ "refactor-patrol", @project, "--pr", pr_number, "--json" ],
          timeout: command_timeout,
          env_overrides: {
            "PATH" => "#{File.dirname(@git_ssh_proxy)}:#{ENV.fetch('PATH', '')}",
            "GIT_SSH_COMMAND" => @git_ssh_proxy,
            "GIT_SSH_VARIANT" => "ssh",
            "HIVE_FAKE_CLAUDE_OUTPUT" => agent_output,
            "HIVE_FAKE_CLAUDE_LOG_DIR" =>
              File.join(@run_home, "fake-claude"),
            "ANTHROPIC_API_KEY" => nil,
            "CLAUDE_API_KEY" => nil
          }
        )
        JSON.parse(result.stdout)
      rescue JSON::ParserError
        raise "Architecture Patrol CLI output was not JSON"
      end

      def show_architecture_job(job_id)
        result = @cli.call(
          [
            "refactor-patrol", @project, "--show", job_id,
            "--full", "--json"
          ],
          timeout: command_timeout
        )
        JSON.parse(result.stdout).fetch("job")
      rescue JSON::ParserError, KeyError
        raise "Architecture Patrol job evidence was not available through CLI"
      end

      def qualify!(contexts, catalog_bytes, candidate_sha)
        common = common_bindings(catalog_bytes, candidate_sha)
        collector = PatrolPublicEvidenceCollector.new(common: common)
        receipts = []
        bindings = []
        contexts.each do |context|
          record = context.fetch(:record)
          generated_at = record.fetch("recorded_at")
          reviewed_at = (Time.iso8601(generated_at) + 1).iso8601(6)
          prepared = collector.prepare(
            record: record,
            repository: {
              "id" => REPOSITORY_ID,
              "sha" => context.fetch(:repository_sha),
              "change_window" => context.fetch(:change_window)
            },
            decision_class:
              context[:decision_class] || context.dig(:row, "decision_class"),
            fault_steps: context.fetch(:fault_steps),
            generated_at: generated_at,
            reviewed_at: reviewed_at
          )
          observed =
            Hive::Modules::Migration::Patrols.deterministic_receipt_for!(
              @project_root,
              selector: {
                "module" => record.fetch("module"),
                "trigger_id" => record.fetch("trigger").fetch("id")
              },
              metadata: receipt_metadata(prepared.document),
              hive_state_path: state_path
            )
          receipts << collector.accept!(prepared, observed)
          bindings << prepared.bindings
        end

        build_and_migrate_report!
        path = report_path
        digest = Digest::SHA256.hexdigest(File.binread(path))
        Hive::Modules::Migration::Patrols.admit_deterministic_qualification!(
          @project_root,
          receipts: receipts,
          expected_bindings: bindings,
          generated_at: Time.now.utc,
          expected_report_digest: digest,
          hive_state_path: state_path
        )
      ensure
        stop_daemon
      end

      def receipt_metadata(document)
        document.slice(
          "artifacts", "candidate_sha", "catalog_digest",
          "configuration_digest", "decision_class", "fault_steps",
          "generated_at", "manifest_digest", "repository", "reviewed_at",
          "reviewer", "run_id", "scenario_manifest_digest", "source_digest"
        )
      end

      def build_and_migrate_report!
        result = @cli.call(
          %w[module migration report --reviewer hive-e2e/u3b --yes --json],
          timeout: command_timeout
        )
        payload = JSON.parse(result.stdout)
        unless payload.fetch("schema") == "hive-module-migration-report" &&
               payload.fetch("schema_version") == 1
          raise "migration report CLI did not emit its legacy input"
        end
        start_daemon("report-migration")
        wait_until("migration report v2 conversion") do
          next false unless File.file?(report_path)

          JSON.parse(File.binread(report_path))["schema_version"] == 2
        rescue JSON::ParserError
          false
        end
      rescue JSON::ParserError, KeyError
        raise "migration report CLI output was not parseable"
      ensure
        stop_daemon
      end

      def common_bindings(catalog_bytes, candidate_sha)
        catalog_digest = Digest::SHA256.hexdigest(catalog_bytes)
        source_digest = digest_paths(SOURCE_PATHS)
        {
          "run_id" => "u3b-#{candidate_sha[0, 12]}",
          "candidate_sha" => candidate_sha,
          "catalog_digest" => catalog_digest,
          "source_digest" => source_digest,
          "manifest_digest" => digest_paths(MANIFEST_PATHS),
          "scenario_manifest_digest" => Digest::SHA256.hexdigest(
            catalog_bytes + committed_control(CAMPAIGN_PATH)
          ),
          "artifacts" => [
            { "kind" => "catalog", "digest" => catalog_digest },
            { "kind" => "candidate-source", "digest" => source_digest }
          ],
          "reviewer" => REVIEWER
        }.freeze
      end

      def proof_for(report, contexts, candidate_sha)
        qualification = report.lanes.fetch("deterministic")
        unless qualification.qualified? &&
               MODULES.all? do |module_name|
                 qualification.modules.dig(module_name, "decision_count") == 10
               end &&
               qualification.duplicate_effects.empty? &&
               qualification.unsettled_effects.empty?
          raise "Patrol public-process evidence did not qualify"
        end
        {
          "schema" => "hive-e2e-patrol-public-process-proof",
          "schema_version" => 1,
          "status" => "deterministic_proof_ready",
          "candidate_sha" => candidate_sha,
          "qualification_id" => qualification.qualification_id,
          "cases" => contexts.size,
          "modules" => qualification.modules,
          "effect_count" => qualification.effect_count,
          "report_digest" => Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(report.to_h)
          )
        }
      end

      def parse_catalog(bytes)
        catalog = JSON.parse(bytes)
        valid = catalog.is_a?(Hash) && catalog.keys.sort == CATALOG_KEYS &&
          catalog["schema"] == "hive-patrol-public-process-catalog" &&
          catalog["schema_version"] == 1 &&
          catalog["cases"].is_a?(Array) && catalog["cases"].size == 20
        raise "Patrol qualification catalogue is malformed" unless valid

        ids = catalog.fetch("cases").map do |row|
          validate_case!(row)
          row.fetch("id")
        end
        raise "Patrol qualification case IDs are not unique" unless ids.uniq == ids
        counts = catalog.fetch("cases").map { |row| row.fetch("module") }.tally
        unless counts == { "patrol" => 10, "architecture-patrol" => 10 }
          raise "Patrol qualification must contain ten cases per module"
        end
        catalog
      rescue JSON::ParserError, KeyError, TypeError
        raise "Patrol qualification catalogue is malformed"
      end

      def validate_case!(row)
        valid = row.is_a?(Hash) && row.keys.sort == CASE_KEYS &&
          row["id"].is_a?(String) &&
          row["id"].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) &&
          MODULES.include?(row["module"]) &&
          row["mode"].is_a?(String) &&
          row["decision_class"].is_a?(String)
        modes = row["module"] == "patrol" ?
          %w[due not_due disabled] : %w[direct retry]
        valid &&= modes.include?(row["mode"])
        raise "Patrol qualification case is malformed" unless valid
      end

      def start_daemon(label)
        stop_daemon
        @daemon = BackgroundProcess.new(
          args: %w[daemon start],
          sandbox_dir: @project_root,
          run_home: @run_home,
          env: {
            "PATH" => "#{File.dirname(@git_ssh_proxy)}:#{ENV.fetch('PATH', '')}",
            "GIT_SSH_COMMAND" => @git_ssh_proxy,
            "GIT_SSH_VARIANT" => "ssh",
            "HIVE_FAKE_CLAUDE_PATROL_EMPTY" => "1",
            "HIVE_FAKE_CLAUDE_PATROL_OUTPUT_ROOT" =>
              File.join(state_path, "patrol", "runs"),
            "HIVE_FAKE_CLAUDE_LOG_DIR" =>
              File.join(@run_home, "fake-claude"),
            "ANTHROPIC_API_KEY" => nil,
            "CLAUDE_API_KEY" => nil
          },
          log_path: File.join(@run_home, "daemon-#{label}.log")
        ).start
        process_start_time = Hive::Lock.process_start_time(@daemon.pid)
        if process_start_time.to_s.empty?
          raise "qualification daemon process identity is unavailable"
        end
        @daemon_identity = Hive::Daemon::OperationalSnapshot.daemon_identity(
          pid: @daemon.pid, process_start_time: process_start_time
        )
        @daemon
      end

      def stop_daemon
        return unless @daemon

        targets = Hive::ProcessKill.process_tree_snapshot(@daemon.pid) || []
        @daemon.stop(grace: DAEMON_STOP_GRACE)
        verify_daemon_shutdown!(@daemon_identity, targets)
      ensure
        cleanup_owned_targets(targets || [])
        @daemon = nil
        @daemon_identity = nil
      end

      def verify_daemon_shutdown!(identity, captured_targets)
        unless identity
          raise "qualification daemon process identity is unavailable"
        end
        reader = Hive::Daemon::OperationalSnapshot::Reader.new(
          path: Hive::Paths.operational_snapshot_path(@run_home),
          expected_daemon: identity,
          pid_path: File.join(@run_home, ".daemon.pid")
        )
        acknowledgement = reader.shutdown_acknowledgement(
          expected_daemon: identity
        )
        unless acknowledgement
          raise "qualification daemon did not publish drained shutdown proof"
        end

        targets = captured_targets + acknowledgement.fetch(
          "child_inventory"
        ).map { |target| symbolize_process_target(target) }
        if targets.any? { |target| Hive::ProcessKill.captured_process_alive?(target) }
          raise "qualification daemon left an owned process alive"
        end
      end

      def cleanup_owned_targets(targets)
        live = targets.select do |target|
          Hive::ProcessKill.captured_process_alive?(target)
        end
        return if live.empty?

        Hive::ProcessKill.signal_captured_processes(
          "TERM", live, require_identity: true
        )
        deadline = monotonic + CLEANUP_TERM_GRACE
        sleep 0.05 while monotonic < deadline && live.any? do |target|
          Hive::ProcessKill.captured_process_alive?(target)
        end
        live.select! { |target| Hive::ProcessKill.captured_process_alive?(target) }
        unless live.empty?
          Hive::ProcessKill.signal_captured_processes(
            "KILL", live, require_identity: true
          )
          deadline = monotonic + Hive::ProcessKill::KILL_GRACE_SECONDS
          sleep 0.05 while monotonic < deadline && live.any? do |target|
            Hive::ProcessKill.captured_process_alive?(target)
          end
        end
        survivor = live.find do |target|
          Hive::ProcessKill.captured_process_alive?(target)
        end
        return unless survivor

        raise "qualification teardown could not terminate an owned process"
      end

      def symbolize_process_target(target)
        {
          pid: Integer(target.fetch("pid")),
          pgid: Integer(target.fetch("pgid")),
          start_time: target.fetch("start_time").to_s
        }
      end

      def verify_fake_agent_isolation!
        path = File.join(@run_home, "fake-claude", "fake-claude-argv.log")
        lines = File.readlines(path, chomp: true)
        %w[ANTHROPIC_API_KEY CLAUDE_API_KEY].each do |key|
          observed = lines.grep(/\Aenv_#{key}=/)
          unless observed.any? && observed.all? { |line| line == "env_#{key}=__unset__" }
            raise "qualification fake agent inherited #{key}"
          end
        end
      rescue Errno::ENOENT
        raise "qualification fake-agent audit log is unavailable"
      end

      def cleanup_run_dir(run_dir)
        FileUtils.chmod_R(0o700, run_dir)
        FileUtils.remove_entry(run_dir)
      end

      def wait_for_shadowing!
        wait_until("Patrol migration shadow ownership") do
          path = Hive::Modules::Migration::Patrols.state_file(
            @project_root, hive_state_path: state_path
          )
          next false unless File.file?(path)

          state = JSON.parse(File.binread(path))
          state["status"] == "shadowing" &&
            state.fetch("admissions").values.all?
        rescue JSON::ParserError, KeyError
          false
        end
      end

      def comparable_records(module_name)
        root = File.join(
          state_path, "module-runtime", "migration", "shadow", module_name
        )
        return [] unless File.directory?(root)

        Dir.children(root).sort.filter_map do |name|
          unless name.match?(/\A[0-9a-f]{64}\.json\z/)
            raise "Patrol shadow evidence filename is malformed"
          end
          path = File.join(root, name)
          stat = File.lstat(path)
          raise "Patrol shadow evidence is not a regular file" unless
            stat.file? && !stat.symlink? && stat.size <= MAX_EVIDENCE_BYTES

          bytes = File.binread(path)
          record = JSON.parse(bytes)
          unless bytes == Hive::WorkflowPackage::CanonicalJSON.generate(record)
            raise "Patrol shadow evidence is not canonical"
          end
          record if record["comparable"] == true && record["legacy_capture"]
        end
      end

      def update_project_config
        path = File.join(state_path, "config.yml")
        config = YAML.safe_load(File.binread(path)) || {}
        yield config
        File.binwrite(path, config.to_yaml)
      end

      def commit_and_push!(message)
        run_git("add", "--", "lib/sample.rb")
        run_git("commit", "-m", message, "--quiet")
        run_git("push", "origin", "master", "--quiet")
      end

      def run_git(*args, root: @project_root)
        command = root ? [ "git", "-C", root, *args ] : [ "git", *args ]
        out, err, status = capture_command(*command)
        raise "git command failed: #{err.empty? ? out : err}" unless status.success?

        out
      end

      def git_head
        head = run_git("rev-parse", "HEAD").strip
        raise "qualification repository HEAD is malformed" unless
          head.match?(/\A[0-9a-f]{40}\z/)
        head
      end

      def state_path
        File.join(@project_root, ".hive-state")
      end

      def report_path
        Hive::Modules::Migration::Patrols.report_file(
          @project_root, hive_state_path: state_path
        )
      end

      def wait_until(label, timeout: WAIT_TIMEOUT)
        local_deadline = [ monotonic + timeout, @deadline ].min
        loop do
          value = yield
          return value if value
          raise "timed out waiting for #{label}" if monotonic >= local_deadline

          sleep 0.1
        end
      end

      def command_timeout
        remaining = @deadline - monotonic
        raise "Patrol qualification exceeded its whole-run deadline" unless
          remaining.positive?
        [ CLI_TIMEOUT, remaining ].min
      end

      def check_deadline!
        raise "Patrol qualification exceeded its whole-run deadline" if
          monotonic >= @deadline
      end

      def clean_candidate!
        out, err, status = capture_command(
          "git", "-C", Paths.repo_root,
          "status", "--porcelain", "--untracked-files=all"
        )
        raise "cannot inspect qualification candidate: #{err}" unless status.success?
        raise "Patrol qualification requires a clean candidate checkout" unless out.empty?

        head = committed_output("rev-parse", "HEAD").strip
        raise "Patrol qualification candidate HEAD is malformed" unless
          head.match?(/\A[0-9a-f]{40}\z/)
        head
      end

      def committed_control(path)
        committed = committed_output("show", "HEAD:#{path}")
        working = File.binread(File.join(Paths.repo_root, path))
        raise "qualification control differs from HEAD: #{path}" unless
          committed == working
        committed
      end

      def digest_paths(paths)
        bytes = paths.map do |path|
          "#{path}\0#{committed_output('show', "HEAD:#{path}")}"
        end.join("\0")
        Digest::SHA256.hexdigest(bytes)
      end

      def committed_output(*args)
        out, err, status = capture_command(
          "git", "-C", Paths.repo_root, *args
        )
        raise "cannot read qualification candidate: #{err}" unless status.success?
        out
      end

      def capture_command(*command)
        Hive::WorkflowPackage::RuntimePolicy.capture3_bounded(
          *command, timeout_sec: command_timeout
        )
      rescue Timeout::Error
        raise "Patrol qualification command timed out: #{command.first}"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
