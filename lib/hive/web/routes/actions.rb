module Hive
  module Web
    class App < Sinatra::Base
      post "/tasks/:project/:slug/approve" do
        settings.dispatcher.approve(
          slug: params["slug"],
          project: params["project"],
          from: params["from"],
          to: params["to"],
          force: params["force"] == "1"
        )
        redirect "/"
      end

      post "/tasks/:project/:slug/reject" do
        settings.dispatcher.reject(
          slug: params["slug"],
          project: params["project"],
          from: params["from"],
          to: params["to"]
        )
        redirect "/"
      end

      post "/tasks/:project/:slug/dispatch" do
        settings.dispatcher.dispatch(
          slug: params["slug"],
          project: params["project"],
          action: params["action"],
          stage: params["stage"]
        )
        redirect "/tasks/#{params["project"]}/#{params["slug"]}"
      end

      post "/tasks/:project/:slug/intervene" do
        row = task_row(find_project!(params["project"]), params["slug"])
        halt 404, "unknown task" unless row
        settings.dispatcher.intervene(folder: row["folder"], message: params["message"])
        redirect "/tasks/#{params["project"]}/#{params["slug"]}"
      end

      post "/ideas" do
        settings.dispatcher.new_idea(project: params["project"], text: params["text"])
        redirect "/"
      end
    end
  end
end
