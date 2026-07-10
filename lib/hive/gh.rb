require "json"
require "time"
require "timeout"
require "uri"
require "yaml"
require "hive/secret_patterns"

module Hive
  module Gh
    NETWORK_TIMEOUT_SEC = 60
    POLL_INTERVAL_SEC = 0.05

    # Leading YAML frontmatter block of a hive-authored pr.md. Capture group
    # 1 is the YAML body (used by #pr_frontmatter); #pr_body strips the whole
    # match. One definition so the two readers can't drift.
    FRONTMATTER_DELIMITER = /\A---\s*\n(.*?)\n---\s*\n/m

    CommandStatus = Struct.new(:exitstatus, keyword_init: true) do
      def success?
        exitstatus == 0
      end
    end

    # Returned by push_branch so callers can decide whether to set a
    # `reason=unpushed_commits` marker vs. exit. A persistent push
    # failure during finalize must surface as an ERROR marker, not an
    # uncaught exit (Plan R5 / finalize verify_state!).
    PushResult = Struct.new(:success, :stdout, :stderr, keyword_init: true) do
      def success?
        success
      end
    end

    # Immutable value object (Ruby 3.4 Data.define) so `pr_metadata` stays the
    # single validated constructor and the result is tamper-proof downstream.
    # Keyword construction + field readers are unchanged for consumers.
    PrMetadata = Data.define(:number, :url, :base_ref_name, :head_ref_oid, :is_cross_repository, :state)

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

    def ensure_authenticated!(cfg = nil)
      out, err, status = capture3("gh", "auth", "status", cfg: cfg)
      return if status.success?

      raise Hive::GhError, "gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
    end

    # Push the branch and return a PushResult. Callers that want to
    # exit on failure can do so explicitly; finalize prefers to write
    # a structured marker.
    def push_branch(worktree_path, branch, cfg: nil, force: false)
      args = [ "git", "-C", worktree_path, "push", "-u" ]
      # --force-with-lease (not --force): a concurrent third-party update to
      # the branch aborts the push instead of being clobbered.
      args << "--force-with-lease" if force
      args.push("origin", branch)
      out, err, status = capture3(*args, cfg: cfg)
      PushResult.new(success: status.success?, stdout: out, stderr: err)
    rescue Hive::GhError => e
      PushResult.new(success: false, stdout: "", stderr: e.message)
    end

    # Hard-fail wrapper for callers that have no recovery path (open-pr).
    def push_branch!(worktree_path, branch, cfg: nil)
      result = push_branch(worktree_path, branch, cfg: cfg)
      return if result.success?

      raise Hive::GhError, "git push failed: #{result.stderr.strip.empty? ? result.stdout : result.stderr}"
    end

    # Look up all pull requests for `branch`. Returns the raw array from
    # `gh pr list --state all`; callers decide which states matter.
    # Raises Hive::GhError when `gh pr list` itself fails or returns
    # unparseable JSON — the caller can't safely decide between
    # "no PR exists" and "remote unavailable" without this signal.
    #
    # The returned hashes may omit optional fields on older/future gh JSON
    # shapes. Stage code treats a missing `isDraft` key as draft for
    # forward compatibility; only an explicit false means "already ready".
    def lookup_prs_for_branch(worktree_path, branch, cfg: nil)
      # `gh -R` accepts a `owner/repo` slug but not a worktree path;
      # `--repo` likewise. `gh` resolves the remote from cwd's git
      # config, so route through chdir. Earlier passes flagged the
      # inconsistency with the `git -C <path>` style used elsewhere
      # in this module; the difference is load-bearing (gh has no
      # `-C` flag), not stylistic. Kept here with a comment so the
      # next reader doesn't "fix" it.
      out, err, status = capture3("gh", "pr", "list", "--head", branch,
                                  "--state", "all", "--json", "url,number,state,isDraft,headRefName,headRefOid",
                                  chdir: worktree_path, cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed for branch #{branch}: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      unless list.is_a?(Array)
        raise Hive::GhError, "`gh pr list` returned #{list.class} for branch #{branch}; expected Array"
      end
      list
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON for branch #{branch}: #{e.message}"
    end

    # Normal open-PR path: return only OPEN pull requests. CLOSED/MERGED
    # PRs are handled by explicit recovery paths so a stale URL cannot
    # silently flow into draft-finalization commands.
    def lookup_existing_pr(worktree_path, branch, cfg: nil)
      lookup_prs_for_branch(worktree_path, branch, cfg: cfg).find { |p| p["state"] == "OPEN" }
    end

    # `chdir` scopes `gh pr view` to a specific repo checkout. Ad-hoc review
    # passes the resolved project root so `hive review --pr N --project NAME`
    # run from another repo queries the right PR instead of cwd's repo.
    def pr_metadata(number, cfg: nil, chdir: nil)
      ensure_authenticated!(cfg)
      fields = "number,url,baseRefName,headRefOid,isCrossRepository,state"
      out, err, status = capture3("gh", "pr", "view", number.to_s, "--json", fields, cfg: cfg, chdir: chdir)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{number}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{number}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      PrMetadata.new(
        number: doc["number"].to_i,
        url: doc["url"].to_s,
        base_ref_name: doc["baseRefName"].to_s,
        head_ref_oid: doc["headRefOid"].to_s,
        is_cross_repository: doc["isCrossRepository"] == true,
        state: doc["state"].to_s
      )
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{number}` returned unparseable JSON: #{e.message}"
    end

    # Resolve the complete immutable inputs needed by PR-scoped architecture
    # patrol. `gh pr view` supplies merge identity while the REST files endpoint
    # supplies status/rename metadata and is explicitly paginated.
    def merged_pr_details(pr, worktree_path:, cfg: nil)
      ensure_authenticated!(cfg)
      fields = %w[number url state baseRefName baseRefOid mergeCommit mergedAt changedFiles].join(",")
      out, err, status = capture3(
        "gh", "pr", "view", pr.to_s, "--json", fields,
        chdir: worktree_path, cfg: cfg
      )
      unless status.success?
        raise Hive::GhError, "`gh pr view #{pr}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end
      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{pr}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      repository = repo_name_with_owner(worktree_path, cfg: cfg)
      number = doc["number"]
      validate_pr_repository_identity!(doc["url"], repository, number)
      pages_out, pages_err, pages_status = capture3(
        "gh", "api", "repos/#{repository}/pulls/#{number}/files?per_page=100",
        "--paginate", "--slurp", chdir: worktree_path, cfg: cfg
      )
      unless pages_status.success?
        message = pages_err.to_s.strip.empty? ? pages_out : pages_err.strip
        raise Hive::GhError, "`gh api` failed while listing files for PR #{number}: #{message}"
      end
      pages = JSON.parse(pages_out)
      unless pages.is_a?(Array) && pages.all? { |page| page.is_a?(Array) }
        raise Hive::GhError, "`gh api` returned incomplete file pages for PR #{number}"
      end
      files = pages.flat_map do |page|
        page.map do |file|
          raise Hive::GhError, "`gh api` returned a non-object file for PR #{number}" unless file.is_a?(Hash)

          {
            "path" => file["filename"].to_s,
            "status" => file["status"].to_s,
            "previous_path" => file["previous_filename"].to_s.empty? ? nil : file["previous_filename"].to_s
          }.compact
        end
      end

      {
        "number" => number,
        "url" => doc["url"],
        "repository" => repository,
        "state" => doc["state"],
        "base_branch" => doc["baseRefName"],
        "base_sha" => doc["baseRefOid"],
        "merge_sha" => doc.dig("mergeCommit", "oid"),
        "merged_at" => doc["mergedAt"],
        "changed_files" => doc["changedFiles"],
        "files" => files
      }
    rescue JSON::ParserError => e
      raise Hive::GhError, "merged PR metadata for #{pr} was unparseable: #{e.message}"
    end

    # One cursor-addressed page of merged PR identities for architecture
    # patrol catch-up. File manifests are deliberately resolved through
    # #merged_pr_details afterward; this API only discovers stable occurrences.
    def merged_prs_page(repository:, default_branch:, cursor:, merged_since:,
                        per_page:, worktree_path:, cfg: nil)
      repository = repository.to_s
      branch = default_branch.to_s
      unless repository.match?(%r{\A[^/\s]+/[^/\s]+\z}) && !branch.empty? && !branch.match?(/\s/)
        raise Hive::GhError, "merged-PR pagination requires a repository and default branch"
      end
      page_size = Integer(per_page)
      raise Hive::GhError, "merged-PR page size must be between 1 and 100" unless (1..100).cover?(page_size)

      search = "repo:#{repository} is:pr is:merged base:#{branch} sort:updated-asc"
      if merged_since
        since = merged_since.is_a?(Time) ? merged_since : Time.iso8601(merged_since.to_s)
        search = "#{search} merged:>=#{since.utc.iso8601}"
      end
      query = <<~GRAPHQL
        query($searchQuery: String!, $pageSize: Int!, $cursor: String) {
          search(query: $searchQuery, type: ISSUE, first: $pageSize, after: $cursor) {
            issueCount
            nodes {
              ... on PullRequest {
                number
                url
                mergedAt
                baseRefName
                mergeCommit { oid }
                repository { nameWithOwner }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      GRAPHQL
      args = [
        "gh", "api", "graphql",
        "-f", "query=#{query}",
        "-f", "searchQuery=#{search}",
        "-F", "pageSize=#{page_size}"
      ]
      args.concat([ "-f", "cursor=#{cursor}" ]) unless cursor.to_s.empty?
      out, err, status = capture3(*args, chdir: worktree_path, cfg: cfg)
      unless status.success?
        raise Hive::GhError,
              "`gh api graphql` failed while listing merged PRs for #{repository}: " \
              "#{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      errors = doc.is_a?(Hash) ? doc["errors"] : nil
      if errors.is_a?(Array) && errors.any?
        messages = errors.filter_map { |item| item.is_a?(Hash) ? item["message"] : item.to_s }
        raise Hive::GhError, "GitHub GraphQL merged-PR pagination failed: #{messages.join('; ')}"
      end
      search_data = doc.is_a?(Hash) ? doc.dig("data", "search") : nil
      nodes = search_data.is_a?(Hash) ? search_data["nodes"] : nil
      page_info = search_data.is_a?(Hash) ? search_data["pageInfo"] : nil
      issue_count = search_data.is_a?(Hash) ? search_data["issueCount"] : nil
      unless issue_count.is_a?(Integer) && nodes.is_a?(Array) && nodes.all? { |item| item.is_a?(Hash) } &&
             page_info.is_a?(Hash) && [ true, false ].include?(page_info["hasNextPage"])
        raise Hive::GhError, "GitHub GraphQL returned an incomplete merged-PR page for #{repository}"
      end
      if issue_count > 1000
        raise Hive::GhError,
              "GitHub GraphQL merged-PR search has #{issue_count} results, above the 1,000-result traversal cap"
      end
      if page_info.fetch("hasNextPage") && page_info["endCursor"].to_s.empty?
        raise Hive::GhError, "GitHub GraphQL omitted the next cursor for #{repository}"
      end

      {
        "items" => nodes.map do |item|
          {
            "number" => item["number"],
            "url" => item["url"],
            "repository" => item.dig("repository", "nameWithOwner"),
            "base_branch" => item["baseRefName"],
            "merge_sha" => item.dig("mergeCommit", "oid"),
            "merged_at" => item["mergedAt"]
          }
        end,
        "next_cursor" => page_info["endCursor"],
        "has_next_page" => page_info.fetch("hasNextPage"),
        "complete" => true
      }
    rescue JSON::ParserError => e
      raise Hive::GhError, "GitHub GraphQL merged-PR page was unparseable: #{e.message}"
    rescue ArgumentError => e
      raise Hive::GhError, "invalid merged-PR pagination input: #{e.message}"
    end

    def validate_pr_repository_identity!(url, repository, number)
      uri = URI.parse(url.to_s)
      match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
      unless uri.host && match && match[1].casecmp?(repository.to_s) && match[2].to_i == number
        raise Hive::GhError,
              "resolved PR URL #{url.inspect} does not match registered repository #{repository.inspect} and PR #{number.inspect}"
      end
      true
    rescue URI::InvalidURIError
      raise Hive::GhError, "resolved PR URL #{url.inspect} is invalid"
    end

    def pr_state(pr_url, cfg: nil)
      out, err, status = capture3("gh", "pr", "view", pr_url.to_s, "--json", "state", cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{pr_url}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{pr_url}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      doc["state"].to_s
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{pr_url}` returned unparseable JSON: #{e.message}"
    end

    def list_open_prs(worktree_path, cfg: nil)
      fields = %w[
        number
        headRefName
        baseRefName
        labels
        isDraft
        isCrossRepository
        author
        headRepository
        url
        updatedAt
        mergeStateStatus
      ].join(",")
      out, err, status = capture3("gh", "pr", "list",
                                  "--state", "open",
                                  "--limit", "1000",
                                  "--json", fields,
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      raise Hive::GhError, "`gh pr list` returned #{list.class}; expected Array" unless list.is_a?(Array)

      list
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON: #{e.message}"
    end

    def repo_name_with_owner(worktree_path, cfg: nil)
      out, err, status = capture3("gh", "repo", "view", "--json", "nameWithOwner",
                                  chdir: worktree_path, cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh repo view` failed in #{worktree_path}: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh repo view` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      slug = doc["nameWithOwner"].to_s
      raise Hive::GhError, "`gh repo view` returned blank nameWithOwner in #{worktree_path}" if slug.empty?

      slug
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh repo view` returned unparseable JSON in #{worktree_path}: #{e.message}"
    end

    def list_merged_prs(repo, since:, until_date:, cfg: nil)
      fields = %w[
        number
        title
        url
        mergedAt
        author
        headRefName
        isCrossRepository
      ].join(",")
      out, err, status = capture3("gh", "pr", "list",
                                  "--repo", repo.to_s,
                                  "--state", "merged",
                                  "--search", "merged:#{since}..#{until_date}",
                                  "--limit", "1000",
                                  "--json", fields,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr list` failed for #{repo}: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      list = JSON.parse(out)
      raise Hive::GhError, "`gh pr list` returned #{list.class} for #{repo}; expected Array" unless list.is_a?(Array)

      list
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr list` returned unparseable JSON for #{repo}: #{e.message}"
    end

    def pr_status_rollup(worktree_path, number, cfg: nil)
      out, err, status = capture3("gh", "pr", "view", number.to_s,
                                  "--json", "mergeable,mergeStateStatus,statusCheckRollup,headRefOid,url",
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{number}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{number}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{number}` returned unparseable JSON: #{e.message}"
    end

    # PR diff/commit stats for the digest footer, keyed off the PR URL (which
    # carries its own owner/repo context, so no worktree/chdir is needed).
    # Returns { additions:, deletions:, commits: } where commits is the commit
    # count. Raises Hive::GhError on a failed/unparseable lookup so the caller
    # can drop just that PR's numbers without failing the whole digest send.
    def pr_stats(pr_url, cfg: nil)
      out, err, status = capture3("gh", "pr", "view", pr_url.to_s,
                                  "--json", "additions,deletions,commits",
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`gh pr view #{pr_url}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      doc = JSON.parse(out)
      raise Hive::GhError, "`gh pr view #{pr_url}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

      {
        additions: doc["additions"].to_i,
        deletions: doc["deletions"].to_i,
        commits: Array(doc["commits"]).size
      }
    rescue JSON::ParserError => e
      raise Hive::GhError, "`gh pr view #{pr_url}` returned unparseable JSON: #{e.message}"
    end

    def pr_failing_job_logs(worktree_path, number, cfg: nil, byte_cap: 50 * 1024)
      rollup = pr_status_rollup(worktree_path, number, cfg: cfg)
      failing_jobs_with_logs(worktree_path, rollup, cfg: cfg, byte_cap: byte_cap)
    end

    def failing_jobs_with_logs(worktree_path, rollup, cfg: nil, byte_cap: 50 * 1024)
      jobs = failing_jobs_from_rollup(rollup)
      return [] if jobs.empty?

      # Two-pass budget allocation: jobs whose full log fits under an even
      # share keep their full text, and the bytes they leave unused are
      # redistributed across the over-cap jobs. A flat `byte_cap / jobs.size`
      # cap makes short jobs underspend while truncating the large failing
      # job more aggressively than the budget allows (plan IU-8).
      raw = jobs.map do |job|
        job_id = job["databaseId"] || job["id"]
        { "name" => job["name"].to_s, "job_id" => job_id, "log" => fetch_job_log(worktree_path, job_id, cfg: cfg) }
      end

      caps = allocate_log_budget(raw.map { |entry| entry["log"].bytesize }, byte_cap)
      raw.each_with_index.map do |entry, index|
        entry.merge("log" => tail_clip(entry["log"], caps[index]))
      end
    end

    def fetch_job_log(worktree_path, job_id, cfg: nil)
      return "[hive-babysitter: no job id available, cannot fetch log]" unless job_id

      fetch_result = fetch_failed_job_log(worktree_path, job_id, cfg: cfg)
      return fetch_result[:log] if fetch_result[:success]

      "[hive-babysitter: failed to fetch log for job #{job_id} via gh run view: #{fetch_result[:error]}]"
    end

    # Max-min fair allocation: repeatedly hand out an even share of the
    # remaining budget; any log that fits under the current share is settled
    # at full size, freeing its leftover bytes for the rest. Whatever stays
    # over-cap then splits the leftover budget evenly.
    def allocate_log_budget(sizes, byte_cap)
      caps = Array.new(sizes.size)
      remaining = byte_cap
      unsettled = (0...sizes.size).to_a

      loop do
        break if unsettled.empty?

        share = [ remaining / unsettled.size, 1 ].max
        fits = unsettled.select { |i| sizes[i] <= share }
        break if fits.empty?

        fits.each do |i|
          caps[i] = sizes[i]
          remaining -= sizes[i]
        end
        unsettled -= fits
      end

      unless unsettled.empty?
        share = [ remaining / unsettled.size, 1 ].max
        unsettled.each { |i| caps[i] = share }
      end

      caps
    end

    def pr_diff_stat(worktree_path, base_ref, head_ref, cfg: nil)
      capture3("git", "fetch", "origin", base_ref.to_s, chdir: worktree_path, cfg: cfg)
      out, err, status = capture3("git", "diff", "--stat",
                                  "origin/#{base_ref}...#{head_ref}",
                                  chdir: worktree_path,
                                  cfg: cfg)
      unless status.success?
        raise Hive::GhError, "`git diff --stat origin/#{base_ref}...#{head_ref}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
      end

      out
    end

    # Base HEAD + merge divergence summary for the babysitter prompt
    # (plan IU-5): the agent needs the current base tip and how far the PR
    # branch has diverged to decide between rebase, merge, or leave-alone.
    # Best-effort — supplementary context, so a git hiccup yields blank
    # values rather than failing the whole context build.
    def pr_base_divergence(worktree_path, base_ref, cfg: nil)
      capture3("git", "fetch", "origin", base_ref.to_s, chdir: worktree_path, cfg: cfg)
      counts = git_rev(worktree_path, "rev-list", "--left-right", "--count", "origin/#{base_ref}...HEAD", cfg: cfg)
      behind, ahead = counts.split(/\s+/)
      {
        "base_ref" => base_ref.to_s,
        "base_sha" => git_rev(worktree_path, "rev-parse", "origin/#{base_ref}", cfg: cfg),
        "merge_base" => git_rev(worktree_path, "merge-base", "origin/#{base_ref}", "HEAD", cfg: cfg),
        "ahead" => ahead.to_i,
        "behind" => behind.to_i
      }
    end

    def git_rev(worktree_path, *args, cfg: nil)
      out, _err, status = capture3("git", *args, chdir: worktree_path, cfg: cfg)
      status.success? ? out.to_s.strip : ""
    end

    def failing_jobs_from_rollup(rollup)
      Array(rollup["statusCheckRollup"]).select do |entry|
        next false unless entry.is_a?(Hash)

        conclusion = entry["conclusion"].to_s.upcase
        status = entry["status"].to_s.upcase
        conclusion == "FAILURE" || conclusion == "TIMED_OUT" || conclusion == "CANCELLED" || status == "FAILURE"
      end
    end

    def fetch_failed_job_log(worktree_path, job_id, cfg: nil)
      out, err, status = capture3("gh", "run", "view",
                                  "--log-failed",
                                  "--job", job_id.to_s,
                                  chdir: worktree_path,
                                  cfg: cfg)
      if status.success?
        { success: true, log: out, error: nil }
      else
        { success: false, log: "", error: err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip }
      end
    rescue Hive::GhError => e
      { success: false, log: "", error: e.message }
    end

    def tail_clip(text, byte_cap)
      text = text.to_s
      return text if text.bytesize <= byte_cap

      elided = text.bytesize - byte_cap
      tail = text.byteslice(-byte_cap, byte_cap).to_s
      tail.scrub!("")
      "\n...[truncated, #{elided} bytes elided]\n#{tail}"
    end

    def lookup_merged_pr(worktree_path, branch, cfg: nil, head_oid: nil)
      lookup_prs_for_branch(worktree_path, branch, cfg: cfg).find do |p|
        p["state"] == "MERGED" && (head_oid.nil? || p["headRefOid"].to_s == head_oid.to_s)
      end
    end

    def pr_frontmatter(path)
      return {} unless File.exist?(path)

      content = File.read(path)
      return {} unless content =~ FRONTMATTER_DELIMITER

      parsed = YAML.safe_load(Regexp.last_match(1)) || {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue Psych::Exception => e
      warn "hive: pr.md frontmatter unparseable (#{e.class}: #{e.message}); treating as empty"
      {}
    end

    # Return the pr.md body — the file content with any leading YAML
    # frontmatter block stripped and surrounding whitespace trimmed.
    # Owns the `---…---` delimiter so callers (e.g. the digest collector)
    # don't re-encode the frontmatter format a second time. Returns "" when
    # the file is absent; read/permission errors propagate as
    # SystemCallError/IOError so callers that must degrade can rescue them.
    def pr_body(path)
      return "" unless File.exist?(path)

      File.read(path).sub(FRONTMATTER_DELIMITER, "").strip
    end

    # Scan the agent-authored state-file plus the remote PR body for
    # credential patterns. Returns a ScanResult. fetch_failed=true
    # signals the caller to fail loud rather than treat as clean.
    def scan_pr_for_secrets(state_file:, pr_url:, cfg: nil)
      sources = [ File.read(state_file) ]
      local_hits = sources.flat_map { |s| Hive::SecretPatterns.scan(s) }

      if pr_url.to_s.empty?
        return ScanResult.new(
          hits: local_hits,
          fetch_failed: false,
          fetch_error: nil
        )
      end

      out, err, status = capture3("gh", "pr", "view", pr_url, "--json", "body", "-q", ".body", cfg: cfg)
      unless status.success?
        return ScanResult.new(
          hits: local_hits,
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
    rescue Hive::GhError => e
      ScanResult.new(hits: local_hits || [], fetch_failed: true, fetch_error: e.message)
    end

    def network_timeout_sec(cfg = nil)
      value = cfg&.dig("gh", "network_timeout_sec")
      value.is_a?(Integer) && value.positive? ? value : NETWORK_TIMEOUT_SEC
    end

    def capture3(*cmd, chdir: nil, cfg: nil, timeout_sec: nil)
      timeout_sec ||= network_timeout_sec(cfg)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes" }
      spawn_options = { out: stdout_w, err: stderr_w }
      spawn_options[:chdir] = chdir if chdir
      pid = Process.spawn(env, *cmd, **spawn_options)
      stdout_w.close
      stderr_w.close
      stdout_reader = Thread.new { stdout_r.read }
      stderr_reader = Thread.new { stderr_r.read }

      status = wait_with_deadline(pid, timeout_sec, cmd)
      [ stdout_reader.value, stderr_reader.value, status ]
    rescue SystemCallError => e
      raise Hive::GhError, "failed to run #{cmd.join(' ')}: #{e.message}"
    ensure
      [ stdout_w, stderr_w, stdout_r, stderr_r ].each do |io|
        io.close if io && !io.closed?
      rescue IOError
        nil
      end
    end

    def wait_with_deadline(pid, timeout_sec, cmd)
      deadline = Time.now + timeout_sec
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited[1] if waited

        if Time.now >= deadline
          terminate_process(pid)
          raise Hive::GhError, "network operation exceeded #{timeout_sec}s while running #{cmd.join(' ')}"
        end
        sleep POLL_INTERVAL_SEC
      end
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
      deadline = Time.now + 1
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited[1] if waited
        break if Time.now >= deadline

        sleep POLL_INTERVAL_SEC
      end
      Process.kill("KILL", pid)
      Process.waitpid2(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def with_network_timeout(timeout_sec: NETWORK_TIMEOUT_SEC, &block)
      yield
    rescue Timeout::Error
      raise Hive::GhError, "network operation exceeded #{timeout_sec}s"
    end
  end
end
