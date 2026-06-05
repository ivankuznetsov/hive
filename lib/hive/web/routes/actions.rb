require "erb"

module Hive
  module Web
    class App < Sinatra::Base
      post "/tasks/:project/:slug/approve" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        settings.dispatcher.approve(
          slug: slug,
          project: project["name"],
          from: params["from"],
          to: params["to"],
          force: params["force"] == "1"
        )
        # Approve advances the task to the next stage (or to done/archived),
        # so its detail page may no longer resolve at this slug/stage — return
        # to the grid. dispatch/intervene keep the task in place and so redirect
        # back to the task page; that asymmetry is deliberate.
        redirect "/"
      end

      post "/tasks/:project/:slug/reject" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        settings.dispatcher.reject(
          slug: slug,
          project: project["name"],
          from: params["from"],
          to: params["to"]
        )
        # Reject moves the task back to a prior gate, so (like approve) its
        # detail page may shift stages — return to the grid. See the approve
        # note above on the deliberate redirect asymmetry vs dispatch/intervene.
        redirect "/"
      end

      post "/tasks/:project/:slug/dispatch" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        # Reject an unknown action here so a typo'd/forged verb yields a clean
        # 422 (via the Hive::Error handler) instead of enqueuing a bogus hive
        # verb the daemon can't run.
        settings.dispatcher.assert_dispatchable!(params["action"])
        settings.dispatcher.dispatch(
          slug: slug,
          project: project["name"],
          action: params["action"],
          stage: params["stage"]
        )
        # Build the redirect from validated, URI-encoded values so a forged
        # `project`/`slug` can't inject an open-redirect Location header.
        redirect task_path(project["name"], slug)
      end

      post "/tasks/:project/:slug/intervene" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        row = task_row(project, slug)
        halt 404, "unknown task" unless row
        settings.dispatcher.intervene(folder: row["folder"], message: params["message"])
        redirect task_path(project["name"], slug)
      end

      post "/ideas" do
        project = find_project!(params["project"])
        settings.dispatcher.new_idea(project: project["name"], text: params["text"])
        redirect "/"
      end

      helpers do
        # Build a /tasks redirect target from validated values, URI-encoding
        # each segment so nothing in the path can break out into a foreign
        # Location (open-redirect guard).
        def task_path(project, slug)
          "/tasks/#{ERB::Util.url_encode(project)}/#{ERB::Util.url_encode(slug)}"
        end
      end
    end
  end
end
