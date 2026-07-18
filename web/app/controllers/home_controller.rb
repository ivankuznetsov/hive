class HomeController < BoardController
  def index
    @work_view = default_work_view
    if @work_view == "grid"
      @payload = StatusBroadcaster.snapshot
      @projects = StatusVisibility.projects(@payload)
      @daemon_status = daemon_status
      render "status/index"
    else
      prepare_board
      render "board/index"
    end
  end
end
