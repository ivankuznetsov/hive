require "shellwords"
require "digest"
require "time"
require "hive/agent_profiles"
require "hive/stages"
require "hive/workflows"
require "hive/task_action/diagnostic"
require "hive/conditions/gate_evaluator"
require "hive/conditions/migration"
require "hive/plan_frontmatter"
require "hive/task_projection/store"
require "hive/markers"
require "hive/draft_pr_receipt"

module Hive
  # Classifier that turns a (Task, Marker) pair into a user-facing
  # action: a stable key (matching `Hive::Schemas::TaskActionKind`),
  # a human label for `hive status` output, and a copy-paste-executable
  # `command` string for the next step.
  #
  # Used by `hive status` (per-row action grouping) and by
  # `hive run` / `hive approve` / `hive accept-finding` JSON
  # `next_action` emission.
  class TaskAction
    ACTIONS = {
      inbox: {
        key: Hive::Schemas::TaskActionKind::READY_TO_BRAINSTORM,
        label: "Ready to brainstorm",
        command: "brainstorm"
      },
      brainstorm_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Answer questions",
        command: "brainstorm"
      },
      brainstorm_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_PLAN,
        label: "Ready to plan",
        command: "plan"
      },
      plan_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Review plan draft",
        command: "plan"
      },
      plan_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_DEVELOP,
        label: "Ready to develop",
        command: "develop"
      },
      execute_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "develop"
      },
      execute_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_OPEN_PR,
        label: "Ready to open PR",
        command: "open-pr"
      },
      open_pr_ready: {
        key: Hive::Schemas::TaskActionKind::READY_TO_OPEN_PR,
        label: "Ready to open PR",
        command: "open-pr"
      },
      open_pr_complete: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
        label: "Ready for review",
        command: "review"
      },
      execute_stale: {
        # Recovery path: the user must edit reviews/, lower task.md
        # frontmatter `pass:`, remove the EXECUTE_STALE marker, then
        # re-run. There is no single command that recovers; the closest
        # agent-callable step is reviewing the findings and toggling
        # accept-finding so the next run sees a smaller accepted set.
        key: Hive::Schemas::TaskActionKind::RECOVER_EXECUTE,
        label: "Needs recovery",
        command: "findings"
      },
      review_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs review decision",
        command: "review"
      },
      review_ready: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
        label: "Ready for review",
        command: "review"
      },
      review_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ARTIFACTS,
        label: "Ready to collect artifacts",
        command: "artifacts"
      },
      # A clean ad-hoc PR review: complete, but parked at 6-review with no
      # advance command. Hive does not auto-finalize a borrowed PR (the
      # ad-hoc plan's non-goal "Finalizing someone else's PR"), so this
      # carries a non-advancing key the daemon's ADVANCE_ACTIONS never fires
      # on. The operator can still run `hive artifacts` by hand.
      review_complete_adhoc: {
        key: Hive::Schemas::TaskActionKind::REVIEW_PARKED,
        label: "Ad-hoc review complete (parked)",
        command: nil
      },
      review_stale: {
        key: Hive::Schemas::TaskActionKind::RECOVER_REVIEW,
        label: "Needs recovery",
        command: nil
      },
      # Used by TWO call sites that today happen to want identical
      # "re-run finalize" semantics:
      #
      #   1. `Coding::ACTION_DISPATCH["artifacts"][:complete]` for a real task
      #      at 7-artifacts with `:complete` — its artifact run is done,
      #      finalize is next. (The live route is the table; the legacy
      #      `artifacts_action` method is now reached only by the parity harness.)
      #   2. `finalize_complete_action` as the fallback when finalize
      #      ran but left the PR as a draft (is_draft != "false") —
      #      operator should re-run finalize.
      #
      # If U2 (or any future artifacts-stage change) repurposes this
      # entry, AUDIT `finalize_complete_action` first: the draft-PR
      # fallback at lib/hive/task_action.rb depends on the current
      # READY_TO_FINALIZE/command:"finalize" shape and would silently
      # break if this entry's key or command shifts. The two call sites
      # should be split into separate ACTIONS keys at that point.
      artifacts_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_FINALIZE,
        label: "Ready to finalize",
        command: "finalize"
      },
      artifacts_ready: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ARTIFACTS,
        label: "Ready to collect artifacts",
        command: "artifacts"
      },
      finalize_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Confirm finalize",
        command: "finalize"
      },
      finalize_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ARCHIVE,
        label: "Ready to archive",
        command: "archive"
      },
      ready_to_advance: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ADVANCE,
        label: "Ready to advance",
        command: "approve"
      },
      generic_ready_to_run: {
        key: Hive::Schemas::TaskActionKind::READY_TO_RUN,
        label: "Ready to run",
        command: "run"
      },
      generic_needs_input: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "run"
      },
      recover_draft_pr: {
        key: Hive::Schemas::TaskActionKind::RECOVER_DRAFT_PR,
        label: "Retry draft PR handoff manually",
        command: "run"
      },
      done: {
        key: Hive::Schemas::TaskActionKind::ARCHIVED,
        label: "Archived",
        command: nil
      },
      manual_steering: {
        key: Hive::Schemas::TaskActionKind::MANUAL_STEERING,
        label: "Manually steered",
        command: nil
      },
      agent_running: {
        # Marker is `:agent_working` — a `hive run` is in flight. Surfacing
        # a workflow command here would send the user (or an agent loop)
        # straight into ConcurrentRunError on every retry. The right
        # action is wait-and-watch.
        key: Hive::Schemas::TaskActionKind::AGENT_RUNNING,
        label: "Agent running",
        command: nil
      },
      error: {
        key: Hive::Schemas::TaskActionKind::ERROR,
        label: "Error",
        command: nil
      }
    }.freeze

    # Ready actions are the shared dispatch vocabulary for status consumers.
    # Derive the lookup from the classifier table so bot and web adapters
    # cannot drift from the command Hive actually reports for an action.
    READY_COMMANDS = ACTIONS.values.each_with_object({}) do |action, commands|
      key = action.fetch(:key)
      commands[key] = action.fetch(:command) if key.start_with?("ready_")
    end.freeze

    attr_reader :task, :marker, :project_name, :projection

    # Default grace window for placeholder AGENT_WORKING markers (no PID
    # attribute) before they classify as orphaned. Mirrors the daemon's
    # `daemon.agent_marker_grace_sec` default so consumers see the same
    # threshold whether they read from the daemon-healed marker or the
    # synthetic classification done here. Configurable per-instance.
    DEFAULT_AGENT_MARKER_GRACE_SEC = 300

    def initialize(task, marker = nil, projection: nil, config: nil,
                   project_name: nil, project_count: 1, stage_collision: false,
                   pid_alive: nil, state_file_mtime: nil,
                   agent_marker_grace_sec: DEFAULT_AGENT_MARKER_GRACE_SEC,
                   live_task_lock: false)
      @task = task
      @projection = projection || load_projection(marker)
      @marker = projected_marker(@projection) || marker ||
                Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
      @config = config || { "conditions" => { "authority" => "markers", "stages" => {} } }
      @project_name = project_name
      @project_count = project_count
      @stage_collision = stage_collision
      @pid_alive = pid_alive
      @state_file_mtime = state_file_mtime
      @agent_marker_grace_sec = agent_marker_grace_sec
      @live_task_lock = live_task_lock
    end

    def self.for(task, marker = nil, **)
      new(task, marker, **)
    end

    def key
      action[:key]
    end

    def label
      action[:label]
    end

    # Returns a copy-paste-executable shell command, or nil for actions
    # whose state requires manual recovery (agent_running, archived, error).
    #
    # Workflow-verb commands ALWAYS include `--from <stage>`: that's the
    # idempotency lever — a retry after a successful advance fails with
    # WRONG_STAGE (4) instead of silently advancing twice. Generic `approve`
    # rows use the same `--from` assertion, generic `run` rows use `--stage`
    # only when slug-stage ambiguity exists, and recovery verbs (findings/
    # accept-finding/reject-finding) also use `--stage` only for ambiguity.
    def command
      verb = action[:command]
      return nil unless verb

      stage = workflow_stage
      return nil unless stage
      stage_ref = command_stage_dir(stage)

      parts = command_prefix(verb)
      if verb == "approve"
        parts.concat([ "--from", stage_ref ])
        # A markerless inert stage has no agent to stamp a terminal marker, so
        # its forward approve can never satisfy Approve#validate_move!'s
        # VALID_TERMINAL_MARKERS gate — without --force the daemon would
        # re-dispatch a WrongStage failure every tick and drain the per-project
        # daily dispatch cap. `:none` here is reachable only for an inert
        # non-terminal stage (generic_action routes every other `:none` to a
        # run command), so the override is scoped exactly to that advance.
        parts << "--force" if marker.name == :none
      elsif verb == "run"
        parts.concat([ "--stage", stage_ref ]) if @stage_collision
      elsif include_stage_filter?(verb)
        parts.concat([ from_or_stage_option(verb), stage_ref ])
      end
      parts.shelljoin
    end

    def payload
      {
        "key" => key,
        "label" => label,
        "command" => command,
        "next_action" => next_action
      }
    end

    def migration_selection
      @migration_selection ||= Hive::Conditions::Migration.selection(
        config: @config, stage: "#{task.stage_index}-#{task.stage_name}",
        projection: projection,
        rule: task.stage_name == "execute" ? execute_condition_rule : nil
      )
    end

    def condition_gate
      return nil unless task.stage_name == "execute"

      @condition_gate ||= Hive::Conditions::GateEvaluator.new(
        projection: projection, rule: execute_condition_rule
      ).evaluate(research: research_execution?, research_evidence: research_evidence?)
    end

    def condition_warning
      return nil unless migration_selection.effective == "shadow"
      return nil unless projection.to_h.dig("shadow_audit", "unexplained_mismatches").to_i.positive?

      "condition shadow mismatch"
    end

    private

    def action
      override = universal_action
      return override if override

      kind_action
    end

    def universal_action
      # A live task lock means `hive run` is already inside this task,
      # including pre-stage work such as auto-rebase. It must pre-empt
      # marker-derived workflow advice; otherwise status can offer a
      # duplicate runnable command that immediately hits ConcurrentRunError.
      return ACTIONS.fetch(:agent_running) if @live_task_lock

      # `:agent_working` overrides every (stage, marker) pair — a live
      # agent run on the task pre-empts whatever workflow advice the
      # state-machine would otherwise produce. When liveness signal is
      # passed and proves the agent isn't actually alive, classify as
      # :error immediately so consumers don't have to wait for the
      # daemon's StaleAgentHealer to rewrite the marker on disk.
      if marker.name == :agent_working
        return ACTIONS.fetch(:error) if stale_agent_reason
        return ACTIONS.fetch(:agent_running)
      end
      if marker.name == :error && marker.attrs["reason"].to_s == Hive::DraftPrReceipt::RECOVERABLE_REASON
        return ACTIONS.fetch(:recover_draft_pr)
      end
      return ACTIONS.fetch(:error) if marker.name == :error
      return ACTIONS.fetch(:manual_steering) if marker.name == :manual_steering

      nil
    end

    def kind_action
      stage = workflow_stage
      return ACTIONS.fetch(:error) unless stage

      case stage.kind
      # `:execute`/`:review_council`/`:finalize` route straight to the coding
      # runtime helpers with NO `coding_id?` guard — unlike the `:agent`/`:inert`
      # arm below, which gates on `coding_id?` via `coding_table_action`. That
      # asymmetry is deliberate and safe: these three kinds are coding-only by
      # construction. `DescriptorParser#parse_kind` rejects them for YAML
      # descriptors, and only `Workflows::Coding` declares them via `Stage.new`,
      # so no non-coding workflow can carry one. The helpers hardcode coding
      # semantics (`finalize`/`plan`/`execute` stage names, coding markers); the
      # guarantee that they only ever see a coding task lives in the kind space
      # itself, not in a runtime id check here.
      when :execute
        execute_action
      when :review_council
        review_action
      when :finalize
        finalize_action
      when :agent, :council, :inert
        # `|| generic_action(stage)` is the LIVE path for NON-coding
        # `:agent`/`:inert` workflows: `coding_table_action` returns nil for any
        # non-coding id. It is dead-for-coding — `coding_test.rb` pins every
        # coding `:agent`/`:inert` stage to a matching-`:kind` ACTION_DISPATCH
        # row, so the table always resolves for the only id that reaches it.
        # Coding `done`/`artifacts` behavior must therefore be edited in
        # `Coding::ACTION_DISPATCH`/the coding helpers, NOT in `generic_action`.
        coding_table_action(stage) || generic_action(stage)
      else
        generic_action(stage)
      end
    end

    def coding_table_action(stage)
      return nil unless Hive::Workflows.coding_id?(task_workflow.id)

      config = Hive::Workflows::Coding::ACTION_DISPATCH[stage.name]
      return nil unless config && config.fetch(:kind) == stage.kind

      if config[:handler]
        send(config.fetch(:handler))
      elsif marker.name == :complete && config[:complete]
        ACTIONS.fetch(config.fetch(:complete))
      else
        ACTIONS.fetch(config.fetch(:default))
      end
    end

    def generic_action(stage = workflow_stage)
      # `validate_workflow_stage!` runs at Task construction (task.rb), so a
      # real `Hive::Task` always resolves a stage here; this guard only
      # defends test doubles that bypass that construction-time invariant.
      return ACTIONS.fetch(:error) unless stage

      terminal = stage == task_workflow.stages.last

      case marker.name
      when :complete
        return ACTIONS.fetch(:error) if terminal && active_terminal_missing_deliverable?(stage)

        terminal ? ACTIONS.fetch(:done) : ACTIONS.fetch(:ready_to_advance)
      when :waiting
        ACTIONS.fetch(:generic_needs_input)
      when :none
        if terminal
          # A TERMINAL inert stage (e.g. the blank scaffold's `done`) has no
          # runner — `Resolver.resolve` raises `StageError` for `kind: :inert` —
          # and nowhere to advance. A task parked there is finished, so classify
          # it as archived; otherwise status/daemon would offer a `hive run`
          # that can only fail and the daemon would re-dispatch it every tick.
          # A terminal stage of any OTHER kind still has an agent, so it keeps
          # falling through to ready-to-run.
          stage.kind == :inert ? ACTIONS.fetch(:done) : ACTIONS.fetch(:generic_ready_to_run)
        else
          # Auto-advance a markerless inert NON-terminal stage (no agent to run)
          # past itself. Any non-inert kind (`:agent`, coding runtime kinds, or
          # nil — the gate is `stage.kind == :inert`, which excludes all of
          # them) must run rather than be approved past it. The entry-only restriction is
          # intentionally dropped: an inert NON-entry middle stage would
          # otherwise strand — `Resolver.resolve` raises `StageError` for
          # `kind: :inert`, so it can neither run nor advance.
          stage.kind == :inert ? ACTIONS.fetch(:ready_to_advance) : ACTIONS.fetch(:generic_ready_to_run)
        end
      else
        ACTIONS.fetch(:generic_ready_to_run)
      end
    end

    def active_terminal_missing_deliverable?(stage)
      return false unless [ :agent, :council ].include?(stage.kind)

      deliverable = stage.deliverable || stage.state_file
      path = File.join(task.folder, deliverable)
      !File.exist?(path) || File.size(path).zero?
    end

    def review_action
      case marker.name
      when :review_complete
        # A clean ad-hoc PR review parks at 6-review instead of advancing to
        # artifacts (the daemon must not auto-finalize a borrowed PR). Normal
        # tasks are unchanged.
        adhoc_task? ? ACTIONS.fetch(:review_complete_adhoc) : ACTIONS.fetch(:review_complete)
      when :review_stale, :review_ci_stale, :review_error
        ACTIONS.fetch(:review_stale)
      when :review_working
        # The review stage's own in-flight marker. Without this branch
        # the row falls through to :review_waiting and emits a
        # runnable `hive review … --from 6-review` command while review
        # is already active — running it would acquire-then-fail the
        # per-task lock with ConcurrentRunError. Treat it as in-flight
        # via the same :agent_running surface other stages use for
        # `:agent_working`. The TUI's verb-refusal flash + log-tail-on-
        # Enter path then kicks in for review-stage rows too.
        ACTIONS.fetch(:agent_running)
      when :review_waiting
        ACTIONS.fetch(:review_waiting)
      else
        ACTIONS.fetch(:review_ready)
      end
    end

    def brainstorm_action
      case marker.name
      when :complete
        ACTIONS.fetch(:brainstorm_complete)
      when :none
        # Markerless (:none) = nothing ran at this stage yet, so it's runnable
        # rather than an input gate; a genuine pause carries a real `:waiting`
        # marker (U6 — stops the phantom needs-input surface).
        ACTIONS.fetch(:generic_ready_to_run)
      else
        ACTIONS.fetch(:brainstorm_waiting)
      end
    end

    def execute_action
      if migration_selection.effective == "conditions"
        return condition_gate.eligible? ? ACTIONS.fetch(:execute_complete) : ACTIONS.fetch(:execute_waiting)
      end

      case marker.name
      when :execute_complete, :complete
        ACTIONS.fetch(:execute_complete)
      when :execute_stale
        ACTIONS.fetch(:execute_stale)
      when :execute_waiting
        return ACTIONS.fetch(:execute_stale) if legacy_execute_findings?

        ACTIONS.fetch(:execute_waiting)
      when :none
        # Markerless (:none) = nothing ran at this stage yet → runnable, not an
        # input gate; a real pause carries an `:execute_waiting` marker (U6).
        ACTIONS.fetch(:generic_ready_to_run)
      else
        # Any other marker at the execute stage is foreign/incoherent: the
        # runner only ever stamps execute_waiting/execute_complete/execute_stale/
        # :none here, and universal markers (agent_working/error/manual_steering)
        # are intercepted earlier. Fail loud rather than auto-running `hive run`
        # against a marker we don't recognize — for a foreign marker (terminal
        # OR non-terminal alike) "no auto-run" is strictly safer for the daemon
        # Policy than presuming the stage is runnable.
        ACTIONS.fetch(:error)
      end
    end

    def execute_condition_rule
      workflow_stage&.condition_policy ||
        Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
    end

    def research_execution?
      path = File.join(task.folder, "plan.md")
      result = Hive::PlanFrontmatter.read(path)
      result.valid? && result.data["execution_mode"].to_s == "research"
    end

    def research_evidence?
      return false unless research_execution?

      fact = projection.current_condition("ChangesPresent")
      fact&.dig("payload", "research_output_evidence") == true &&
        Array(fact["evidence"]).any? do |entry|
          entry["type"] == "file" && entry["purpose"] == "research_output"
        end
    end

    def load_projection(marker)
      folder = task.respond_to?(:folder) && task.folder
      if folder
        Hive::TaskProjection::Store.new(task_folder: folder).read(marker: marker)
      else
        Hive::TaskProjection.project(records: [], marker: marker)
      end
    end

    def projected_marker(value)
      data = value.respond_to?(:to_h) ? value.to_h : value
      compatibility = data&.dig("compatibility", "marker") ||
                      data&.dig("compatibility", "marker_fallback")
      return nil unless compatibility

      Hive::Markers::State.new(
        name: compatibility.fetch("name").to_sym,
        attrs: compatibility.fetch("attrs", {}), raw: nil
      )
    end

    def plan_action
      return ACTIONS.fetch(:plan_complete) if marker.name == :complete
      return ACTIONS.fetch(:error) if incomplete_plan_artifact?
      # Markerless (:none) with no plan run yet is runnable, not an input gate.
      # incomplete_plan_artifact? above already routes a crashed/empty plan run
      # to :error, so reaching here with :none means the plan agent simply has
      # not run (e.g. the task was moved into 3-plan via `hive approve` / a
      # manual mv / a crash before the run). Classify it ready_to_run so the
      # daemon dispatches the plan agent instead of skipping it as un-approvable
      # (plan-approval auto-dispatch requires :waiting/:complete) — without this
      # it wedges in 3-plan with a misleading "Needs your input" label. Mirrors
      # finalize_action's :none handling.
      return ACTIONS.fetch(:generic_ready_to_run) if marker.name == :none

      ACTIONS.fetch(:plan_waiting)
    end

    def finalize_action
      return ACTIONS.fetch(:error) if finalize_missing_pr_md?
      return finalize_complete_action if marker.name == :complete
      # Markerless (:none) = nothing ran at this stage yet → runnable, not an
      # input gate; a real pause carries a `:waiting` marker (U6).
      return ACTIONS.fetch(:generic_ready_to_run) if marker.name == :none

      ACTIONS.fetch(:finalize_waiting)
    end

    def finalize_complete_action
      return ACTIONS.fetch(:error) if finalize_missing_pr_url?
      return ACTIONS.fetch(:error) if finalize_pr_url_mismatch?
      return ACTIONS.fetch(:finalize_complete) if marker.attrs["is_draft"].to_s == "false"

      # Draft PR fallback: re-run finalize. After the artifacts-stage
      # renumber, :review_complete now routes to "hive artifacts" (the
      # 6-review → 7-artifacts verb), so we can't reuse it here. The
      # :artifacts_complete action carries the "Ready to finalize"
      # semantics this fallback wants TODAY — see the doc comment on
      # the ACTIONS entry above before changing either side.
      ACTIONS.fetch(:artifacts_complete)
    end

    # Markerless 7-artifacts rows still need their stage runner to write
    # artifact.md and the terminal marker before finalize is allowed.
    #
    # Production-dead: 7-artifacts now routes through
    # `Coding::ACTION_DISPATCH["artifacts"]` (complete/default), not this
    # method. Retained solely for the parity harness's `LegacyCaseTaskAction`,
    # which still exercises the old stage-name case path.
    def artifacts_action
      marker.name == :complete ? ACTIONS.fetch(:artifacts_complete) : ACTIONS.fetch(:artifacts_ready)
    end

    # Returns :agent_died, :agent_orphaned, or nil. Mirrors
    # Hive::Daemon::StaleAgentHealer's classification so the in-memory
    # action surface matches the disk-side healing, even before the
    # daemon has ticked.
    def stale_agent_reason
      return nil unless marker.name == :agent_working

      case @pid_alive
      when false
        :agent_died
      when nil
        return nil unless @state_file_mtime && marker.attrs["pid"].to_s.empty?

        age = Time.now - @state_file_mtime
        age > @agent_marker_grace_sec ? :agent_orphaned : nil
      else
        nil
      end
    end

    public

    def diagnostic
      diagnostic_builder.to_h
    end

    def next_action
      diagnostic_builder.next_action
    end

    private

    # The diagnostics concern lives in the Diagnostic collaborator; it's a
    # pure function of (task, marker) plus the classification context the
    # diagnostic depends on (this action's key, its rerun command, and the
    # state predicates that also drive classification). Memoized so a single
    # `hive status` row builds it once.
    def diagnostic_builder
      @diagnostic_builder ||= Diagnostic.new(
        task: task,
        marker: marker,
        action_key: key,
        rerun_command: command,
        incomplete_plan_artifact: incomplete_plan_artifact?,
        finalize_missing_pr_md: finalize_missing_pr_md?,
        finalize_missing_pr_url: finalize_missing_pr_url?,
        finalize_pr_url_mismatch: finalize_pr_url_mismatch?,
        legacy_execute_findings: legacy_execute_findings?,
        stale_agent_reason: stale_agent_reason,
        condition_gate: migration_selection.effective == "conditions" ? condition_gate : nil,
        state_file_mtime: @state_file_mtime,
        project_name: project_name,
        project_count: @project_count
      )
    end

    public

    # Canonical freshness key for a (marker.name, marker.attrs) pair.
    # Lifted to a class method so producer + consumer (DiagnosisAgent
    # write side and TaskAction read side) call one canonical impl and
    # cannot drift. Re-used by:
    #   - this class's fresh_diagnosis_artifact (consumer side: validates
    #     diagnostics/red-status.md's frontmatter against the current
    #     marker before trusting the artifact body)
    #   - Hive::DiagnosisAgent#artifact_body (producer side: writes the
    #     signature into the artifact frontmatter at spawn time) and
    #     freshness gate (compares dispatch-time vs write-time signature)
    #   - Hive::Tui::Update.apply_red_status_detail_snapshot (TUI live-
    #     update gate: detects marker rotation while the operator is in
    #     the red-status detail view)
    #
    # Marker attrs are coerced to String so a future non-string value
    # (Integer pass attr, Time stamp) cannot silently change the digest
    # via Hash#to_s formatting.
    def self.marker_signature(marker)
      attrs = (marker.attrs || {}).sort_by { |key, _value| key.to_s }
                                  .map { |key, value| "#{key}=#{value}" }
      ::Digest::SHA256.hexdigest(([ marker.name.to_s ] + attrs).join("\n"))
    end

    # Class-level predicate so TUI consumers (KeyMap#red_detail_row?,
    # BubbleModel#red_status_autofix_force?) share the exact same logic
    # as the JSON producer here. Previously the rule lived in three
    # near-identical implementations coordinated only by comments;
    # drift would silently desync producer + consumers. See PR #84
    # review finding #17.
    def self.max_passes_review_stale_with_escalations?(folder:, marker_name:, attrs:)
      return false unless marker_name.to_s == "review_stale"

      pass = (attrs || {})["pass"].to_s
      return false unless pass.match?(/\A[1-9]\d*\z/)

      File.exist?(File.join(folder.to_s, "reviews", "escalations-#{format('%02d', pass.to_i)}.md"))
    end

    # Shared prefix for every `hive <verb> <slug>` builder: the verb, the
    # slug, and the `--project` qualifier added only when more than one
    # project is in view (a single-project status never needs it). Callers
    # append their own `--from`/`--stage` suffix and `shelljoin`.
    def command_prefix(verb)
      parts = [ "hive", verb, task.slug ]
      parts.concat([ "--project", project_name ]) if project_name && @project_count > 1
      parts
    end

    def legacy_execute_findings?
      task.stage_name == "execute" &&
        marker.name == :execute_waiting &&
        marker.attrs["findings_count"].to_i.positive?
    end

    def finalize_missing_pr_md?
      task.stage_name == "finalize" &&
        marker.name == :none &&
        task.state_file.to_s.end_with?("/pr.md") &&
        !File.exist?(task.state_file)
    end

    def finalize_missing_pr_url?
      task.stage_name == "finalize" &&
        marker.name == :complete &&
        task.state_file.to_s.end_with?("/pr.md") &&
        frontmatter_pr_url.empty?
    end

    def finalize_pr_url_mismatch?
      task.stage_name == "finalize" &&
        marker.name == :complete &&
        task.state_file.to_s.end_with?("/pr.md") &&
        !frontmatter_pr_url.empty? &&
        marker.attrs["pr_url"].to_s != frontmatter_pr_url
    end

    def frontmatter_pr_url
      @frontmatter_pr_url ||= begin
        parsed = state_file_frontmatter
        parsed.fetch("pr_url", "").to_s
      end
    end

    # True when this is an ad-hoc PR review (`source: ad-hoc` in the review
    # stage's task.md). Used to park a clean ad-hoc review at 6-review rather
    # than auto-advancing it. casecmp? matches the review stage's reader so a
    # drifted `source: Ad-Hoc` routes consistently. An unreadable source falls
    # back to non-ad-hoc (state_file_frontmatter swallows SystemCallError → {}),
    # so a normal task is never mis-parked.
    def adhoc_task?
      state_file_frontmatter["source"].to_s.strip.casecmp?("ad-hoc")
    end

    def state_file_frontmatter
      return {} unless File.exist?(task.state_file)

      content = File.read(task.state_file)
      match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      return {} unless match

      parsed = YAML.safe_load(match[1]) || {}
      parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
    rescue Psych::Exception, SystemCallError
      {}
    end

    def incomplete_plan_artifact?
      task.stage_name == "plan" &&
        marker.name == :none &&
        task.state_file.to_s.end_with?("/plan.md") &&
        ((File.exist?(task.state_file) && File.zero?(task.state_file)) ||
          (!File.exist?(task.state_file) && plan_run_started?))
    end

    def plan_run_started?
      log_dirs.any? { |dir| Dir[File.join(dir, "plan-*.log")].any? }
    end

    # The task's log directories. A class method shared with
    # TaskAction::Diagnostic so the two concerns can't drift on where logs live.
    def self.log_dirs(task)
      [
        (task.log_dir if task.respond_to?(:log_dir)),
        File.join(task.folder, "logs")
      ].compact.uniq
    end

    def log_dirs = self.class.log_dirs(task)

    # Workflow verbs (brainstorm/plan/develop/pr/archive) use --from for
    # the source-stage assertion; coding recovery verbs (findings/accept-
    # finding/reject-finding) use --stage for ambiguity disambiguation.
    def from_or_stage_option(verb)
      Hive::Workflows.workflow_verb?(verb) ? "--from" : "--stage"
    end

    # Workflow verbs always carry --from for retry idempotency.
    # Coding recovery verbs only when ambiguity demands disambiguation.
    def include_stage_filter?(verb)
      Hive::Workflows.workflow_verb?(verb) || @stage_collision
    end

    def command_stage_dir(stage)
      # For a real coding Task the `"#{index}-#{name}"` string form is provably
      # equal to `stage.dir`: `validate_workflow_stage!` (task.rb) pins the
      # task's stage_index/stage_name to the descriptor stage at construction.
      # The string form is kept on the coding branch so the command echoes the
      # task's own on-disk stage dir rather than re-deriving it from the
      # descriptor.
      return "#{task.stage_index}-#{task.stage_name}" if Hive::Workflows.coding_id?(task_workflow.id)

      stage.dir
    end

    def workflow_stage
      task_workflow.stage_named(task.stage_name)
    end

    def task_workflow
      workflow = task.respond_to?(:workflow) ? task.workflow : nil
      workflow || Hive::Workflows::Registry.default
    end
  end
end
