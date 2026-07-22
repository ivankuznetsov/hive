require "test_helper"
require "hive/bot/notification_builders"
require "hive/bot/row_actions"
require "hive/bot/router"
require "hive/bot/status_watcher"
require "hive/bot/supervisor"
require "hive/markers"
require "hive/stages/base"
require "hive/workflows"

class HiveBotButtonCoverageTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  # Derived from the closed marker registry (KNOWN_NAMES — which includes
  # manual_steering) plus the marker-absent `none` state, so a newly added
  # marker is swept across every (action, stage, workflow) without a hand-edit
  # here. KNOWN_NAMES already subsumes TERMINAL_MARKER_NAMES and PAUSE_MARKERS.
  MARKERS = (Hive::Markers::KNOWN_NAMES.map(&:downcase) + %w[none]).uniq.freeze

  # Derived from the closed workflow registry so a third workflow extends the
  # "every (action, marker, stage, workflow)" guarantee automatically instead
  # of escaping the sweep.
  WORKFLOWS = Hive::Workflows::Registry.all.map { |descriptor| descriptor.id.to_s }.freeze

  def row(action:, marker:, stage:, workflow: "coding", attrs: {}, diagnostic: nil)
    Row.new(
      project: "hive",
      slug: "slug-260624-abcd",
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      action: action,
      action_label: action,
      suggested_command: nil,
      diagnostic: diagnostic
    )
  end

  def test_every_representative_row_has_resolvable_button_or_is_suppressed
    rows = Hive::Schemas::TaskActionKind::ALL.product(MARKERS, stages, WORKFLOWS).map do |action, marker, stage, workflow|
      row(action: action, marker: marker, stage: stage, workflow: workflow, attrs: attrs_for(marker),
          diagnostic: diagnostic_for(action, marker))
    end

    rows.each do |candidate|
      resolution = Hive::Bot::RowActions.resolve(candidate)
      assert_status_surface_matches_resolver(candidate, resolution)
      assert_next_step_hint_present(candidate)
      next if resolution.suppress || resolution.actions.empty?

      primary = resolution.actions.find(&:primary) || resolution.actions.first
      assert_resolvable_callback(primary.callback, candidate)
      if candidate.action.to_s == Hive::Schemas::TaskActionKind::NEEDS_INPUT
        refute_dead_details_only(candidate, resolution)
      end
    end
  end

  def test_per_marker_regressions_from_needs_input_report
    cases = {
      "plan_waiting" => row(action: "needs_input", marker: "waiting", stage: "3-plan"),
      "execute_waiting" => row(action: "needs_input", marker: "execute_waiting", stage: "4-execute"),
      "finalize_waiting" => row(action: "needs_input", marker: "waiting", stage: "8-finalize"),
      "generic_needs_input" => row(action: "needs_input", marker: "waiting", stage: "1-inbox", workflow: "content"),
      "none" => row(action: "needs_input", marker: "none", stage: "4-execute"),
      "complete" => row(action: "needs_input", marker: "complete", stage: "4-execute")
    }

    assert_equal [ :approve_plan, :details ], roles(cases.fetch("plan_waiting"))
    assert_equal [ :rerun, :details ], roles(cases.fetch("execute_waiting"))
    assert_equal [ :rerun, :details ], roles(cases.fetch("finalize_waiting"))
    assert_equal [ :rerun ], roles(cases.fetch("generic_needs_input"))
    assert Hive::Bot::RowActions.resolve(cases.fetch("none")).suppress
    assert Hive::Bot::RowActions.resolve(cases.fetch("complete")).suppress
  end

  # `recovery?` fires for ANY action when the marker is one of these (and for
  # the recover_*/error actions regardless of marker). Excluding them from the
  # "does this kind map?" sweep is what makes the guard sound: otherwise every
  # kind — including a genuinely inert one — resolves via the incidental
  # error-marker recovery path and the guard passes vacuously.
  RECOVERY_MARKERS = %w[review_error review_stale review_ci_stale execute_stale error].freeze

  # Kinds with no actionable chat surface of their own. They legitimately
  # resolve ONLY via a recovery marker; on every coherent (non-recovery)
  # marker they must be non-actionable. A future inert kind has to be listed
  # here AND proven non-actionable below — it can no longer ride the
  # error-marker recovery path into the mapped set unnoticed.
  #
  # review_parked is a clean ad-hoc PR review parked at 6-review: complete,
  # non-advancing (command: nil), with no chat button of its own — RowActions
  # has no branch for it, so it falls through to an empty Resolution on every
  # coherent marker. Inert by construction.
  INERT_KINDS = %w[
    admission_error agent_running archived manual_steering recover_draft_pr review_parked
  ].freeze

  def test_new_task_action_kind_requires_row_action_decision
    expected = %w[
      needs_input recover_draft_pr recover_execute recover_review error ready_to_brainstorm
      ready_to_plan ready_to_develop ready_to_open_pr ready_for_review
      ready_to_artifacts ready_to_finalize ready_to_archive ready_to_advance
      ready_to_run admission_error agent_running archived manual_steering review_parked
    ]
    assert_equal expected.sort, Hive::Schemas::TaskActionKind::ALL.sort,
                 "a new TaskActionKind must be classified as actionable or inert below"

    non_recovery = MARKERS - RECOVERY_MARKERS
    mapped = Hive::Schemas::TaskActionKind::ALL.select do |action|
      non_recovery.any? do |marker|
        stages.any? do |stage|
          resolution = Hive::Bot::RowActions.resolve(row(action: action, marker: marker, stage: stage))
          resolution.suppress || !resolution.actions.empty?
        end
      end
    end

    # Every NON-inert kind must earn its place through a coherent (non-recovery)
    # marker — its own needs_input / ready / recovery-by-action decision — not
    # the incidental error-marker recovery path.
    assert_equal (expected - INERT_KINDS).sort, mapped.sort,
                 "actionable kinds must resolve via their own surface, not only via an error marker"

    # Inert kinds must be genuinely non-actionable on coherent markers, so a
    # future inert kind can't slip through by resolving only on error markers.
    INERT_KINDS.each do |action|
      non_recovery.product(stages).each do |marker, stage|
        resolution = Hive::Bot::RowActions.resolve(row(action: action, marker: marker, stage: stage))
        refute resolution.suppress, "inert #{action} must not suppress on coherent marker=#{marker}"
        assert_empty resolution.actions, "inert #{action} must offer no action on coherent marker=#{marker}"
      end
    end
  end

  private

    def stages
      @stages ||= Hive::Workflows::Registry.all.flat_map(&:stage_dirs).uniq
    end

    def roles(candidate)
      Hive::Bot::RowActions.resolve(candidate).actions.map(&:role)
    end

    def attrs_for(marker)
      case marker.to_s
      when "review_waiting" then { "pass" => "1" }
      when "review_error" then { "phase" => "fix", "reason" => "timeout", "pass" => "1" }
      when "review_stale" then { "pass" => "2" }
      when "execute_waiting" then { "reason" => "no_worktree_changes" }
      else {}
      end
    end

    def diagnostic_for(action, marker)
      return nil unless %w[recover_execute recover_review error].include?(action.to_s)
      return nil if marker.to_s == "execute_stale"

      { "suggested_next_action" => { "kind" => "retry", "command" => "hive run slug --json" } }
    end

    # next_step_hint now fails loud (raises) on a primary role it has no hint
    # for, instead of silently degrading a new role to the laptop hint. Sweep
    # every representative row through it so a new primary-capable role added
    # without a hint is caught here rather than shipped.
    def assert_next_step_hint_present(candidate)
      hint = Hive::Bot::Supervisor.allocate.send(:next_step_hint, candidate)
      assert_kind_of String, hint, "next_step_hint must map a hint for #{label(candidate)}"
      refute_empty hint, "next_step_hint must not be blank for #{label(candidate)}"
    end

    def assert_status_surface_matches_resolver(candidate, resolution)
      button = Hive::Bot::Supervisor.allocate.send(:status_action_button, candidate)
      should_render = !resolution.suppress && resolution.actions.any?
      if should_render
        refute_nil button, "expected /status button for #{label(candidate)}"
        primary = resolution.actions.find(&:primary) || resolution.actions.first
        assert_equal primary.callback, Hive::Bot::NotificationBuilders.resolve_callback(button.fetch(:callback_data)),
                     "status callback for #{label(candidate)}"
      else
        assert_nil button, "expected no /status button for #{label(candidate)}"
      end
    end

    def assert_resolvable_callback(callback, candidate)
      intent = Hive::Bot::Router.allocate.send(:callback_intent, callback)
      refute_equal :unknown, intent, "unroutable callback #{callback.inspect} for #{label(candidate)}"
    end

    def refute_dead_details_only(candidate, resolution)
      return unless resolution.actions.map(&:role) == [ :details ]
      return if Hive::Bot::RowActions.terminal_details?(candidate)

      flunk "needs_input row has only Details for #{label(candidate)}"
    end

    def label(candidate)
      "action=#{candidate.action} marker=#{candidate.marker} stage=#{candidate.stage} workflow=#{candidate.workflow}"
    end
end
