require "hive/bot/brainstorm_parser"
require "hive/bot/dispatch_request_writer"
require "hive/commands/answer"
require "hive/commands/approve"
require "hive/commands/drop"
require "hive/config"
require "hive/daemon/dispatch_request_queue"
require "hive/git_ops"
require "hive/lock"
require "hive/plan_review/automation"
require "hive/plan_review/decision_service"
require "hive/plan_review/projection"
require "hive/plan_review/transition_guard"
require "hive/recovery/api"
require "hive/stages"
require "hive/task"
require "hive/task_action"
require "hive/task_closure"
require "hive/task_resolver"

module TaskMutations
  def closure_preview(input)
    Hive::TaskClosure.preview(
      task: native_task_for_closure, project: project.name, input: normalized_closure_input(input)
    )
  end

  def close_with_evidence!(input:, preview_digest:, operator:, authorized:)
    Hive::TaskClosure.confirm!(
      task: native_task_for_closure,
      project: project.name,
      input: normalized_closure_input(input),
      preview_digest: preview_digest,
      operator: operator,
      channel: "web",
      authorized: authorized
    )
  end

  extend ActiveSupport::Concern

  STAGE_VERB_BY_ACTION = Hive::TaskAction::READY_COMMANDS.select do |_action, verb|
    Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS.include?(verb)
  end.freeze

  def approve!(from: nil, to: nil, force: false)
    Hive::Commands::Approve.new(
      slug,
      project: project.name,
      from:,
      to:,
      force:,
      json: true
    ).call
  end

  def reject!(from: nil, to: nil)
    approve!(from:, to: to || prior_gate(from), force: true)
  end

  def drop!(from: nil)
    Hive::Commands::Drop.new(slug, project: project.name, from:, json: false).call
  end

  def run!(expected_action:, expected_stage:)
    unless STAGE_VERB_BY_ACTION.key?(expected_action.to_s)
      raise Hive::Error, "unknown dispatch action: #{expected_action.inspect}"
    end

    action = dispatch_action
    stage = self["stage"].to_s
    unless action.present? && expected_action.to_s == action && expected_stage.to_s == stage
      raise Hive::Error, "task state changed — reload the page before running this stage"
    end

    verb = STAGE_VERB_BY_ACTION.fetch(action)
    argv = [ "hive", verb, slug, "--project", project.name ]
    argv += [ verb == "run" ? "--stage" : "--from", stage ]
    reference = Hive::Bot::DispatchRequestWriter.dispatch!(
      project: project.name,
      slug:,
      argv:,
      trigger: "web"
    )
    {
      ok: true,
      request_id: reference.request_id,
      attempt_id: reference.attempt_id,
      state: reference.state,
      dispatch_status: reference.status,
      argv:
    }
  rescue ArgumentError => e
    raise Hive::Error, "cannot queue this dispatch: #{e.message}"
  end

  def recover!
    marker = self["marker"]
    marker_name = marker.to_s.downcase
    if marker_name.empty? || %w[none agent_working].include?(marker_name)
      raise Hive::Error, "nothing to recover: #{slug} has no failure marker (its state changed — reload the page)"
    end
    unless Hive::Recovery::API.recoverable_marker?(marker)
      raise Hive::Error, "Hive has no automatic recovery for this state - open it on a laptop."
    end
    if Hive::Recovery.intervention_required?(
      marker: marker, attrs: self["attrs"] || {}, folder: folder
    )
      raise Hive::Error,
            "edit the current review escalation, then confirm the retry from the TUI with `r`"
    end

    Hive::Recovery::API.recover!(
      row: self,
      project: project.name,
      requestor: "web"
    )
  end

  def intervene!(message, binding:)
    text = message.to_s.strip
    raise Hive::Error, "intervene message is required" if text.empty?
    raise Hive::Error, "question binding is required — reload the page" if binding.to_s.empty?

    brainstorm_path!
    receipt = write_bound_answer!(binding, text)
    { ok: true, question_n: receipt.dig("slot", "question_number") }
  end

  def answer_questions!(answers)
    brainstorm_path!(noun: "answers")
    provided = (answers || {}).to_h
                              .transform_keys(&:to_s)
                              .transform_values { |value| value.to_s.strip }
                              .reject { |binding, text| binding.empty? || text.empty? }
    raise Hive::Error, "no answers provided" if provided.empty?

    inventory = Hive::Commands::Answer.inventory(slug, project: project.name)
    open_bindings = inventory.fetch("slots").reject { |slot| slot.fetch("answered") }
                             .map { |slot| slot.fetch("binding") }
    stale = provided.keys - open_bindings
    if stale.any?
      raise Hive::Error,
            "one or more questions changed while you were answering — reload the page"
    end

    answered = provided.map do |binding, text|
      write_bound_answer!(binding, text).dig("slot", "question_number")
    end
    { ok: true, answered: answered }
  end

  def plan_review_action!(action:, review_id:, task_generation:, policy_fingerprint:,
                          expected_artifact_digest:, target_fingerprint: nil,
                          answer: nil, coverage: nil, level: nil, reason: nil,
                          operator:, authorized:, service_factory: nil, resumer: nil)
    native = Hive::TaskResolver.new(folder, project_filter: project.name).resolve
    assert_current_plan_review!(native)
    normalized_action = action.to_s.tr("-", "_")
    service_factory ||= ->(task) { Hive::PlanReview::DecisionService.new(task:) }
    result = service_factory.call(native).apply(
      action: normalized_action, review_id:, task_generation: task_generation.to_s,
      policy_fingerprint:, expected_artifact_digest:, target_fingerprint:,
      value: Hive::PlanReview::DecisionService.action_value(
        normalized_action, answer:, coverage:, level:
      ),
      reason:, origin: "web", operator:, authorized:
    )
    projection = if result.applied
      (resumer || method(:resume_plan_review_after_decision!)).call(native, normalized_action)
    else
      result.projection
    end
    { applied: result.applied, decision: result.decision, projection: }
  end

  private

  def assert_current_plan_review!(task)
    projection = Hive::PlanReview::Projection.load(task_folder: task.folder)
    config = Hive::Config.load(task.project_root)
    freshness = Hive::PlanReview::TransitionGuard.freshness(
      task:, projection:, config:
    )
    return if freshness.fetch("status") == "current"

    raise Hive::PlanReview::StaleDecision,
          "plan review changed; refresh the current observation"
  end

  def resume_plan_review_after_decision!(task, action)
    projection = nil
    Hive::Lock.with_commit_lock(task.hive_state_path) do
      projection = Hive::PlanReview::Automation.run!(task: Hive::Task.new(task.folder))
      Hive::GitOps.new(task.project_root).hive_commit(
        stage_name: "#{task.stage_index}-#{task.stage_name}", slug: task.slug,
        action: "resume plan review after #{action} from web"
      )
    end
    projection
  end

  def native_task_for_closure
    Hive::TaskResolver.new(folder, project_filter: project.name).resolve
  end

  def normalized_closure_input(input)
    values = input.respond_to?(:to_h) ? input.to_h : {}
    values = values.transform_keys(&:to_s)
    evidence = Array(values["evidence"]).flat_map { |entry| entry.to_s.lines }
    {
      "reason" => values["reason"],
      "evidence" => Array(evidence).map(&:strip).reject(&:empty?),
      "successor" => values["successor"],
      "attestation" => values["attestation"]
    }
  end

  def prior_gate(from)
    return Hive::Stages::DIRS.first if from.blank?

    parsed = Hive::Stages.parse(from)
    raise Hive::Error, "unknown stage #{from.inspect}" unless parsed

    Hive::Stages.prev_dir(parsed.first) || Hive::Stages::DIRS.first
  end

  def brainstorm_path!(noun: "intervene")
    path = File.join(folder.to_s, "brainstorm.md")
    return path if File.file?(path)

    raise Hive::Error, "#{noun} #{noun == "answers" ? "are" : "is"} only available while a task awaits a brainstorm answer"
  end

  def write_bound_answer!(binding, text)
    receipt = Hive::Commands::Answer.write(
      slug,
      project: project.name,
      binding: binding,
      answer: text
    )
    return receipt if %w[written idempotent].include?(receipt.fetch("outcome"))

    if receipt.fetch("reason") == "task_lock_busy"
      raise Hive::Error, receipt.fetch("acknowledgement")
    end

    raise Hive::Error,
          "question changed while you were answering it (#{receipt.fetch('reason')}) — reload the page"
  end
end
