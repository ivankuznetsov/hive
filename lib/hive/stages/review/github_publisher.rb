require "json"
require "open3"
require "tempfile"
require "hive/gh"
require "hive/reviewers"
require "hive/secret_patterns"

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

          pr_url = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"].to_s
          if pr_url.empty?
            warn "hive: review GitHub publish skipped; no pr_url in #{File.join(task.folder, 'pr.md')}"
            return :missing_pr
          end

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
