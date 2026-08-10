require "json"
require "open3"
require "tempfile"
require "hive/gh"
require "hive/reviewers"
require "hive/secret_patterns"
require "hive/worktree"

module Hive
  module Stages
    module Review
      module GithubPublisher
        module_function

        def publish!(task, pass:, reviewer_name:, body_path:, cfg:)
          return :disabled unless enabled?(cfg)
          return :missing_body unless File.exist?(body_path)

          file_body = File.read(body_path)
          # Reviewers that found nothing still write the High/Medium/Nit
          # section headers (see templates/reviewer_*_ce_code_review.md.erb).
          # Posting that as a PR comment is pure noise — the absence of a
          # `Reviewer: X - Pass NN` comment already conveys "nothing to
          # report". `publish_escalations` already has the same guard.
          return :no_findings unless file_body =~ /^\s*-\s+\[[ xX]\]\s+/

          pr_path = File.join(task.folder, "pr.md")
          pr_frontmatter = Hive::Gh.pr_frontmatter(pr_path)
          if pr_frontmatter["pr_url"].to_s.empty?
            warn "hive: review GitHub publish skipped; no pr_url in #{pr_path}"
            return :missing_pr
          end

          pr_url = validated_pr_url(task, cfg) { [ pr_path, pr_frontmatter ] }
          return :invalid_pr unless pr_url

          header = "### Reviewer: #{reviewer_name} - Pass #{format('%02d', pass)}"
          body = "#{header}\n\n#{file_body}"
          if (hits = Hive::SecretPatterns.scan(body)).any?
            warn "hive: review GitHub publish skipped for pass=#{format('%02d', pass)} reviewer=#{reviewer_name}; " \
                 "secret patterns=#{hits.map { |h| h[:name].to_s }.uniq.first(3).join(',')}"
            return :secret
          end

          return :already_posted if already_posted?(pr_url, header)

          with_body_file(body) do |file|
            failures = []
            max_attempts = attempts(cfg)
            max_attempts.times do |idx|
              _out, err, status = Hive::Gh.capture3("gh", "pr", "comment", pr_url, "--body-file", file.path, cfg: cfg)
              return :posted if status.success?

              failures << err.to_s.strip
              if idx + 1 >= max_attempts
                warn_failure(pass, reviewer_name, body_path, failures)
                return :failed
              end
              sleep([ 2**idx, Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC ].min)
            end
          end
        # Narrow rescue: only the categories we can't surface as a
        # structured :secret / :missing_body / :failed return. A
        # broad StandardError rescue would mask programming bugs
        # (NoMethodError on a nil arg, future helper rename) as a
        # "failed to post" warning.
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOSPC, JSON::ParserError => e
          warn "hive: failed to post reviewer comment for pass=#{format('%02d', pass)} reviewer=#{reviewer_name}; " \
               "local file at #{relative_body_path(task, body_path)} is authoritative (#{e.class}: #{e.message})"
          :failed
        end

        def enabled?(cfg)
          cfg.dig("review", "github_publish", "enabled") != false
        end

        def attempts(cfg)
          value = cfg.dig("review", "github_publish", "max_attempts").to_i
          value.positive? ? value : 2
        end

        # Reviewer output is local authority; publishing is optional remote
        # projection. Bind the target to the task repository and a fresh,
        # repository-scoped PR observation before even reading comments.
        # Agent-authored or subsequently tampered pr.md URLs therefore remain
        # inert instead of becoming `gh pr view/comment <arbitrary-url>`.
        def validated_pr_url(task, cfg)
          path, frontmatter = if block_given?
            yield
          else
            path = File.join(task.folder, "pr.md")
            [ path, Hive::Gh.pr_frontmatter(path) ]
          end
          parsed = Hive::Gh.parse_pull_request_url(frontmatter["pr_url"])
          unless parsed
            warn "hive: review GitHub publish skipped; pr_url is missing or invalid in #{path}"
            return nil
          end

          root = Hive::Worktree.canonical_root(task.project_root)
          pointer = Hive::Worktree.read_owned_pointer(
            task.folder,
            project_root: task.project_root,
            slug: task.slug,
            expected_root: root
          )
          worktree_path = pointer.fetch("path")
          branch = pointer.fetch("branch")
          persisted_head = frontmatter["head_oid"].to_s.downcase
          unless persisted_head.match?(/\A[a-f0-9]{40,64}\z/)
            warn "hive: review GitHub publish skipped; pr.md has no exact controller head identity"
            return nil
          end

          identity = Hive::Gh.repository_identity(worktree_path, cfg: cfg)
          unless parsed.fetch("host") == identity.fetch("host").downcase &&
                 parsed.fetch("repository") == identity.fetch("repository").downcase
            warn "hive: review GitHub publish skipped; pr_url is outside the task repository"
            return nil
          end

          exact_match = Hive::Gh.lookup_prs_for_branch(
            worktree_path, branch, cfg: cfg
          ).one? do |candidate|
            candidate["state"].to_s.upcase == "OPEN" &&
              candidate["headRefName"].to_s == branch &&
              candidate["headRefOid"].to_s.downcase == persisted_head &&
              candidate["number"].to_i == parsed.fetch("number") &&
              Hive::Gh.parse_pull_request_url(candidate["url"]) == parsed
          end
          unless exact_match
            warn "hive: review GitHub publish skipped; pull-request identity is stale or mismatched"
            return nil
          end

          parsed.fetch("url")
        rescue Hive::GhError, Hive::WorktreeError, SystemCallError, IOError => e
          warn "hive: review GitHub publish skipped; pull-request identity could not be proven (#{e.class}: #{e.message})"
          nil
        end

        # Per-comment line-anchored match, NOT a substring scan over
        # the joined corpus — quoting the bot header in any unrelated
        # comment yields a false positive there.
        #
        # Uses `gh pr view --json comments` and parses the JSON so we
        # can iterate comment-by-comment. `gh pr view` caps the
        # `comments` array at GitHub's default (≈100). When that cap is
        # hit we cannot prove no earlier match exists; fail-closed (treat
        # as "already posted, do not duplicate") so a long-tailed PR
        # does not silently accumulate repeated posts each pass.
        COMMENT_PAGE_CAP = 100

        def already_posted?(pr_url, header)
          out, _err, status = Hive::Gh.capture3("gh", "pr", "view", pr_url, "--json", "comments")
          return false unless status.success?

          parsed = JSON.parse(out)
          comments = parsed.is_a?(Hash) ? Array(parsed["comments"]) : []
          if comments.size >= COMMENT_PAGE_CAP
            warn "hive: review GitHub publish: comment list hit page cap " \
                 "(#{COMMENT_PAGE_CAP}); fail-closed (treating as already-posted) to avoid duplicate post"
            return true
          end

          comments.any? { |c| c.is_a?(Hash) && c["body"].to_s.lines.first.to_s.chomp == header }
        rescue JSON::ParserError, Hive::GhError
          false
        end

        def with_body_file(body)
          file = Tempfile.new([ "hive-review-comment", ".md" ])
          file.write(body)
          file.flush
          yield file
        ensure
          file&.close!
        end

        # Surface all attempt-stderrs joined with `; ` so a flaky
        # transient pattern (e.g. one HTTP 502 followed by one auth
        # error) survives the warn — earlier passes used to drop all
        # but the last stderr. The separator before `: <err>` is `:`
        # only when there is at least one non-empty stderr.
        def warn_failure(pass, reviewer_name, body_path, failures)
          stderr_blob = Array(failures).map(&:to_s).reject(&:empty?).join("; ")
          suffix = stderr_blob.empty? ? "" : ": #{stderr_blob}"
          warn "hive: failed to post reviewer comment for pass=#{format('%02d', pass)} " \
               "reviewer=#{reviewer_name}; local file at #{body_path} is authoritative#{suffix}"
        end

        def relative_body_path(task, body_path)
          body_path.to_s.sub(%r{\A#{Regexp.escape(task.folder)}/?}, "")
        end
      end
    end
  end
end
