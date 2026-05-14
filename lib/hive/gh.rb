require "json"
require "open3"
require "timeout"
require "yaml"
require "hive/secret_patterns"

module Hive
  module Gh
    NETWORK_TIMEOUT_SEC = 60

    # Returned by push_branch so callers can decide whether to set a
    # `reason=unpushed_commits` marker vs. exit. A persistent push
    # failure during finalize must surface as an ERROR marker, not an
    # uncaught exit (Plan R5 / finalize verify_state!).
    PushResult = Struct.new(:success, :stdout, :stderr, keyword_init: true) do
      def success?
        success
      end
    end

    # Returned by scan_pr_for_secrets so a remote-fetch failure is
    # distinguishable from a clean scan. A blanket rescue that
    # returned `[]` on any error would reduce a security-critical
    # gate to a no-op on any transient gh hiccup.
    ScanResult = Struct.new(:hits, :fetch_failed, :fetch_error, keyword_init: true) do
      def clean?
        hits.empty? && !fetch_failed
      end
    end

    module_function

    def ensure_authenticated!
      out, err, status = with_network_timeout { Open3.capture3("gh", "auth", "status") }
      return if status.success?

      warn "hive: gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
      exit 1
    end

    # Push the branch and return a PushResult. Callers that want to
    # exit on failure can do so explicitly; finalize prefers to write
    # a structured marker.
    def push_branch(worktree_path, branch)
      out, err, status = with_network_timeout do
        Open3.capture3("git", "-C", worktree_path, "push", "-u", "origin", branch)
      end
      PushResult.new(success: status.success?, stdout: out, stderr: err)
    end

    # Hard-fail wrapper for callers that have no recovery path (open-pr).
    def push_branch!(worktree_path, branch)
      result = push_branch(worktree_path, branch)
      return if result.success?

      warn "hive: git push failed: #{result.stderr.strip.empty? ? result.stdout : result.stderr}"
      exit 1
    end

    # Look up an OPEN pull request for `branch`. Returns:
    #   - the PR hash when an OPEN PR exists for this branch
    #   - nil when `gh pr list` succeeds and reports no OPEN PR
    # Hard-fails (exit 1) when `gh pr list` itself fails or returns
    # unparseable JSON — the caller can't safely decide between
    # "no PR exists" and "remote unavailable" without this signal,
    # and silently falling through opens a second PR for the same
    # branch on retry (Plan R5).
    #
    # CLOSED/MERGED PRs are explicitly NOT returned: a stale URL
    # would propagate into pr.md and downstream `gh pr edit` /
    # `gh pr ready` calls would target a dead PR.
    def lookup_existing_pr(worktree_path, branch)
      # `gh -R` accepts a `owner/repo` slug but not a worktree path;
      # `--repo` likewise. `gh` resolves the remote from cwd's git
      # config, so route through chdir. Earlier passes flagged the
      # inconsistency with the `git -C <path>` style used elsewhere
      # in this module; the difference is load-bearing (gh has no
      # `-C` flag), not stylistic. Kept here with a comment so the
      # next reader doesn't "fix" it.
      out, err, status = with_network_timeout do
        Open3.capture3("gh", "pr", "list", "--head", branch,
                       "--state", "all", "--json", "url,number,state,isDraft",
                       chdir: worktree_path)
      end
      unless status.success?
        warn "hive: `gh pr list` failed for branch #{branch}: #{err.to_s.strip.empty? ? out : err.strip}"
        exit 1
      end

      list = JSON.parse(out)
      list.find { |p| p["state"] == "OPEN" }
    rescue JSON::ParserError => e
      warn "hive: `gh pr list` returned unparseable JSON for branch #{branch}: #{e.message}"
      exit 1
    end

    def pr_frontmatter(path)
      return {} unless File.exist?(path)

      content = File.read(path)
      return {} unless content =~ /\A---\s*\n(.*?)\n---\s*\n/m

      parsed = YAML.safe_load(Regexp.last_match(1)) || {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue Psych::Exception => e
      warn "hive: pr.md frontmatter unparseable (#{e.class}: #{e.message}); treating as empty"
      {}
    end

    # Scan the agent-authored state-file plus the remote PR body for
    # credential patterns. Returns a ScanResult. fetch_failed=true
    # signals the caller to fail loud rather than treat as clean.
    def scan_pr_for_secrets(state_file:, pr_url:)
      sources = [ File.read(state_file) ]

      if pr_url.to_s.empty?
        return ScanResult.new(
          hits: sources.flat_map { |s| Hive::SecretPatterns.scan(s) },
          fetch_failed: false,
          fetch_error: nil
        )
      end

      out, err, status = with_network_timeout do
        Open3.capture3("gh", "pr", "view", pr_url, "--json", "body", "-q", ".body")
      end
      unless status.success?
        return ScanResult.new(
          hits: [],
          fetch_failed: true,
          fetch_error: err.to_s.strip.empty? ? out : err.strip
        )
      end

      sources << out unless out.empty?
      ScanResult.new(
        hits: sources.flat_map { |s| Hive::SecretPatterns.scan(s) },
        fetch_failed: false,
        fetch_error: nil
      )
    end

    def with_network_timeout(&block)
      Timeout.timeout(NETWORK_TIMEOUT_SEC, &block)
    rescue Timeout::Error
      warn "hive: network operation exceeded #{NETWORK_TIMEOUT_SEC}s; aborting"
      exit 1
    end
  end
end
