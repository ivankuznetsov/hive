require "json"
require "tempfile"
require "time"
require "uri"
require "hive/gh"

module Hive
  module RefactorPatrol
    # Architecture-patrol GitHub protocol. Hive::Gh remains the shared command
    # transport and repository identity boundary; this adapter owns the
    # feature-specific validation and response shapes used by durable patrol
    # publication and merge intake.
    class GithubGateway
      def self.coerce(gateway = nil, transport:, required:)
        return gateway unless gateway.nil?

        methods = Array(required)
        return transport if methods.all? { |name| transport.respond_to?(name) }

        new(transport: transport)
      end

      def initialize(transport: Hive::Gh, monotonic_clock: nil)
        @transport = transport
        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      # The REST /issues endpoint includes pull requests, so fetch every page
      # and validate every issue-shaped record before returning the exact issue
      # inventory. Malformed or partial responses must not look like an empty
      # inventory because publication callers would create duplicates.
      def issues_for_repository(repository:, host:, cfg: nil)
        repo = validated_repository_slug(repository)
        github_host = validated_github_host(host)

        endpoint = "repos/#{repo}/issues?state=all&per_page=100"
        out, err, status = @transport.capture3(
          "gh", "api", "--hostname", github_host, endpoint,
          "--paginate", "--slurp", cfg: cfg
        )
        unless status.success?
          message = err.to_s.strip.empty? ? out : err.strip
          raise Hive::GhError, "`gh api` failed while listing issues for #{repo}: #{message}"
        end

        pages = JSON.parse(out)
        unless pages.is_a?(Array) && pages.all? { |page| page.is_a?(Array) }
          raise Hive::GhError, "`gh api --paginate --slurp` returned incomplete issue pages for #{repo}"
        end

        pages.flatten.filter_map do |issue|
          validate_issue_api_record!(issue, repo, host: github_host)
          next if issue.key?("pull_request")

          {
            "number" => issue.fetch("number"),
            "state" => issue.fetch("state").upcase,
            "url" => issue.fetch("html_url"),
            "title" => issue.fetch("title"),
            "body" => issue.fetch("body")
          }
        end
      rescue JSON::ParserError => e
        raise Hive::GhError, "issue pages for #{repository} were unparseable: #{e.message}"
      end

      def issues_with_marker(repository:, marker:, host:, cfg: nil)
        needle = marker.to_s
        raise Hive::GhError, "issue marker must be a non-empty string" if needle.empty?

        issues_for_repository(repository: repository, host: host, cfg: cfg).select do |issue|
          issue.fetch("body").to_s.lines.any? { |line| line.strip == needle }
        end
      end

      # Use a temporary body file so markdown is never interpreted as argv or
      # by a shell. The caller owns content bounds; this gateway owns transport
      # and fail-closed command/result handling.
      def create_issue(repository:, title:, body:, host:, cfg: nil)
        repo = validated_repository_slug(repository)
        github_host = validated_github_host(host)
        unless title.is_a?(String) && !title.strip.empty?
          raise Hive::GhError, "issue title must be a non-empty string"
        end
        raise Hive::GhError, "issue body must be a string" unless body.is_a?(String)

        Tempfile.create([ "hive-refactor-issue-", ".md" ]) do |file|
          file.binmode
          file.write(body)
          file.flush
          out, err, status = @transport.capture3(
            "gh", "issue", "create", "--repo", "#{github_host}/#{repo}",
            "--title", title, "--body-file", file.path, cfg: cfg
          )
          unless status.success?
            message = err.to_s.strip.empty? ? out : err.strip
            raise Hive::GhError, "`gh issue create` failed for #{repo}: #{message}"
          end

          url = out.lines.map(&:strip).reject(&:empty?).last.to_s
          raise Hive::GhError, "`gh issue create` returned no issue URL for #{repo}" if url.empty?
          unless issue_url_matches_repository?(url, repo, host: github_host)
            raise Hive::GhError, "`gh issue create` returned an unexpected issue URL for #{repo}"
          end

          url
        end
      end

      def verify_pr_identity!(pr_url, repository:, host:, branch:, head_oid:,
                              base_branch:, cfg: nil)
        target = github_repository_target(repository, host)
        fields = "url,number,state,isDraft,headRefName,headRefOid,baseRefName,headRepository"
        out, err, status = @transport.capture3(
          "gh", "pr", "view", pr_url.to_s, "--repo", target, "--json", fields,
          cfg: cfg
        )
        unless status.success?
          raise Hive::GhError,
                "`gh pr view` failed while verifying created PR: " \
                "#{err.to_s.strip.empty? ? out : err.strip}"
        end
        doc = JSON.parse(out)
        unless doc.is_a?(Hash)
          raise Hive::GhError, "`gh pr view` returned #{doc.class}; expected Hash"
        end

        validate_pr_repository_identity!(
          pr_url, repository, doc["number"], host: host
        )
        validate_pr_repository_identity!(
          doc["url"], repository, doc["number"], host: host
        )

        uri = URI.parse(doc["url"].to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        head_repository = doc["headRepository"]
        valid = uri.is_a?(URI::HTTP) && uri.host&.casecmp?(host.to_s) && match &&
                match[1].casecmp?(repository.to_s) && uri.userinfo.nil? &&
                uri.query.nil? && uri.fragment.nil? &&
                doc["number"].is_a?(Integer) && doc["number"].positive? &&
                match[2].to_i == doc["number"] && doc["state"] == "OPEN" &&
                doc["isDraft"] == false && doc["headRefName"] == branch &&
                doc["headRefOid"] == head_oid && doc["baseRefName"] == base_branch &&
                head_repository.is_a?(Hash) &&
                head_repository["nameWithOwner"].to_s.casecmp?(repository.to_s)
        raise Hive::GhError, "created pull request identity does not match the validated patch" unless valid

        doc
      rescue JSON::ParserError, URI::InvalidURIError => e
        raise Hive::GhError, "created pull request identity is unparseable: #{e.message}"
      end

      # Resolve the complete immutable inputs needed by PR-scoped architecture
      # patrol. `gh pr view` supplies merge identity while the REST files
      # endpoint supplies status/rename metadata and is explicitly paginated.
      def merged_pr_details(pr, worktree_path:, cfg: nil, timeout_sec: nil)
        deadline = operation_deadline(timeout_sec)
        identity = @transport.repository_identity(
          worktree_path, cfg: cfg, timeout_sec: remaining_timeout(deadline)
        )
        repository = identity.fetch("repository")
        host = identity.fetch("host")
        @transport.ensure_authenticated!(
          cfg, host: host, timeout_sec: remaining_timeout(deadline)
        )
        fields = %w[number url state baseRefName baseRefOid mergeCommit mergedAt changedFiles].join(",")
        out, err, status = @transport.capture3(
          "gh", "pr", "view", pr.to_s, "--repo", "#{host}/#{repository}",
          "--json", fields,
          chdir: worktree_path, cfg: cfg, timeout_sec: remaining_timeout(deadline)
        )
        unless status.success?
          raise Hive::GhError, "`gh pr view #{pr}` failed: #{err.to_s.strip.empty? ? out : err.strip}"
        end
        doc = JSON.parse(out)
        raise Hive::GhError, "`gh pr view #{pr}` returned #{doc.class}; expected Hash" unless doc.is_a?(Hash)

        number = doc["number"]
        validate_pr_repository_identity!(doc["url"], repository, number, host: host)
        pages_out, pages_err, pages_status = @transport.capture3(
          "gh", "api", "repos/#{repository}/pulls/#{number}/files?per_page=100",
          "--hostname", host, "--paginate", "--slurp",
          chdir: worktree_path, cfg: cfg, timeout_sec: remaining_timeout(deadline)
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
            unless file.is_a?(Hash)
              raise Hive::GhError, "`gh api` returned a non-object file for PR #{number}"
            end

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
      # patrol catch-up. File manifests are resolved through
      # #merged_pr_details afterward; this API discovers stable occurrences.
      def merged_prs_page(repository:, host:, default_branch:, cursor:, merged_since:,
                          per_page:, worktree_path:, merged_until: nil, cfg: nil,
                          timeout_sec: nil)
        deadline = operation_deadline(timeout_sec)
        repository = validated_repository_slug(repository)
        host = validated_github_host(host)
        branch = default_branch.to_s
        unless repository.match?(%r{\A[^/\s]+/[^/\s]+\z}) && !branch.empty? && !branch.match?(/\s/)
          raise Hive::GhError, "merged-PR pagination requires a repository and default branch"
        end
        page_size = Integer(per_page)
        unless (1..100).cover?(page_size)
          raise Hive::GhError, "merged-PR page size must be between 1 and 100"
        end
        unless cursor.nil? || (cursor.is_a?(String) && !cursor.empty?)
          raise Hive::GhError, "merged-PR pagination cursor must be a non-empty string"
        end

        search = "repo:#{repository} is:pr is:merged base:#{branch} sort:created-asc"
        since = nil
        if merged_since
          since = merged_since.is_a?(Time) ? merged_since : Time.iso8601(merged_since.to_s)
          search = "#{search} merged:>=#{since.utc.iso8601}"
        end
        if merged_until
          upper = merged_until.is_a?(Time) ? merged_until : Time.iso8601(merged_until.to_s)
          if since && upper < since
            raise Hive::GhError, "merged-PR pagination upper bound cannot precede its lower bound"
          end
          search = "#{search} merged:<=#{upper.utc.iso8601}"
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
          "gh", "api", "graphql", "--hostname", host,
          "-f", "query=#{query}",
          "-f", "searchQuery=#{search}",
          "-F", "pageSize=#{page_size}"
        ]
        args.concat([ "-f", "cursor=#{cursor}" ]) unless cursor.to_s.empty?
        out, err, status = @transport.capture3(
          *args, chdir: worktree_path, cfg: cfg,
          timeout_sec: remaining_timeout(deadline)
        )
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
        if page_info.fetch("hasNextPage") &&
           (!page_info["endCursor"].is_a?(String) || page_info["endCursor"].empty?)
          raise Hive::GhError, "GitHub GraphQL omitted the next cursor for #{repository}"
        end

        nodes.each do |item|
          validate_pr_repository_identity!(item["url"], repository, item["number"], host: host)
          node_repository = item.dig("repository", "nameWithOwner")
          merge_sha = item.dig("mergeCommit", "oid")
          merged_at = item["mergedAt"]
          valid = node_repository.is_a?(String) && node_repository.casecmp?(repository) &&
                  item["baseRefName"] == branch &&
                  merge_sha.is_a?(String) && merge_sha.match?(/\A[a-f0-9]{40,64}\z/) &&
                  merged_at.is_a?(String) && !merged_at.empty?
          unless valid
            raise Hive::GhError, "GitHub GraphQL returned incomplete merged-PR identity"
          end
          Time.iso8601(merged_at)
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
          "total_count" => issue_count,
          "complete" => true
        }
      rescue JSON::ParserError => e
        raise Hive::GhError, "GitHub GraphQL merged-PR page was unparseable: #{e.message}"
      rescue ArgumentError => e
        raise Hive::GhError, "invalid merged-PR pagination input: #{e.message}"
      end

      private

      def operation_deadline(timeout_sec)
        return nil if timeout_sec.nil?

        seconds = Float(timeout_sec)
        unless seconds.finite? && seconds.positive?
          raise Hive::GhError, "GitHub operation timeout must be positive"
        end

        monotonic_now + seconds
      rescue TypeError, ArgumentError
        raise Hive::GhError, "GitHub operation timeout must be positive"
      end

      def remaining_timeout(deadline)
        return nil unless deadline

        remaining = deadline - monotonic_now
        raise Hive::GhError, "GitHub operation exceeded its deadline" unless remaining.positive?

        remaining
      end

      def monotonic_now
        Float(@monotonic_clock.call)
      end

      def validate_pr_repository_identity!(url, repository, number, host:)
        uri = URI.parse(url.to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        unless uri.is_a?(URI::HTTP) && uri.host&.casecmp?(host.to_s) && match &&
               match[1].casecmp?(repository.to_s) && number.is_a?(Integer) &&
               number.positive? && match[2].to_i == number && uri.userinfo.nil? &&
               uri.query.nil? && uri.fragment.nil?
          raise Hive::GhError,
                "resolved PR URL does not match registered host/repository and PR number"
        end
        true
      rescue URI::InvalidURIError
        raise Hive::GhError, "resolved PR URL #{url.inspect} is invalid"
      end

      def validated_repository_slug(repository)
        value = repository.to_s.strip
        segments = value.split("/", -1)
        valid = segments.size == 2 && segments.all? do |segment|
          segment.match?(/\A[a-zA-Z0-9_.-]+\z/) && !%w[. ..].include?(segment)
        end
        raise Hive::GhError, "repository must be an owner/name slug" unless valid

        value
      end

      def validated_github_host(host)
        value = host.to_s.strip
        uri = URI.parse("https://#{value}")
        valid = !value.empty? && uri.host == value && uri.path.empty? &&
                uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise Hive::GhError, "GitHub host must be a hostname without a scheme or path" unless valid

        value
      rescue URI::InvalidURIError
        raise Hive::GhError, "GitHub host must be a hostname without a scheme or path"
      end

      def github_repository_target(repository, host)
        "#{validated_github_host(host)}/#{validated_repository_slug(repository)}"
      end

      def validate_issue_api_record!(issue, repository, host:)
        unless issue.is_a?(Hash)
          raise Hive::GhError, "`gh api` returned a non-object issue for #{repository}"
        end

        missing = %w[number state html_url title body].reject { |key| issue.key?(key) }
        unless missing.empty?
          raise Hive::GhError, "`gh api` issue for #{repository} is missing #{missing.inspect}"
        end
        unless issue["number"].is_a?(Integer) && issue["number"].positive?
          raise Hive::GhError, "`gh api` issue for #{repository} has an invalid number"
        end
        unless %w[open closed].include?(issue["state"].to_s.downcase)
          raise Hive::GhError, "`gh api` issue #{issue['number']} for #{repository} has an invalid state"
        end
        unless issue["html_url"].is_a?(String) && !issue["html_url"].empty?
          raise Hive::GhError, "`gh api` issue #{issue['number']} for #{repository} has no URL"
        end
        unless issue["title"].is_a?(String) && !issue["title"].strip.empty?
          raise Hive::GhError, "`gh api` issue #{issue['number']} for #{repository} has an invalid title"
        end
        unless issue["body"].nil? || issue["body"].is_a?(String)
          raise Hive::GhError, "`gh api` issue #{issue['number']} for #{repository} has an invalid body"
        end
        if issue.key?("pull_request") && !issue["pull_request"].is_a?(Hash)
          raise Hive::GhError,
                "`gh api` issue #{issue['number']} for #{repository} has an invalid pull-request shape"
        end
        valid_url = if issue.key?("pull_request")
          pull_request_url_matches_repository?(
            issue["html_url"], repository, host: host, number: issue["number"]
          )
        else
          issue_url_matches_repository?(
            issue["html_url"], repository, host: host, number: issue["number"]
          )
        end
        unless valid_url
          kind = issue.key?("pull_request") ? "pull request" : "issue"
          raise Hive::GhError,
                "`gh api` #{kind} #{issue['number']} URL does not belong to #{repository}"
        end

        issue
      end

      def pull_request_url_matches_repository?(url, repository, host:, number: nil)
        uri = URI.parse(url.to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        return false unless uri.is_a?(URI::HTTP) && uri.host && match
        return false unless uri.host.casecmp?(host.to_s)
        return false unless match[1].casecmp?(repository.to_s)
        return false if number && match[2].to_i != number.to_i
        return false unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        true
      rescue URI::InvalidURIError
        false
      end

      def issue_url_matches_repository?(url, repository, host:, number: nil)
        uri = URI.parse(url.to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/issues/([1-9]\d*)\z})
        return false unless uri.is_a?(URI::HTTP) && uri.host && match
        return false unless uri.host.casecmp?(host.to_s)
        return false unless match[1].casecmp?(repository.to_s)
        return false if number && match[2].to_i != number.to_i
        return false unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        true
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
