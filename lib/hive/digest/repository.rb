require "time"
require "hive/gh/repository_identity"

module Hive
  module Digest
    RepositoryTarget = Data.define(:project_name, :path, :repository, :host) do
      def initialize(project_name:, path:, repository:, host:)
        project = project_name.to_s.strip
        raise ArgumentError, "digest project name must not be blank" if project.empty?

        super(
          project_name: project,
          path: File.expand_path(path.to_s),
          repository: Hive::Gh::RepositoryIdentity.validated_repository_slug(repository),
          host: Hive::Gh::RepositoryIdentity.validated_github_host(host)
        )
      end

      def key = "#{host.downcase}/#{repository.downcase}"
    end

    RepositoryMetadata = Data.define(:name, :description, :url) do
      def initialize(name:, description:, url:)
        raise ArgumentError, "digest repository name must not be blank" if name.to_s.strip.empty?
        raise ArgumentError, "digest repository URL must not be blank" if url.to_s.strip.empty?

        super(name: name.to_s.strip, description: description.to_s.strip, url: url.to_s.strip)
      end
    end

    PullRequestIdentity = Data.define(:repository, :number, :url, :merged_at) do
      def initialize(repository:, number:, url:, merged_at:)
        slug = Hive::Gh::RepositoryIdentity.validated_repository_slug(repository)
        parsed_number = Integer(number)
        raise ArgumentError, "digest PR number must be positive" unless parsed_number.positive?
        raise ArgumentError, "digest PR URL must not be blank" if url.to_s.strip.empty?

        timestamp = merged_at.is_a?(Time) ? merged_at : Time.iso8601(merged_at.to_s)
        super(repository: slug, number: parsed_number, url: url.to_s.strip, merged_at: timestamp)
      end

      def key = "#{repository.downcase}##{number}"
    end

    Warning = Data.define(:kind, :message, :repository, :pr_number, :metrics) do
      def initialize(kind:, message:, repository: nil, pr_number: nil, metrics: nil)
        kind_value = kind.to_s.strip
        message_value = message.to_s.strip
        raise ArgumentError, "digest warning kind must not be blank" if kind_value.empty?
        raise ArgumentError, "digest warning message must not be blank" if message_value.empty?

        parsed_pr = pr_number.nil? ? nil : Integer(pr_number)
        raise ArgumentError, "digest warning PR number must be positive" if parsed_pr && !parsed_pr.positive?

        super(
          kind: kind_value,
          message: message_value,
          repository: repository&.to_s,
          pr_number: parsed_pr,
          metrics: Array(metrics).map(&:to_s).reject(&:empty?).uniq.freeze
        )
      end

      def to_h
        {
          "kind" => kind,
          "message" => message,
          "repository" => repository,
          "pr_number" => pr_number,
          "metrics" => metrics.empty? ? nil : metrics
        }.compact
      end
    end

    Resolution = Data.define(:targets, :warnings) do
      def initialize(targets:, warnings:)
        super(targets: Array(targets).freeze, warnings: Array(warnings).freeze)
      end
    end
  end
end
