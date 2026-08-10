class Tasks::AnswersController < Tasks::BaseController
  def create
    raw = params[:answers]
    answers = raw.respond_to?(:permit) ? raw.permit(*raw.keys) : raw
    answered = @task.answer_questions!(answers)[:answered]
    redirect_to task_path(@project.name, @task.slug, source: @task_source),
                notice: "Recorded #{answered.size == 1 ? "answer" : "answers"} to Q#{answered.join(", Q")}"
  end
end
