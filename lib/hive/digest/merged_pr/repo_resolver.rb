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
          # A present-but-blank --repo (e.g. "  ") is an explicit scope attempt,
          # not "resolve everything": keep it out of `explicit` (no valid tokens)
          # but remember it so we raise the owner/name error instead of silently
          # inverting the user's intent into auto-resolve-all-projects.
          requested = Array(repos).reject { |repo| repo.to_s.empty? }
          explicit = requested.flat_map { |repo| repo.to_s.split(/\s+/) }.reject(&:empty?)
          unless requested.empty?
            if explicit.empty?
              raise Hive::ConfigError,
                    "hive digest: --repo must be owner/name; got #{requested.first.inspect}"
            end

            return Resolution.new(repos: dedup(validate_explicit(explicit)), warnings: warnings)
          end

          slugs = []
          @registry.call.each do |entry|
            slugs << resolve_project(entry)
          rescue StandardError => e
            warn("merged-pr digest: dropping project #{entry_name(entry)} during repo resolution: #{e.message}")
          end
          Resolution.new(repos: dedup(slugs.compact), warnings: warnings)
        end

        private

        # GitHub owner/name slugs are case-insensitive, so dedup accordingly and
        # keep the first-seen casing — otherwise `Owner/Repo` and `owner/repo`
        # survive as two entries and produce duplicate gh calls / repo sections.
        def dedup(repos)
          repos.uniq { |repo| repo.downcase }
        end

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
