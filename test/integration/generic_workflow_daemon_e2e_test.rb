require "test_helper"
require "json"
require "shellwords"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/policy"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/stages/base"
require "hive/task_meta"

class GenericWorkflowDaemonE2ETest < Minitest::Test
  include HiveTestHelper

  SLUG = "generic-daemon-260620-abcd"

  # A generic workflow only ever uses the universal `hive run` / `hive approve`
  # verbs and the generic action set. Any coding-only verb or action appearing
  # on a generic row means a coding-only branch leaked into the generic path.
  GENERIC_ACTIONS = %w[ready_to_run ready_to_advance needs_input done error].freeze
  CODING_ONLY_VERBS = %w[brainstorm plan develop open-pr review artifacts finalize archive].freeze

  def test_generic_task_advances_two_stages_through_status_policy_and_cli
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          project = File.basename(project_root)
          capture_io { Hive::Commands::Init.new(project_root).call }
          seed_generic_task(project_root, descriptor)
          coding_slug = seed_coding_task(project)

          first = status_row(SLUG)
          assert_equal "1-intake", first.fetch("stage")
          assert_equal "dispatch", first.fetch("workflow")
          assert_equal "ready_to_run", first.fetch("action")
          assert_equal "hive run #{SLUG}", first.fetch("suggested_command")
          assert_equal :dispatch, policy_decision(first)
          refute_coding_only_branch(first)

          # The coding parity row, by contrast, DOES take a coding-only branch
          # (ready_to_brainstorm / `hive brainstorm`) — proving the routing
          # actually discriminates on workflow rather than treating all rows alike.
          coding = status_row(coding_slug)
          assert_equal "coding", coding.fetch("workflow")
          assert_equal "ready_to_brainstorm", coding.fetch("action")
          assert_equal :dispatch, policy_decision(coding)

          ran = []
          with_stubbed_generic_agent(ran) do
            capture_io { Hive::CLI.start([ "run", SLUG, "--project", project ]) }

            after_intake_run = status_row(SLUG)
            assert_equal "ready_to_advance", after_intake_run.fetch("action")
            assert_equal "hive approve #{SLUG} --from 1-intake", after_intake_run.fetch("suggested_command")
            assert_equal :dispatch, policy_decision(after_intake_run)
            refute_coding_only_branch(after_intake_run)

            capture_io { Hive::CLI.start([ "approve", SLUG, "--project", project, "--from", "1-intake" ]) }
            assert File.directory?(stage_folder(project_root, "2-gather"))
            refute File.exist?(stage_folder(project_root, "1-intake"))

            gather = status_row(SLUG)
            assert_equal "2-gather", gather.fetch("stage")
            assert_equal "ready_to_run", gather.fetch("action")
            assert_equal :dispatch, policy_decision(gather)
            refute_coding_only_branch(gather)

            capture_io { Hive::CLI.start([ "run", SLUG, "--project", project ]) }
            after_gather_run = status_row(SLUG)
            assert_equal "ready_to_advance", after_gather_run.fetch("action")
            assert_equal "hive approve #{SLUG} --from 2-gather", after_gather_run.fetch("suggested_command")
            refute_coding_only_branch(after_gather_run)

            capture_io { Hive::CLI.start([ "approve", SLUG, "--project", project, "--from", "2-gather" ]) }
          end

          assert_equal %w[intake gather], ran
          assert File.directory?(stage_folder(project_root, "3-report"))
          refute File.exist?(stage_folder(project_root, "2-gather"))
        end
      end
    end
  end

  # U6.6 / A6 — the REAL end-to-end daemon path. The test above drives
  # `Hive::CLI` directly and feeds `Policy.decide` a hardcoded
  # `last_dispatched_state_file_mtime: nil`, so it never exercises the daemon's
  # controller. This one runs the actual `Daemon::Dispatcher#tick` loop with a
  # real `ConcurrencyController`, so the cross-advance baseline carry and the
  # post-completion `find_post_advance_state_file` refresh (the High #1 stall
  # surface) actually run. A fake supervisor executes each dispatched command
  # in-process (under the stubbed generic agent) and surfaces it as a child
  # exit on the next tick — the spawn→reap lifecycle the real daemon sees.
  def test_generic_task_advances_two_stages_through_real_daemon_tick
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          capture_io { Hive::Commands::Init.new(project_root).call }
          seed_generic_task(project_root, descriptor)

          ran = []
          with_stubbed_generic_agent(ran) do
            supervisor = InlineRunSupervisor.new(
              run: ->(cmd) { capture_io { Hive::CLI.start(Shellwords.split(cmd).drop(1)) }; 0 }
            )
            controller = Hive::Daemon::ConcurrencyController.new(
              max_concurrent_runs: 5, max_concurrent_per_project: 5,
              max_runs_per_day_per_project: 100
            )
            consumer = LiveStatusConsumer.new(
              fetch: lambda do
                out, = capture_io { Hive::CLI.start([ "status", "--json" ]) }
                doc = JSON.parse(out)
                mapper = Hive::Daemon::StatusConsumer.new
                Hive::Daemon::StatusConsumer::Result.new(
                  ok: true, rows: mapper.send(:extract_rows, doc),
                  projects: mapper.send(:extract_projects, doc), error: nil
                )
              end
            )
            dispatcher = Hive::Daemon::Dispatcher.new(
              # edit_debounce_sec: 0 so the generic ready_to_run debounce never
              # waits — the inline runner writes real file mtimes, and real
              # `Time.now` ticks keep `now >= mtime`, which is all decide_run
              # needs once debounce is zero.
              config: { "daemon" => { "edit_debounce_sec" => 0, "poll_interval_sec" => 30 } },
              controller: controller, supervisor: supervisor,
              status_consumer: consumer, logger: CollectingLogger.new
            )
            # Bypass real daemon enrollment — the controller/dispatch path is
            # what's under test here, not per-project YAML opt-in.
            dispatcher.define_singleton_method(:project_enabled?) { |_| true }

            # One dispatch-and-reap per tick; advance through both stages.
            12.times do
              break if File.directory?(stage_folder(project_root, "3-report"))

              now = Time.now
              supervisor.now = now
              dispatcher.tick(now: now)
            end

            @spawned_commands = supervisor.spawned.map { |s| s[:command] }
          end

          # The agent ran for BOTH descriptor agent stages, driven by the
          # daemon loop — not by direct CLI calls.
          assert_equal %w[intake gather], ran,
                       "the real daemon tick loop must run intake then gather"
          assert File.directory?(stage_folder(project_root, "3-report")),
                 "the task must reach the descriptor's terminal report stage"
          refute File.exist?(stage_folder(project_root, "1-intake"))
          refute File.exist?(stage_folder(project_root, "2-gather"))
          # The daemon — not a direct CLI call — issued both the run and the
          # advancing approve dispatches through the supervisor.
          assert(@spawned_commands.any? { |c| c.start_with?("hive run") },
                 "daemon must have dispatched at least one `hive run`")
          assert(@spawned_commands.any? { |c| c.start_with?("hive approve") },
                 "daemon must have dispatched the advancing `hive approve`")

          # Per-stage artifacts: each agent stage wrote its descriptor state_file
          # and the approve carried them forward into the terminal folder.
          # (report.md is absent — the terminal report stage is reached by the
          # advancing approve, not by running its agent.)
          final = stage_folder(project_root, "3-report")
          %w[intake.md gather.md].each do |artifact|
            assert File.file?(File.join(final, artifact)),
                   "#{artifact} should be carried into the terminal stage folder"
          end
          refute File.exist?(File.join(final, "report.md")),
                 "the terminal report agent never ran, so report.md must not exist"

          # Commit-per-advance trail: one approve commit per stage transition,
          # each naming the descriptor's own stage dirs.
          log_subjects = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s")
          approve_commits = log_subjects.lines.grep(/ approve /)
          assert_equal 2, approve_commits.size,
                       "one approve commit per stage transition to reach 3-report"
          assert_includes log_subjects, "hive: 1-intake/#{SLUG} approve 1-intake -> 2-gather"
          assert_includes log_subjects, "hive: 2-gather/#{SLUG} approve 2-gather -> 3-report"
        end
      end
    end
  end

  private

  # Minimal logger collaborator (the real Hive::Daemon::Logger writes files).
  class CollectingLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end

    def close; end
  end

  # Status consumer that recomputes rows from a live in-process
  # `hive status --json` each fetch (via the injected lambda), reusing the
  # real StatusConsumer's row/project mapping so the dispatcher sees on-disk
  # state every tick.
  class LiveStatusConsumer
    def initialize(fetch:)
      @fetch = fetch
    end

    def fetch
      @fetch.call
    end
  end

  # Supervisor stand-in that runs each dispatched command in-process and
  # surfaces it as a child exit on the NEXT reap — mirroring the real
  # daemon's spawn→reap split across ticks.
  class InlineRunSupervisor
    ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

    attr_reader :spawned
    attr_accessor :now

    def initialize(run:)
      @run = run
      @spawned = []
      @pending = []
      @next_pid = 4000
      @now = Time.now
    end

    def spawn(command_string:, project:, slug:, stage:,
              log_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = (@next_pid += 1)
      @spawned << { command: command_string, project: project, slug: slug, stage: stage }
      exit_code = @run.call(command_string)
      @pending << ChildExit.new(
        pid: pid, exit_code: exit_code, project: project, slug: slug, stage: stage,
        command: command_string, state_file_path: state_file_path,
        started_at: @now, finished_at: @now, json_envelope: nil
      )
      pid
    end

    def reap_all(now: Time.now)
      out = @pending
      @pending = []
      out
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600); end
    def update_timeouts(**); end
    def enforce_timeouts(now:)
      []
    end

    def in_flight_count
      @pending.size
    end
  end

  def seed_generic_task(project_root, descriptor)
    stage = descriptor.stage_named("intake")
    folder = stage_folder(project_root, stage.dir)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: 101, slug: SLUG, display_name: "Generic Daemon", workflow: descriptor.id.to_s)
  end

  def seed_coding_task(project)
    capture_io { Hive::Commands::New.new(project, "coding parity row").call }
    folder = Dir[File.join(Hive::Config.find_project(project).fetch("hive_state_path"), "stages", "1-inbox", "coding-parity-row-*")].first
    File.basename(folder)
  end

  def stage_folder(project_root, stage_dir)
    File.join(project_root, ".hive-state", "stages", stage_dir, SLUG)
  end

  def status_row(slug)
    out, = capture_io { Hive::CLI.start([ "status", "--json" ]) }
    payload = JSON.parse(out)
    payload.fetch("projects").flat_map { |project| project.fetch("tasks") }.find { |task| task.fetch("slug") == slug } ||
      flunk("missing status row for #{slug}")
  end

  # Negative assertion (U6.6): a generic row must never emit a coding-only verb
  # or action — neither the status classifier nor the CLI dispatch routed it
  # through a bespoke coding branch.
  def refute_coding_only_branch(row)
    action = row.fetch("action")
    assert_includes GENERIC_ACTIONS, action,
                    "generic row emitted non-generic action #{action.inspect} (a coding-only branch fired)"
    verb = row.fetch("suggested_command").to_s.split(/\s+/)[1]
    refute_includes CODING_ONLY_VERBS, verb,
                    "generic row suggested coding-only verb #{verb.inspect} instead of hive run/approve"
  end

  def policy_decision(row)
    Hive::Daemon::Policy.decide(
      action: row.fetch("action"),
      stage: row.fetch("stage"),
      workflow: row.fetch("workflow"),
      command: row.fetch("suggested_command"),
      state_file_mtime: Time.parse(row.fetch("mtime")),
      last_dispatched_state_file_mtime: nil,
      now: Time.now
    )
  end

  def with_stubbed_generic_agent(ran)
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **_kwargs|
      ran << task.stage_name
      File.write(task.state_file, "# #{task.stage_name}\n<!-- COMPLETE -->\n")
      { status: :complete }
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end
end
