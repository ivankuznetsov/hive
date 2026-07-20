class Tasks::AnswersController < Tasks::BaseController
  before_action :load_task

  def create
    raw = params[:answers]
    answers = raw.respond_to?(:permit) ? raw.permit(*raw.keys) : raw
    answered = dispatcher.answer_questions(folder: @task.folder, answers:)[:answered]
    redirect_to task_path(@project["name"], params[:slug]),
                notice: "Recorded #{answered.size == 1 ? "answer" : "answers"} to Q#{answered.join(", Q")}"
  end
end
