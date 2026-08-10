class Tasks::ClosuresController < Tasks::BaseController
  def new
    @closure_input = {
      "reason" => "already_delivered",
      "evidence" => [],
      "successor" => nil,
      "attestation" => nil
    }
  end

  def create
    @closure_input = closure_params.to_h
    @closure_input["evidence"] = Array(@closure_input["evidence"])
    digest = params[:preview_digest].to_s
    if digest.empty?
      @preview = @task.closure_preview(@closure_input)
      return render :new, status: @preview.valid? ? :ok : :unprocessable_entity
    end

    receipt = @task.close_with_evidence!(
      input: @closure_input,
      preview_digest: digest,
      operator: operator_label,
      authorized: operator_access?
    )
    redirect_to task_path(@project.name, @task.slug),
                notice: "Archived as #{receipt.fetch('reason').tr('_', ' ')}."
  end

  private

  def closure_params
    params.permit(:reason, :successor, :attestation, evidence: [])
  end
end
