require "logger"
require "hive/config"
require "hive/gh"
require "hive/digest/repository"

module Hive
  module Digest
    class RepoResolver
      def initialize(registry: -> { Hive::Config.digest_registered_projects }, gh: Hive::Gh,
                     cfg: nil, logger: Logger.new($stderr))
        @registry = registry
        @gh = gh
        @cfg = cfg
        @logger = logger
      end

      def resolve(repos: [])
        warnings = []
        targets = Array(@registry.call).filter_map do |entry|
          resolve_entry(entry)
        rescue StandardError => e
          project = entry_name(entry)
          warning = Warning.new(
            kind: "repository_discovery_failed",
            repository: project,
            message: "Could not resolve registered project #{project}: #{safe_error(e)}"
          )
          warnings << warning
          @logger&.warn("digest: #{warning.message}")
          nil
        end
        targets = targets.uniq(&:key)
        raise_no_scope! if targets.empty?

        requested = normalize_filters(repos)
        targets = filter_targets(targets, requested) unless requested.empty?
        Resolution.new(targets: targets, warnings: warnings)
      rescue Hive::ConfigError
        raise
      rescue StandardError => e
        raise Hive::ConfigError, "hive digest: repository discovery failed: #{safe_error(e)}"
      end

      private

      def resolve_entry(entry)
        path = entry.fetch("path")
        identity = @gh.repository_identity(path, cfg: @cfg)
        RepositoryTarget.new(
          project_name: entry.fetch("name", File.basename(path)),
          path: path,
          repository: identity.fetch("repository"),
          host: identity.fetch("host")
        )
      end

      def normalize_filters(repos)
        supplied = Array(repos).flatten
        return [] if supplied.empty?

        values = supplied.flat_map { |repo| repo.to_s.split(/\s+/) }.reject(&:empty?)
        invalid = supplied.find { |repo| repo.to_s.strip.empty? }
        raise_invalid_filter!(invalid) if invalid || values.empty?

        values.map do |value|
          Hive::Gh::RepositoryIdentity.validated_repository_slug(value)
        rescue Hive::GhError
          raise_invalid_filter!(value)
        end.uniq(&:downcase)
      end

      def filter_targets(targets, requested)
        known = targets.to_h { |target| [ target.repository.downcase, target ] }
        missing = requested.reject { |repo| known.key?(repo.downcase) }
        unless missing.empty?
          raise Hive::ConfigError,
                "hive digest: --repo #{missing.join(', ')} is not registered; use owner/name from a registered project"
        end

        requested_keys = requested.map(&:downcase)
        targets.select { |target| requested_keys.include?(target.repository.downcase) }
      end

      def raise_invalid_filter!(value)
        raise Hive::ConfigError, "hive digest: --repo must be owner/name; got #{value.inspect}"
      end

      def raise_no_scope!
        raise Hive::ConfigError,
              "hive digest: no registered GitHub repositories could be resolved"
      end

      def entry_name(entry)
        value = entry.fetch("name", File.basename(entry.fetch("path"))).to_s.strip
        value.empty? ? "<malformed>" : value
      rescue StandardError
        "<malformed>"
      end

      def safe_error(error)
        text = error.message.to_s.lines.first.to_s.strip
        text.empty? ? error.class.name : text
      end
    end
  end
end
