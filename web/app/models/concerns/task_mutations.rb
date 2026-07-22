require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"
require "hive/bot/dispatch_request_writer"
require "hive/bot/handlers/recovery_sequence"
require "hive/bot/notification_builders"
require "hive/commands/approve"
require "hive/commands/drop"
require "hive/daemon/dispatch_request_queue"
require "hive/stages"
require "hive/task_action"

module TaskMutations
  extend ActiveSupport::Concern

  STAGE_VERB_BY_ACTION = Hive::TaskAction::READY_COMMANDS.select do |_action, verb|
    Hive::Daemon::DispatchRequestQueue::ALLOWED_VERBS.include?(verb)
  end.freeze

  RecoveryRow = Data.define(:marker, :attrs)

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
    attrs = (self["attrs"] || {}).to_h.transform_keys(&:to_s)
    marker_name = marker.to_s.downcase
    if marker_name.empty? || %w[none agent_working].include?(marker_name)
      raise Hive::Error, "nothing to recover: #{slug} has no failure marker (its state changed — reload the page)"
    end
    if Hive::Bot::Handlers::RecoverySequence.manual_only?(marker, attrs)
      raise Hive::Error, Hive::Bot::Handlers::RecoverySequence.manual_only_text(marker, attrs)
    end

    match_attr = Hive::Bot::NotificationBuilders.recovery_match_attr(RecoveryRow.new(marker, attrs))
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: project.name,
      slug:,
      stage: self["stage"],
      marker:,
      match_attr:,
      workflow: self["workflow"]
    )
    raise Hive::Error, "no retry verb for stage #{self["stage"].inspect}" if commands.empty?

    enqueue_recovery(commands)
  end

  def intervene!(message)
    text = message.to_s.strip
    raise Hive::Error, "intervene message is required" if text.empty?

    brainstorm_path = brainstorm_path!
    question = Hive::Bot::BrainstormParser.next_unanswered_question(
      Hive::Bot::BrainstormParser.parse(brainstorm_path)
    )
    raise Hive::Error, "no unanswered brainstorm question remains for this task" unless question

    write_answer!(brainstorm_path, question.n, text)
    { ok: true, question_n: question.n }
  end

  def answer_questions!(answers)
    brainstorm_path = brainstorm_path!(noun: "answers")
    provided = (answers || {}).to_h
                              .transform_keys { |key| Integer(key, exception: false) }
                              .transform_values { |value| value.to_s.strip }
                              .reject { |number, text| number.nil? || text.empty? }
    raise Hive::Error, "no answers provided" if provided.empty?

    open_numbers = Hive::Bot::BrainstormParser.unanswered_questions(
      Hive::Bot::BrainstormParser.parse(brainstorm_path)
    ).map(&:n)
    stale = provided.keys - open_numbers
    if stale.any?
      raise Hive::Error,
            "question(s) #{stale.sort.join(", ")} are no longer open — the brainstorm may have moved on; reload the page"
    end

    provided.keys.sort.each { |number| write_answer!(brainstorm_path, number, provided.fetch(number)) }
    { ok: true, answered: provided.keys.sort }
  end

  private

  def prior_gate(from)
    return Hive::Stages::DIRS.first if from.blank?

    parsed = Hive::Stages.parse(from)
    raise Hive::Error, "unknown stage #{from.inspect}" unless parsed

    Hive::Stages.prev_dir(parsed.first) || Hive::Stages::DIRS.first
  end

  def enqueue_recovery(commands)
    request_id = Hive::Bot::DispatchRequestWriter.generate_request_id
    first, *remaining = commands
    if remaining.any?
      Hive::Bot::DispatchRequestWriter.write_sequence!(request_id:, remaining_argvs: remaining)
    end
    begin
      Hive::Bot::DispatchRequestWriter.write!(
        project: project.name,
        slug:,
        argv: first,
        trigger: "web_recover",
        request_id:
      )
    rescue StandardError
      Hive::Bot::DispatchRequestWriter.discard_sequence!(request_id:) if remaining.any?
      raise
    end
    request_id
  end

  def brainstorm_path!(noun: "intervene")
    path = File.join(folder.to_s, "brainstorm.md")
    return path if File.file?(path)

    raise Hive::Error, "#{noun} #{noun == "answers" ? "are" : "is"} only available while a task awaits a brainstorm answer"
  end

  def write_answer!(path, question_number, text)
    result = Hive::Bot::BrainstormAnswerWriter.append!(
      brainstorm_path: path,
      question_n: question_number,
      answer_text: text
    )
    return if result == :written

    raise Hive::Error, "could not record answer to Q#{question_number} (#{result})"
  end
end
