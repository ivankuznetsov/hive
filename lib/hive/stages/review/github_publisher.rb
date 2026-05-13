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

          pr_url = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"].to_s
          if pr_url.empty?
            warn "hive: review GitHub publish skipped; no pr_url in #{File.join(task.folder, 'pr.md')}"
            return :missing_pr
          end

          header = "### Reviewer: #{reviewer_name} - Pass #{format('%02d', pass)}"
          body = "#{header}\n\n#{File.read(body_path)}"
          if (hits = Hive::SecretPatterns.scan(body)).any?
            warn "hive: review GitHub publish skipped for pass=#{format('%02d', pass)} reviewer=#{reviewer_name}; " \
                 "secret patterns=#{hits.map { |h| h[:name].to_s }.uniq.first(3).join(',')}"
            return :secret
          end

          return :already_posted if already_posted?(pr_url, header)

          with_body_file(body) do |file|
            attempts(cfg).times do |idx|
              _out, err, status = Open3.capture3("gh", "pr", "comment", pr_url, "--body-file", file.path)
              return :posted if status.success?

              if idx + 1 >= attempts(cfg)
                warn_failure(pass, reviewer_name, body_path, err)
                return :failed
              end
              sleep([ 2**idx, Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC ].min)
            end
          end
        rescue StandardError => e
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

        def already_posted?(pr_url, header)
          out, _err, status = Open3.capture3(
            "gh", "pr", "view", pr_url, "--json", "comments", "-q", ".comments[].body"
          )
          status.success? && out.include?(header)
        end

        def with_body_file(body)
          file = Tempfile.new([ "hive-review-comment", ".md" ])
          file.write(body)
          file.flush
          yield file
        ensure
          file&.close!
        end

        def warn_failure(pass, reviewer_name, body_path, err)
          warn "hive: failed to post reviewer comment for pass=#{format('%02d', pass)} " \
               "reviewer=#{reviewer_name}; local file at #{body_path} is authoritative" \
               "#{err.to_s.strip.empty? ? '' : ": #{err.strip}"}"
        end

        def relative_body_path(task, body_path)
          body_path.to_s.sub(%r{\A#{Regexp.escape(task.folder)}/?}, "")
        end
      end
    end
  end
end
