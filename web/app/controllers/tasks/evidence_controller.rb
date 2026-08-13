class Tasks::EvidenceController < Tasks::BaseController
  def show
    file = @task.outcome_evidence_file(params[:attempt_id], params[:digest])
    unless file
      Rails.logger.warn(
        "outcome evidence unresolved for #{params[:slug]}: " \
        "#{params[:attempt_id].inspect}/#{params[:digest].to_s.first(12).inspect}"
      )
      return head :not_found
    end

    expires_in 60.seconds, public: false
    send_file_headers!(
      filename: file.fetch("filename"),
      type: file.fetch("content_type"),
      disposition: file.fetch("disposition")
    )
    response.headers["Content-Length"] = file.fetch("bytes").to_s
    self.response_body = file.fetch("body")
  end
end
