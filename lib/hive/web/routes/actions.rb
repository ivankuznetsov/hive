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
        settings.dispatcher.approve(
          slug: params["slug"],
          project: params["project"],
          to: params.fetch("to", "2-brainstorm"),
          force: true
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
        File.open(File.join(row["folder"], "web-interventions.md"), "a") do |f|
          f.puts "\n## #{Time.now.utc.iso8601}\n\n#{params["message"]}\n"
        end
        redirect "/tasks/#{params["project"]}/#{params["slug"]}"
      end

      post "/ideas" do
        settings.dispatcher.new_idea(project: params["project"], text: params["text"])
        redirect "/"
      end
    end
  end
end
