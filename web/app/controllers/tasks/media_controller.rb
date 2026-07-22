class Tasks::MediaController < Tasks::BaseController
  def show
    path = @task.media_path(params[:filename])
    unless path
      Rails.logger.warn("media file unresolved for #{params[:slug]}: #{params[:filename].inspect}")
      return head :not_found
    end

    expires_in 60.seconds, public: false
    send_file path,
              type: Rack::Mime.mime_type(File.extname(path), "application/octet-stream"),
              disposition: "inline"
  end
end
