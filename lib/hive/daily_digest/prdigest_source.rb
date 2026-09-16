require "prdigest"
require "hive/gh"
require "hive/repository_identity"
require "hive/secret_patterns"

module Hive
  module DailyDigest
    class PrdigestSource
      def call(date:, time_zone:, projects:)
        repositories = projects.filter_map do |project|
          identity = project["repository_identity"] || Hive::RepositoryIdentity.current(project.fetch("path"))
          next unless identity&.start_with?("github.com/")

          Hive::Gh::RepositoryIdentity.validated_repository_slug(identity.delete_prefix("github.com/"))
        end.uniq.sort
        clock = Prdigest::Clock.new(timezone: time_zone)
        github = Prdigest::GitHub.new(token: repositories.empty? ? "" : github_token)
        digest = Prdigest::Collector.new(clock: clock, github: github, repositories: repositories).call(date: date)
        # Raw descriptions and patches never bypass Hive's existing secret
        # redaction on their way to an agent or persisted document.
        JSON.parse(Hive::SecretPatterns.redact(JSON.generate(Prdigest::Facts.new(digest: digest, timezone: time_zone).to_h)))
      rescue Prdigest::Error => error
        raise Hive::UnavailableError, "digest evidence collection failed: #{error.message}"
      end

      private

      def github_token
        token, _error, status = Hive::Gh.capture3("gh", "auth", "token", "--hostname", "github.com")
        raise Hive::ConfigError, "GitHub authentication is required to generate a digest; run gh auth login" unless status.success?

        token.strip
      end
    end
  end
end
