require "logger"
require "hive/config"
require "hive/gh"
require "hive/digest/merged_pr/record"

module Hive
  module Digest
    module MergedPr
      class RepoResolver
        REPO_SLUG = %r{\A[^/\s]+/[^/\s]+\z}.freeze

        attr_reader :warnings

        def initialize(registry: -> { Hive::Config.registered_projects }, gh: Hive::Gh,
                       cfg: nil, logger: Logger.new($stderr))
          @registry = registry
          @gh = gh
          @cfg = cfg
          @logger = logger
          @warnings = []
        end

        def resolve(repos: [])
          @warnings = []
          explicit = Array(repos).flat_map { |repo| repo.to_s.split(/\s+/) }.reject(&:empty?)
          return Resolution.new(repos: validate_explicit(explicit).uniq, warnings: warnings) unless explicit.empty?

          slugs = []
          @registry.call.each do |entry|
            slugs << resolve_project(entry)
          rescue Hive::GhError, StandardError => e
            warn("merged-pr digest: dropping project #{entry_name(entry)} during repo resolution: #{e.message}")
          end
          Resolution.new(repos: slugs.compact.uniq, warnings: warnings)
        end

        private

        def validate_explicit(repos)
          repos.each do |repo|
            next if repo.match?(REPO_SLUG)

            raise Hive::ConfigError, "hive digest: --repo must be owner/name; got #{repo.inspect}"
          end
        end

        def resolve_project(entry)
          @gh.repo_name_with_owner(entry.fetch("path"), cfg: @cfg)
        end

        def entry_name(entry)
          entry.fetch("name", entry.fetch("path", "<unknown>"))
        rescue NoMethodError
          "<malformed>"
        end

        def warn(message)
          @warnings << message
          @logger&.warn(message)
        end
      end
    end
  end
end
