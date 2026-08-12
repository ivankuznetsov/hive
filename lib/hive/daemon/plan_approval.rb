require "shellwords"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/plan_review/transition_guard"
require "hive/task"

module Hive
  module Daemon
    # Rewrite a `hive plan ...` command into `hive develop ...` and
    # flip the plan-stage `:waiting` marker to `:complete` so the
    # daemon's plan-approval auto-dispatch can satisfy the workflow
    # verb's terminal-marker gate (`Hive::Commands::Approve::
    # VALID_TERMINAL_MARKERS`). Without this, the daemon would
    # dispatch `hive plan ...` (which loops; the plan stage does
    # not transition `:waiting` on its own re-run) or dispatch
    # `hive develop ...` against a `:waiting` marker (which raises
    # `Hive::WrongStage` and exits 4 every tick).
    #
    # Mirrors the TUI's two-step pattern in
    # `Hive::Tui::BubbleModel#dispatch_develop_for` /
    # `#develop_command_from_plan` / `#finalize_plan_marker`. The
    # TUI helper stays scoped to its message layer; this module is
    # the daemon-callable equivalent. Both share the same load-bearing
    # safety property (validate command shape BEFORE flipping the
    # marker so a malformed row leaves the marker at `:waiting` for
    # operator inspection rather than stranding it at `:complete`
    # with no follow-up dispatch).
    module PlanApproval
      module_function

      class NotApprovable < StandardError; end

      # Prepare a plan-stage row for daemon auto-dispatch.
      #
      # Returns the rewritten develop command string. Side effect:
      # if the marker is `:waiting`, flips it to `:complete` on disk.
      # If the marker is already `:complete` (a race with manual
      # operator action), leaves it alone and returns the rewritten
      # command. For any other marker, raises `NotApprovable` so the
      # caller can route the row to `:skip` instead of relying on the
      # workflow verb's `WrongStage` check as the failure boundary.
      #
      # @param suggested_command [String] the `hive plan ...` command
      #   from the row's `suggested_command` (or an already-rewritten
      #   `hive develop ...` command when the row has already advanced)
      # @param state_file [String] absolute path to the row's state
      #   file (e.g. `.../3-plan/<slug>/plan.md`)
      # @return [String] the rewritten `hive develop ...` command
      # @raise [ArgumentError] when `suggested_command` is not a
      #   well-formed `hive plan ...` or `hive develop ...` invocation
      # @raise [NotApprovable] when the marker is neither `:waiting`
      #   nor `:complete`
      def prepare(suggested_command, state_file, clearance_checker: nil)
        develop_command = rewrite_to_develop(suggested_command)

        if clearance_checker
          unless clearance_checker.call == true
            raise NotApprovable, "plan review has not authorized execution"
          end
          finalize_marker!(state_file)
          return develop_command
        end

        task = Hive::Task.new(File.dirname(state_file))
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "plan-review-approval") do
          locked = Hive::Task.new(task.folder)
          cfg = Hive::Config.load(locked.project_root)
          observation = Hive::PlanReview::TransitionGuard.prepare_existing!(
            task: locked, destination: "4-execute", config: cfg
          )
          Hive::PlanReview::TransitionGuard.verify!(
            task: locked, destination: "4-execute", observation:, config: cfg
          )
          finalize_marker!(locked.state_file)
        end

        develop_command
      rescue Hive::PlanReview::TransitionBlocked => error
        raise NotApprovable, error.message
      end

      def finalize_marker!(state_file)
        marker = Hive::Markers.current(state_file)
        case marker.name
        when :waiting
          Hive::Markers.set(state_file, :complete)
        when :complete
          # Already approved by something else (manual operator
          # action, prior tick race). The dispatch is still valid.
        else
          raise NotApprovable,
                "marker=#{marker.name.inspect}; plan-approval auto-dispatch requires :waiting or :complete"
        end

        true
      end

      # Idempotent for an already-advanced row. The daemon path always passes
      # the `plan_waiting` row's `hive plan ...` command. The bot's Approve
      # button can instead fire on a row that already raced to `:complete`
      # (daemon auto-approve or a manual advance), at which point TaskAction
      # reclassifies it as `ready_to_develop` and its `suggested_command` is
      # already `hive develop ...`. Accepting both shapes lets that stale tap
      # dispatch the valid develop and makes the `:complete` no-op branch in
      # `prepare` reachable, rather than raising on the develop verb.
      def rewrite_to_develop(suggested_command)
        argv = Shellwords.split(suggested_command.to_s)
        unless argv.length >= 3 && argv[0] == "hive" && %w[plan develop].include?(argv[1])
          raise ArgumentError,
                "plan-approval auto-dispatch expects `hive plan ...` or `hive develop ...`, " \
                "got #{suggested_command.inspect}"
        end

        argv[1] = "develop"
        Shellwords.join(argv)
      end
    end
  end
end
