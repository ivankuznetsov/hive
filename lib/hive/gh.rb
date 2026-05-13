require "json"
require "open3"
require "timeout"
require "yaml"

module Hive
  module Gh
    NETWORK_TIMEOUT_SEC = 60

    module_function

    def ensure_authenticated!
      out, err, status = with_network_timeout { Open3.capture3("gh", "auth", "status") }
      return if status.success?

      warn "hive: gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
      exit 1
    end

    def push_branch!(worktree_path, branch)
      out, err, status = with_network_timeout do
        Open3.capture3("git", "-C", worktree_path, "push", "-u", "origin", branch)
      end
      return if status.success?

      warn "hive: git push failed: #{err.strip.empty? ? out : err}"
      exit 1
    end

    def lookup_existing_pr(worktree_path, branch)
      out, _err, status = with_network_timeout do
        Open3.capture3("gh", "pr", "list", "--head", branch,
                       "--state", "all", "--json", "url,number,state,isDraft",
                       chdir: worktree_path)
      end
      return nil unless status.success?

      list = JSON.parse(out)
      list.find { |p| p["state"] == "OPEN" } || list.first
    rescue JSON::ParserError
      nil
    end

    def pr_frontmatter(path)
      return {} unless File.exist?(path)

      content = File.read(path)
      return {} unless content =~ /\A---\s*\n(.*?)\n---\s*\n/m

      parsed = YAML.safe_load(Regexp.last_match(1)) || {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue Psych::Exception
      {}
    end

    def with_network_timeout(&block)
      Timeout.timeout(NETWORK_TIMEOUT_SEC, &block)
    rescue Timeout::Error
      warn "hive: network operation exceeded #{NETWORK_TIMEOUT_SEC}s; aborting"
      exit 1
    end
  end
end
