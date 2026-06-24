require "json"
require "hive/cli"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"

# In-process daemon scaffolding shared by the content-workflow end-to-end
# tests. Extracted from content_workflow_e2e_test.rb so a second e2e (or a
# future one) can drive the real Dispatcher against an inline supervisor
# without re-declaring the supervisor / logger / status-consumer doubles and
# letting the copies drift. Mix into a Minitest::Test with `include`; the
# nested doubles resolve as unqualified constants through ancestor lookup.
module HiveDaemonE2EHarness
  # Logger double that retains every emitted event so a test can assert which
  # daemon lifecycle events fired (e.g. that no :fatal / :markerless_stalled
  # event occurred during a clean run).
  class CollectingLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << { name: name, attrs: attrs }
    end

    def close; end
  end

  # Status-consumer double that defers to a fetch lambda each tick, letting the
  # test feed the dispatcher a live `hive status --json` snapshot.
  class LiveStatusConsumer
    def initialize(fetch:)
      @fetch = fetch
    end

    def fetch
      @fetch.call
    end
  end

  # Supervisor double that runs each dispatched command inline (in-process)
  # instead of forking, records every spawn, and synthesizes the ChildExit the
  # dispatcher reaps on the next tick.
  class InlineSupervisor
    ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

    attr_reader :spawned
    attr_accessor :now

    def initialize(run:)
      @run = run
      @spawned = []
      @pending = []
      @next_pid = 7000
      @now = Time.now
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = (@next_pid += 1)
      @spawned << { command: command_string, project: project, slug: slug, stage: stage }
      exit_code = @run.call(command_string)
      @pending << ChildExit.new(
        pid: pid,
        exit_code: exit_code,
        project: project,
        slug: slug,
        stage: stage,
        command: command_string,
        state_file_path: state_file_path,
        started_at: @now,
        finished_at: @now,
        json_envelope: nil
      )
      pid
    end

    def reap_all(now: Time.now)
      pending = @pending
      @pending = []
      pending
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600); end
    def update_timeouts(**); end
    def enforce_timeouts(now:) = []
    def in_flight_count = @pending.size
  end

  # Advance the harness one dispatcher tick: stamp the same `now` onto the
  # supervisor and the dispatcher so reap and dispatch share a clock. Names the
  # triplet repeated by both the drive loop and the rest proof.
  def advance_tick(dispatcher, supervisor)
    now = Time.now
    supervisor.now = now
    dispatcher.tick(now: now)
  end

  # Build a StatusConsumer::Result from a live `hive status --json` snapshot —
  # the dispatcher's per-tick view of the queue.
  def status_snapshot
    out, = capture_io { Hive::CLI.start([ "status", "--json" ]) }
    doc = JSON.parse(out)
    mapper = Hive::Daemon::StatusConsumer.new
    Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: mapper.send(:extract_rows, doc),
      projects: mapper.send(:extract_projects, doc),
      error: nil
    )
  end

  # Path of a task folder within the tmp project's `.hive-state` tree.
  def task_folder(project_root, stage, slug)
    File.join(project_root, ".hive-state", "stages", stage, slug)
  end
end
