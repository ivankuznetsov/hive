class DigestsController < ApplicationController
  def show
    @digest = DailyDigest.find(date: params.fetch(:date, "today"), project: params[:project])
  rescue Hive::DailyDigest::Reader::UnknownProject
    redirect_to digest_path(params.fetch(:date, "today")),
                alert: "That project is not present in the selected digest."
  end
end
