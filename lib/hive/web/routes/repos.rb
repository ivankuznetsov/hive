require "open3"
require "fileutils"
require "hive/commands/init"
require "hive/commands/forget"

module Hive
  module Web
    class App < Sinatra::Base
      get "/repos" do
        @projects = Hive::Config.registered_projects
        erb :repos
      end

      post "/repos" do
        url = params["url"].to_s.strip
        halt 422, "repo URL required" if url.empty?
        root = ENV.fetch("HIVEBOX_REPOS_DIR", "/data/repos")
        FileUtils.mkdir_p(root)
        name = params["name"].to_s.strip
        name = File.basename(url).delete_suffix(".git") if name.empty?
        # Sanitize: a `name` containing `../` would otherwise escape the
        # repos root via File.join. File.basename strips any path segments.
        name = File.basename(name)
        halt 422, "invalid repo name" if name.empty? || name == "." || name == ".."
        target = File.join(root, name)
        if File.directory?(target)
          Hive::Commands::Init.new(target, force: true, json: false).call
        else
          # Clone via `gh` so private-repo clones use the box's gh auth (U7),
          # not just public URLs or a git credential helper.
          out, err, status = Open3.capture3("gh", "repo", "clone", url, target)
          halt 422, [ out, err ].join("\n") unless status.success?
          Hive::Commands::Init.new(target, force: true, json: false).call
        end
        redirect "/repos"
      end

      post "/repos/:name/delete" do
        Hive::Commands::Forget.new(params["name"], if_exists: true).call
        redirect "/repos"
      end
    end
  end
end
