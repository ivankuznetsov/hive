require "json"
require "time"
require "uri"
require "hive/gh"

module Hive
  module RefactorPatrol
    # Architecture-patrol GitHub protocol. Hive::Gh remains the shared command
    # transport and repository identity boundary; this adapter owns the
    # feature-specific validation and response shapes used by durable patrol
    # merge intake.
    class GithubGateway
      MAX_MERGE_TITLE_BYTES = 512
      MAX_MERGE_BODY_BYTES = 32 * 1024
      MAX_MERGE_LABELS = 100
      MAX_MERGE_LABEL_BYTES = 256
      MAX_MERGE_FILES = 10_000
      PATROL_PUBLICATION_MARKER =
        /<!--\s*hive-publication:v1\s+id=pub-[0-9a-f]{32}\s+base=[0-9a-f]{40,64}\s*-->/
      PATROL_SUCCESSOR_MARKER =
        /<!--\s*hive-patrol-fix-successor:v1\s+digest=[0-9a-f]{64}\s*-->/

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
        fields = %w[
          number url state baseRefName baseRefOid mergeCommit mergedAt changedFiles
          title body labels author
        ].join(",")
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

        title = bounded_merge_text(
          doc["title"], "title", MAX_MERGE_TITLE_BYTES, allow_empty: true
        )
        body = bounded_merge_text(doc["body"], "body", MAX_MERGE_BODY_BYTES, allow_empty: true)
        author = doc.dig("author", "login")
        author = bounded_merge_text(
          author, "author", MAX_MERGE_LABEL_BYTES, allow_empty: true
        )
        labels = doc["labels"]
        unless labels.is_a?(Array) && labels.size <= MAX_MERGE_LABELS
          raise Hive::GhError, "merged PR labels are incomplete"
        end
        labels = labels.map do |label|
          unless label.is_a?(Hash)
            raise Hive::GhError, "merged PR labels contain a non-object"
          end
          bounded_merge_text(label["name"], "label", MAX_MERGE_LABEL_BYTES)
        end.uniq.sort
        changed_files = doc["changedFiles"]
        unless changed_files.is_a?(Integer) && changed_files.between?(1, MAX_MERGE_FILES)
          raise Hive::GhError, "merged PR changed-file count is invalid"
        end

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
        unless files.size == changed_files
          raise Hive::GhError,
                "merged PR file metadata is incomplete (expected #{changed_files}, got #{files.size})"
        end

        marker = body[PATROL_PUBLICATION_MARKER] || body[PATROL_SUCCESSOR_MARKER]
        provenance_kind = if marker&.match?(PATROL_PUBLICATION_MARKER)
          "patrol"
        elsif marker&.match?(PATROL_SUCCESSOR_MARKER)
          "patrol_successor"
        else
          "none"
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
          "changed_files" => changed_files,
          "title" => title, "body" => body, "labels" => labels, "author" => author,
          "publication_provenance" => { "kind" => provenance_kind, "marker" => marker },
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
        repository = Hive::Gh::RepositoryIdentity.validated_repository_slug(repository)
        host = Hive::Gh::RepositoryIdentity.validated_github_host(host)
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
        since = merged_since && (merged_since.is_a?(Time) ? merged_since : Time.iso8601(merged_since.to_s))
        upper = merged_until && (merged_until.is_a?(Time) ? merged_until : Time.iso8601(merged_until.to_s))
        if since && upper && upper < since
          raise Hive::GhError, "merged-PR pagination upper bound cannot precede its lower bound"
        end
        merged_range = if since && upper
          "#{since.utc.iso8601}..#{upper.utc.iso8601}"
        elsif since
          ">=#{since.utc.iso8601}"
        elsif upper
          "<=#{upper.utc.iso8601}"
        end
        search = "#{search} merged:#{merged_range}" if merged_range
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

      def bounded_merge_text(value, label, max_bytes, allow_empty: false)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding? && text.bytesize <= max_bytes &&
               (allow_empty || !text.empty?) && !text.include?("\0")
          raise Hive::GhError, "merged PR #{label} is invalid"
        end
        text
      end

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
    end
  end
end
