require "hive/bot/dispatch_request_writer"
require "hive/commands/approve"
require "hive/commands/new"

module Hive
  module Web
    class Dispatcher
      STAGE_VERB_BY_ACTION = {
        "ready_to_brainstorm" => "brainstorm",
        "ready_to_plan" => "plan",
        "ready_to_develop" => "develop",
        "ready_to_open_pr" => "open-pr",
        "ready_for_review" => "review",
        "ready_to_artifacts" => "artifacts",
        "ready_to_finalize" => "finalize",
        "ready_to_archive" => "archive"
      }.freeze

      def approve(slug:, project:, from: nil, to: nil, force: false)
        Hive::Commands::Approve.new(
          slug,
          project: project,
          from: from,
          to: to,
          force: force,
          json: true
        ).call
      end

      def dispatch(slug:, project:, action:, stage: nil)
        verb = STAGE_VERB_BY_ACTION.fetch(action.to_s) { action.to_s }
        argv = [ "hive", verb, slug, "--project", project ]
        argv += [ "--from", stage ] if stage
        request_id = Hive::Bot::DispatchRequestWriter.write!(
          project: project,
          slug: slug,
          argv: argv,
          trigger: "web"
        )
        { ok: true, request_id: request_id, argv: argv }
      end

      def new_idea(project:, text:)
        Hive::Commands::New.new(project, text).call
      end
    end
  end
end
