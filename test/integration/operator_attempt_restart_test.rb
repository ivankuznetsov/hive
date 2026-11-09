require "test_helper"
require "open3"
require "stringio"
require "hive/commands/init"
require "hive/attempts/dispatcher"
require "hive/attempts/supervisor"
require "hive/attempts/reconciler"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"
require "hive/daemon/concurrency_controller"
require "hive/recovery/api"
require "hive/recovery/manual_retry"

# Opt-in Linux characterization: disposable services model the shipped kill
# policies. They do not restart the operator's installed Hive applications.
class OperatorAttemptRestartTest < Minitest::Test
  include HiveTestHelper

  class Launcher
    attr_reader :pid

    def initialize(store:, task:, release:)
      @store, @task, @release = store, task, release
    end

    def preflight! = true

    def launch(record, claim_capability:)
      # SQLite handles cannot cross fork; both sides reconnect independently.
      Sequel::DATABASES.each(&:disconnect)
      @pid = fork do
        Process.setsid
        database = Hive::RuntimeControlPlane::Database.new(path: @store.database.path).open!
        store = Hive::Attempts::Repository.new(database: database, root: @store.root)
        supervisor = Hive::Attempts::Supervisor.new(store: store, attempt_id: record.attempt_id,
          claim_io: StringIO.new(claim_capability), install_signal_handlers: true,
          heartbeat_sec: 5, stale_sec: 30)
        worker = worker_argv(record)
        supervisor.define_singleton_method(:hive_worker?) { |_| false }
        supervisor.define_singleton_method(:resolved_worker_argv) { |_| worker }
        exit! supervisor.run
      end
      { "claimed" => true }
    end

    def worker_argv(record)
      script = <<~'WORKER'
        require "hive"
        require "hive/lock"
        require "hive/markers"
        folder, state_file, release, attempt_id, generation, working_marker = ARGV
        Hive::Lock.with_task_lock(folder, "attempt_id" => attempt_id) do
          Hive::Markers.set(state_file, working_marker.to_sym,
            attempt_id: attempt_id, ownership_generation: generation)
          sleep 0.02 until File.exist?(release)
          Hive::Markers.set(state_file, :complete, attempt_id: attempt_id)
        end
      WORKER
      [ RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-e", script,
        @task.folder, @task.state_file, @release, record.attempt_id, record.task_generation,
        @task.stage_index == 6 ? "review_working" : "agent_working" ]
    end
  end

  class ProbeClient < Hive::Attempts::Client
    def initialize(store:, probe:)
      super(store: store)
      @probe = probe
    end

    def attach(attempt_id, **options)
      @probe.call(attempt_id)
      super
    end
  end

  def test_direct_operator_attempt_survives_isolated_service_policy_restarts
    characterize(attached_retry: false)
  end

  def test_attached_retry_survives_isolated_service_policy_restarts
    characterize(attached_retry: true)
  end

  private

  def characterize(attached_retry:)
    skip "set HIVE_TEST_SYSTEMD_RESTARTS=1 for disposable user-service characterization" unless ENV["HIVE_TEST_SYSTEMD_RESTARTS"] == "1"
    skip "Linux user systemd and fork are required" unless RUBY_PLATFORM.include?("linux") && Process.respond_to?(:fork)
    skip "user systemd unavailable" unless system("/usr/bin/systemctl", "--user", "show-environment", out: File::NULL, err: File::NULL)

    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        project = Hive::Config.registered_projects.find { |entry| entry["path"] == root }
        stage = attached_retry ? "6-review" : "4-execute"
        folder = File.join(project.fetch("hive_state_path"), "stages", stage, "restart-probe-task")
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 818, slug: "restart-probe-task", display_name: nil, workflow: "coding")
        task = Hive::Task.new(folder)
        File.write(task.state_file, "# Restart characterization\n")
        Hive::Markers.set(task.state_file, :review_error, reason: "review_orphaned") if attached_retry
        store = Hive::Attempts::Repository.open_default
        repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
        release = File.join(root, "release-worker")
        launcher = Launcher.new(store: store, task: task, release: release)
        dispatcher = Hive::Attempts::Dispatcher.new(store: store, launcher: launcher, task_resolver: ->(_) { task })
        probe = lambda do |attempt_id|
          wait_for_worker(store, attempt_id, task)
          record = store.fetch(attempt_id)
          identity = Hive::Attempts::ProcessIdentity.new
          before = File.binread(task.state_file)
          %w[daemon web babysitter].each do |service|
            template = File.read(File.expand_path("../../examples/systemd/hive-#{service}.service", __dir__))
            mode = template[/^KillMode=(.+)$/, 1] || "control-group"
            unit = "hive-retry-probe-#{Process.pid}-#{SecureRandom.hex(4)}"
            begin
              run_command("/usr/bin/systemd-run", "--user", "--quiet", "--collect", "--unit", unit,
                "--property", "KillMode=#{mode}", "/usr/bin/sleep", "infinity")
              old_pid = run_command("/usr/bin/systemctl", "--user", "show", "#{unit}.service", "-p", "MainPID", "--value").to_i
              refute_equal record.wrapper.fetch("pid"), old_pid
              refute_equal record.worker.fetch("pid"), old_pid
              run_command("/usr/bin/systemctl", "--user", "restart", "#{unit}.service")
              new_pid = run_command("/usr/bin/systemctl", "--user", "show", "#{unit}.service", "-p", "MainPID", "--value").to_i
              refute_equal old_pid, new_pid
              assert_equal :matching, identity.status(record.wrapper), service
              assert_equal :matching, identity.status(record.worker), service
              # Delayed heartbeats with a matching wrapper remain suspects.
              status = Hive::Attempts::Reconciler.new(store: store).reconcile(now: Time.now.utc + 120)
              assert_empty status.newly_lost_attempts, service
              assert_equal [ attempt_id ], status.capacity.reserved_attempt_ids, service
              marker = Hive::Markers.current(task.state_file)
              row = Hive::Daemon::StatusConsumer::Row.new(project: project.fetch("name"), slug: task.slug,
                stage: stage, folder: folder, state_file: task.state_file,
                marker: marker.name.to_s, marker_attrs: marker.attrs,
                state_file_mtime: Time.now.utc - 600, action: "agent_running", live_task_lock: true)
              logger = Object.new
              logger.define_singleton_method(:event) { |*_, **_| }
              Hive::Daemon::StaleAgentHealer.new(controller: Hive::Daemon::ConcurrencyController.new(
                max_concurrent_runs: 4, max_concurrent_per_project: 2, max_runs_per_day_per_project: 50),
                logger: logger).heal([ row ], now: Time.now.utc)
              assert_equal before, File.binread(task.state_file), service
              assert Hive::Lock.read_task_lock(folder), service
              assert_equal record.wrapper, store.fetch(attempt_id).wrapper, service
              if ENV["HIVE_RESTART_EVIDENCE_PATH"]
                File.open(ENV.fetch("HIVE_RESTART_EVIDENCE_PATH"), "a") do |file|
                  file.puts JSON.generate(service: service, kill_mode: mode, attached_retry: attached_retry,
                    attempt_id: attempt_id, wrapper: record.wrapper, worker: record.worker,
                    heartbeat_deadline: record["heartbeat_deadline"], lock: Hive::Lock.read_task_lock(folder),
                    marker: marker.name, old_service_pid: old_pid, new_service_pid: new_pid,
                    classification: status.attempts.first.classification, state: store.fetch(attempt_id).state)
                end
              end
            ensure
              system("/usr/bin/systemctl", "--user", "stop", "#{unit}.service", out: File::NULL, err: File::NULL)
            end
          end
          File.write(release, "complete")
        end
        client = ProbeClient.new(store: store, probe: probe)
        if attached_retry
          coordinator = Hive::Daemon::RecoveryCoordinator.new(dispatch_repository: repository, attempt_store: store)
          runner = Hive::Recovery::ManualRetry.new(coordinator: coordinator, repository: repository,
            store: store, attempts: Hive::Attempts::API.new(daemon: dispatcher), client: client)
          row = Hive::OperationalAction.observed_row(task, project: project.fetch("name"))
          receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
          assert_equal "succeeded", receipt.terminal_outcome, receipt.to_h.inspect
        else
          admitted = dispatcher.dispatch(task: task, project: project.fetch("name"), intended_stage: "4-execute",
            argv: [ "hive", "develop", task.slug ], request_id: "direct-restart-probe", provider: "codex", interactive: false)
          result = client.attach(admitted.attempt.attempt_id, stdout: StringIO.new, stderr: StringIO.new)
          assert_equal "succeeded", result.outcome
        end
        assert_equal :complete, Hive::Markers.current(task.state_file).name
        assert_equal 1, store.database.read { |db| db[:attempts].count }
      ensure
        File.write(release, "complete") if release
        if launcher&.pid
          Timeout.timeout(10) { Process.wait(launcher.pid) }
        end
      end
    end
  end

  def wait_for_worker(store, attempt_id, task)
    Timeout.timeout(10) do
      loop do
        record = store.fetch(attempt_id)
        break if record&.worker && %i[agent_working review_working].include?(Hive::Markers.current(task.state_file).name)
        sleep 0.02
      end
    end
  end

  def run_command(*argv)
    output, error, status = Open3.capture3(*argv)
    assert status.success?, "#{argv.first}: #{error}"
    output
  end
end
