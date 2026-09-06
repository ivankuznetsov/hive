require "hive/commands/brainstorm_suggestion"
require "stringio"

class Tasks::BrainstormSuggestionsController < Tasks::BaseController
  def create
    receipt = Hive::Commands::BrainstormSuggestion.new(
      "retry",
      target: @task.folder,
      project: @project.name,
      task_roots: [ @task.folder ],
      question: params.require(:question),
      binding: params.require(:binding),
      json: true,
      output: StringIO.new
    ).call
    unless receipt.fetch("status") == "updated"
      raise Hive::Error, retry_error(receipt)
    end

    redirect_to task_path(@project.name, @task.slug, source: @task_source),
                notice: "A replacement suggestion was requested"
  end

  private

  def retry_error(receipt)
    case receipt.fetch("status")
    when "stale" then "suggestion changed — reload the page before retrying"
    when "invalid_state" then "this suggestion cannot be retried in its current state"
    when "lock_busy" then "suggestion state is busy — retry shortly"
    else "suggestion is no longer available"
    end
  end
end
