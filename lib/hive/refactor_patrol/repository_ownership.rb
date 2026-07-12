require "hive/config"
require "hive/gh"
require "hive/refactor_patrol/job_store"
require "uri"

module Hive
  module RefactorPatrol
    # Resolves architecture-patrol ownership from the live registration set.
    # Every call is a fresh snapshot: repository remotes and consent may change
    # between scheduler candidate selection and the final external-effect fence.
    class RepositoryOwnership
      Decision = Struct.new(:authority, :reason, :evidence, keyword_init: true) do
        def full? = authority == :full
        def continuation_only? = authority == :continuation_only
        def blocked? = authority == :blocked
      end

      def self.continuation_evidence?(aggregate)
        aggregate.fetch("actions").any? do |action|
          next false if action.fetch("terminal")

          receipts = action.fetch("receipts")
          action.fetch("owner_job_id") != aggregate.fetch("job_id") ||
            receipts.key?("creation_intent") || receipts.key?("pr_url") ||
            receipts.key?("issue_url") || receipts.key?("review_task_path")
        end
      end

      def self.remote_continuation_evidence?(aggregate)
        aggregate.fetch("actions").any? do |action|
          next false if action.fetch("terminal")

          receipts = action.fetch("receipts")
          receipts["creation_intent"].is_a?(Hash) ||
            !receipts["pr_url"].to_s.empty? ||
            !receipts["issue_url"].to_s.empty? ||
            !receipts["review_task_path"].to_s.empty?
        end
      end

      def self.identity_from_source(source)
        uri = URI.parse(source.fetch("url").to_s)
        repository = source.fetch("repository").to_s
        number = source.fetch("number")
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil? &&
               uri.query.nil? && uri.fragment.nil? && match &&
               match[1].casecmp?(repository) && number.is_a?(Integer) &&
               number.positive? && match[2].to_i == number
          raise Hive::GhError, "source repository URL is invalid"
        end

        { "repository" => repository, "host" => uri.host }
      rescue KeyError, URI::InvalidURIError => e
        raise Hive::GhError, "source repository URL is invalid: #{e.message}"
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     identity_resolver: nil, continuation_resolver: nil,
                     require_registration: true)
        @registry = registry
        @config_loader = config_loader
        @require_registration = require_registration
        @continuation_resolver = continuation_resolver || method(:stored_continuation_identities)
        @identity_resolver = identity_resolver || lambda do |entry, cfg|
          Hive::Gh.repository_identity(entry.fetch("path"), cfg: cfg)
        end
      end

      # Candidate selection may evaluate several due jobs from the same set of
      # registrations. Resolve each registration/config/identity/continuation
      # input at most once for that pass, including failures, so one slow git
      # remote or large continuation ledger is not multiplied by job count.
      # Reservation and effect-time callers deliberately keep using #call on
      # the live resolver instead of retaining this snapshot.
      def snapshot
        registry_cache = {}
        config_cache = {}
        identity_cache = {}
        continuation_cache = {}

        self.class.new(
          registry: lambda do
            snapshot_fetch(registry_cache, :registrations) { Array(@registry.call) }
          end,
          config_loader: lambda do |path|
            snapshot_fetch(config_cache, File.expand_path(path)) do
              @config_loader.call(path)
            end
          end,
          identity_resolver: lambda do |entry, cfg|
            snapshot_fetch(identity_cache, entry_key(normalized_entry(entry))) do
              @identity_resolver.call(entry, cfg)
            end
          end,
          continuation_resolver: lambda do |entry, cfg|
            snapshot_fetch(continuation_cache, entry_key(normalized_entry(entry))) do
              @continuation_resolver.call(entry, cfg)
            end
          end,
          require_registration: @require_registration
        )
      end

      def call(entry:, cfg:, expected_identity: nil, continuation: false,
               continuation_owner: false)
        target = normalized_entry(entry)
        enabled, unresolved, registered, configured = enabled_registrations(target, cfg)
        participants = (enabled + [ [ target, cfg ] ]).uniq { |candidate, _| entry_key(candidate) }
        identities = resolve_identities(participants, unresolved)
        continuations = resolve_continuations(configured, unresolved)
        return unresolved_decision(unresolved) if unresolved.any?

        target_identity = identities.fetch(entry_key(target))
        expected = normalize_identity(expected_identity) if expected_identity
        [ target_identity, expected ].compact.uniq.each do |guarded_identity|
          enabled_owners = enabled.select do |candidate, _candidate_cfg|
            identities.fetch(entry_key(candidate)) == guarded_identity
          end.map(&:first)
          continuation_owners = continuations.select do |item|
            item.fetch(:identity) == guarded_identity
          end.map { |item| item.fetch(:entry) }
          if continuation_owner && expected == guarded_identity
            continuation_owners << target
          end
          owners = (enabled_owners + continuation_owners).uniq { |owner| entry_key(owner) }
          return duplicate_decision(guarded_identity, owners) if owners.size > 1
        end

        if @require_registration && !registered
          return decision(
            :blocked,
            "repository_registration_missing",
            registration_evidence(target)
          )
        end

        if expected && !identity_matches?(target_identity, expected)
          evidence = identity_evidence(target_identity).merge(
            "expected_repository" => identity_repository(expected_identity),
            "expected_host" => identity_host(expected_identity)
          ).compact
          return decision(
            continuation ? :continuation_only : :blocked,
            "repository_identity_drift", evidence
          )
        end

        if cfg.dig("refactor_patrol", "enabled") == true
          decision(:full)
        elsif continuation
          decision(:continuation_only, "architecture_patrol_disabled")
        else
          decision(:blocked, "architecture_patrol_disabled")
        end
      rescue StandardError => e
        unresolved_decision(
          [ registration_evidence(entry).merge("error" => "#{e.class}: #{e.message}") ]
        )
      end

      private

      def snapshot_fetch(cache, key)
        captured = cache[key]
        unless captured
          captured = begin
            { value: immutable_copy(yield) }.freeze
          rescue StandardError => e
            { error: e }.freeze
          end
          cache[key] = captured
        end
        raise captured.fetch(:error) if captured.key?(:error)

        captured.fetch(:value)
      end

      def immutable_copy(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), copy|
            copy[immutable_copy(key)] = immutable_copy(item)
          end.freeze
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value.freeze
        end
      end

      def enabled_registrations(target, target_cfg)
        unresolved = []
        entries = Array(@registry.call).map { |entry| normalized_entry(entry) }
        registered = entries.any? { |entry| entry_key(entry) == entry_key(target) }
        configured = entries.filter_map do |entry|
          cfg = if entry_key(entry) == entry_key(target)
            target_cfg
          else
            @config_loader.call(entry.fetch("path"))
          end
          [ entry, cfg ]
        rescue StandardError => e
          unresolved << registration_evidence(entry).merge("error" => "#{e.class}: #{e.message}")
          nil
        end
        enabled = configured.select { |_entry, cfg| cfg.dig("refactor_patrol", "enabled") == true }
        [ enabled, unresolved, registered, configured ]
      rescue StandardError => e
        unresolved << registration_evidence(target).merge("error" => "#{e.class}: #{e.message}")
        [ [], unresolved, false, [] ]
      end

      def resolve_identities(participants, unresolved)
        participants.each_with_object({}) do |(entry, cfg), identities|
          identities[entry_key(entry)] = normalize_identity(@identity_resolver.call(entry, cfg))
        rescue StandardError => e
          unresolved << registration_evidence(entry).merge("error" => "#{e.class}: #{e.message}")
        end
      end

      def resolve_continuations(configured, unresolved)
        configured.filter_map do |entry, cfg|
          Array(@continuation_resolver.call(entry, cfg)).map do |identity|
            { entry: entry, identity: normalize_identity(identity) }
          end
        rescue StandardError => e
          unresolved << registration_evidence(entry).merge("error" => "#{e.class}: #{e.message}")
          nil
        end.flatten
      end

      def stored_continuation_identities(entry, _cfg)
        JobStore.new(entry.fetch("path")).each_job.filter_map do |aggregate|
          self.class.identity_from_source(aggregate.fetch("source")) if
            self.class.remote_continuation_evidence?(aggregate)
        end.uniq
      end

      def normalized_entry(entry)
        {
          "name" => entry.fetch("name").to_s,
          "path" => File.expand_path(entry.fetch("path"))
        }
      end

      def entry_key(entry)
        [ entry.fetch("name"), entry.fetch("path") ]
      end

      def normalize_identity(identity)
        repository = identity_repository(identity).to_s.strip
        host = identity_host(identity).to_s.strip
        segments = repository.split("/", -1)
        valid_repository = segments.size == 2 && segments.all? do |segment|
          segment.match?(/\A[a-zA-Z0-9_.-]+\z/) && !%w[. ..].include?(segment)
        end
        unless valid_repository
          raise Hive::GhError, "repository identity must be an owner/name slug"
        end
        unless valid_host?(host)
          raise Hive::GhError, "repository identity must include an exact host"
        end

        { "repository" => repository.downcase, "host" => host.downcase }
      end

      def identity_repository(identity)
        identity.is_a?(Hash) ? identity["repository"] || identity[:repository] : identity
      end

      def identity_host(identity)
        identity.is_a?(Hash) ? identity["host"] || identity[:host] : nil
      end

      def identity_matches?(actual, expected)
        actual == expected
      end

      def valid_host?(host)
        return false if host.empty?

        uri = URI.parse("https://#{host}")
        uri.host == host && uri.path.empty? && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil?
      rescue URI::InvalidURIError
        false
      end

      def decision(authority, reason = nil, evidence = {})
        Decision.new(authority: authority, reason: reason, evidence: evidence)
      end

      def duplicate_decision(identity, registrations)
        decision(
          :blocked,
          "duplicate_repository_registration",
          {
            "repository" => identity.fetch("repository"),
            "host" => identity["host"],
            "registrations" => registrations.map { |entry| registration_evidence(entry) }
                                            .sort_by { |item| [ item.fetch("name"), item.fetch("path") ] }
          }.compact
        )
      end

      def unresolved_decision(unresolved)
        decision(
          :blocked,
          "repository_identity_unresolved",
          "unresolved_registrations" => unresolved.sort_by do |item|
            [ item.fetch("name", ""), item.fetch("path", "") ]
          end
        )
      end

      def identity_evidence(identity)
        {
          "current_repository" => identity.fetch("repository"),
          "current_host" => identity["host"]
        }.compact
      end

      def registration_evidence(entry)
        {
          "name" => entry.fetch("name").to_s,
          "path" => File.expand_path(entry.fetch("path"))
        }
      end
    end
  end
end
