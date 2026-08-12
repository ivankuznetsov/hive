class Tasks::TimelinesController < Tasks::BaseController
  def show
    if params[:cursor].present? && params[:raw_cursor].present?
      raise Hive::TaskWorkspace::Timeline::InvalidCursor,
            "choose either an older-history cursor or a raw-group cursor"
    end

    @timeline = task_workspace_builder.timeline(
      cursor: bounded_cursor(params[:cursor]),
      raw_cursor: bounded_cursor(params[:raw_cursor])
    )
    respond_to do |format|
      format.html
      format.json { render json: @timeline }
    end
  end

  private

  def bounded_cursor(value)
    return nil if value.blank?

    cursor = value.to_s
    if cursor.bytesize > Hive::TaskWorkspace::Timeline::CursorCodec::MAX_TOKEN_BYTES
      raise Hive::TaskWorkspace::Timeline::InvalidCursor, "timeline cursor is too large"
    end
    cursor
  end
end
