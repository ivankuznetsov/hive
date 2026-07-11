require "digest"
require "json"
require "uri"
require "hive/refactor_patrol/fingerprint"

module Hive
  module RefactorPatrol
    # Pure, language-neutral identity and matching for reworded architecture
    # theses. Exact thesis fingerprints remain occurrence identities; this
    # module groups compatible occurrences behind one durable family id.
    module SemanticFamily
      VERSION = 1
      ID_PREFIX = "af#{VERSION}-".freeze
      MIN_ANCHOR_OVERLAP = 0.5
      MIN_CONCEPT_OVERLAP = 0.35

      PROBLEM_KINDS = %w[
        mixed_responsibilities
        duplicated_policy
        scattered_contract
        boundary_leak
        cyclic_dependency
        unstable_dependency
        oversized_component
        parallel_implementations
        missing_abstraction
        other
      ].freeze

      REFACTOR_KINDS = %w[
        extract_boundary
        consolidate_policy
        consolidate_contract
        split_component
        move_responsibility
        introduce_adapter
        invert_dependency
        other
      ].freeze

      DESCRIPTOR_KEYS = %w[
        host repository component problem_kind refactor_kind anchors concepts
      ].freeze

      Result = Struct.new(
        :status, :family_id, :descriptor, :matched_family_ids, :reason,
        keyword_init: true
      ) do
        def matched? = status == "matched"
        def ambiguous? = status == "family_ambiguous"
        def new_family? = status == "new_family"

        def to_h
          {
            "status" => status,
            "family_id" => family_id,
            "descriptor" => descriptor,
            "matched_family_ids" => matched_family_ids,
            "reason" => reason
          }
        end
      end

      module_function

      def descriptor(repository:, component:, problem_kind:, refactor_kind:, anchors:, concepts:,
                     host: "github.com")
        normalize_descriptor(
          "host" => host,
          "repository" => repository,
          "component" => component,
          "problem_kind" => problem_kind,
          "refactor_kind" => refactor_kind,
          "anchors" => anchors,
          "concepts" => concepts
        )
      end

      def family(family_id:, descriptor:, occurrence_fingerprints: [])
        id = nonempty_string(family_id, "family_id")
        deep_freeze(
          "family_id" => id,
          "descriptor" => normalize_descriptor(descriptor),
          "occurrence_fingerprints" => normalized_strings(
            occurrence_fingerprints, "occurrence_fingerprints"
          )
        )
      end

      def id_for(value)
        id_for_normalized(normalize_descriptor(value))
      end

      def id_for_normalized(normalized)
        payload = DESCRIPTOR_KEYS.to_h { |key| [ key, normalized.fetch(key) ] }
        "#{ID_PREFIX}#{::Digest::SHA256.hexdigest("hive-architecture-family-v#{VERSION}\0#{JSON.generate(payload)}")}"
      end
      private_class_method :id_for_normalized

      # Resolution order is deliberately strict: a durable occurrence alias is
      # authoritative, then an explicitly hinted compatible family, then the
      # deterministic structural matcher. Hints fail closed when stale or
      # incompatible instead of silently creating a second family.
      def resolve(descriptor:, families:, occurrence_fingerprint:, hinted_family_id: nil)
        candidate = normalize_descriptor(descriptor)
        occurrence = nonempty_string(occurrence_fingerprint, "occurrence_fingerprint")
        records = normalize_families(families)

        aliases = records.select do |record|
          record.fetch("occurrence_fingerprints").include?(occurrence)
        end
        unless aliases.empty?
          return resolution_from_matches(
            aliases,
            unique_reason: "occurrence_fingerprint_alias",
            ambiguous_reason: "duplicate_occurrence_fingerprint_alias"
          )
        end

        unless hinted_family_id.nil? || hinted_family_id.to_s.strip.empty?
          hint = hinted_family_id.to_s.strip
          hinted = records.find { |record| record.fetch("family_id") == hint }
          unless hinted
            return ambiguous_result([], "unknown_family_hint", descriptor: candidate)
          end
          unless compatible_descriptors?(candidate, hinted.fetch("descriptor"))
            return ambiguous_result([ hinted ], "incompatible_family_hint", descriptor: candidate)
          end

          return matched_result(hinted, "compatible_family_hint")
        end

        matches = records.select do |record|
          compatible_descriptors?(candidate, record.fetch("descriptor"))
        end
        return matched_result(matches.first, "structural_match") if matches.one?
        if matches.size > 1
          return ambiguous_result(matches, "multiple_compatible_families", descriptor: candidate)
        end

        result(
          status: "new_family",
          family_id: id_for_normalized(candidate),
          descriptor: candidate,
          matched_family_ids: [],
          reason: "no_compatible_family"
        )
      end

      def compatible?(left, right)
        candidate = normalize_descriptor(left)
        existing = normalize_descriptor(right)
        compatible_descriptors?(candidate, existing)
      end

      def compatible_descriptors?(candidate, existing)
        return false unless candidate.fetch("host") == existing.fetch("host")
        return false unless candidate.fetch("repository") == existing.fetch("repository")
        return false unless candidate.fetch("component") == existing.fetch("component")
        return false unless candidate.fetch("problem_kind") == existing.fetch("problem_kind")
        return false unless candidate.fetch("refactor_kind") == existing.fetch("refactor_kind")
        return false if overlap(candidate.fetch("anchors"), existing.fetch("anchors")) < MIN_ANCHOR_OVERLAP

        overlap(candidate.fetch("concepts"), existing.fetch("concepts")) >= MIN_CONCEPT_OVERLAP
      end
      private_class_method :compatible_descriptors?

      def overlap(left, right)
        Fingerprint.overlap_coefficient(Array(left), Array(right))
      end

      def normalize_descriptor(value)
        unless value.is_a?(Hash)
          raise ArgumentError, "descriptor must be a Hash"
        end

        unknown = value.keys.map(&:to_s) - DESCRIPTOR_KEYS
        raise ArgumentError, "descriptor has unknown keys #{unknown.sort.inspect}" unless unknown.empty?

        problem_kind = fetch_key(value, "problem_kind").to_s
        refactor_kind = fetch_key(value, "refactor_kind").to_s
        unless PROBLEM_KINDS.include?(problem_kind)
          raise ArgumentError, "problem_kind must be one of #{PROBLEM_KINDS.inspect}; got #{problem_kind.inspect}"
        end
        unless REFACTOR_KINDS.include?(refactor_kind)
          raise ArgumentError, "refactor_kind must be one of #{REFACTOR_KINDS.inspect}; got #{refactor_kind.inspect}"
        end

        anchors = Array(fetch_key(value, "anchors")).map { |anchor| normalize_anchor(anchor) }.uniq.sort
        raise ArgumentError, "anchors must contain at least one repository-relative target" if anchors.empty?

        concepts = concept_tokens(fetch_key(value, "concepts"))
        raise ArgumentError, "concepts must contain at least one normalized token" if concepts.empty?

        deep_freeze(
          "host" => normalize_host(optional_key(value, "host") || "github.com"),
          "repository" => normalize_repository(fetch_key(value, "repository")),
          "component" => normalize_component(fetch_key(value, "component")),
          "problem_kind" => problem_kind,
          "refactor_kind" => refactor_kind,
          "anchors" => anchors,
          "concepts" => concepts
        )
      rescue KeyError => e
        raise ArgumentError, "descriptor is missing #{e.key.inspect}"
      end
      private_class_method :normalize_descriptor

      def normalize_families(values)
        records = Array(values).map do |value|
          unless value.is_a?(Hash)
            raise ArgumentError, "family must be a Hash"
          end

          family(
            family_id: fetch_key(value, "family_id"),
            descriptor: fetch_key(value, "descriptor"),
            occurrence_fingerprints: optional_key(value, "occurrence_fingerprints") || []
          )
        rescue KeyError => e
          raise ArgumentError, "family is missing #{e.key.inspect}"
        end
        duplicate = records.map { |record| record.fetch("family_id") }.tally.find { |_id, count| count > 1 }&.first
        raise ArgumentError, "duplicate family_id #{duplicate.inspect}" if duplicate

        records.sort_by { |record| record.fetch("family_id") }
      end
      private_class_method :normalize_families

      def resolution_from_matches(matches, unique_reason:, ambiguous_reason:)
        return matched_result(matches.first, unique_reason) if matches.one?

        ambiguous_result(matches, ambiguous_reason, descriptor: matches.first.fetch("descriptor"))
      end
      private_class_method :resolution_from_matches

      def matched_result(record, reason)
        result(
          status: "matched",
          family_id: record.fetch("family_id"),
          descriptor: record.fetch("descriptor"),
          matched_family_ids: [ record.fetch("family_id") ],
          reason: reason
        )
      end
      private_class_method :matched_result

      def ambiguous_result(matches, reason, descriptor:)
        result(
          status: "family_ambiguous",
          family_id: nil,
          descriptor: descriptor,
          matched_family_ids: matches.map { |record| record.fetch("family_id") }.uniq.sort,
          reason: reason
        )
      end
      private_class_method :ambiguous_result

      def result(status:, family_id:, descriptor:, matched_family_ids:, reason:)
        Result.new(
          status: status,
          family_id: family_id,
          descriptor: descriptor,
          matched_family_ids: matched_family_ids.sort.freeze,
          reason: reason
        ).freeze
      end
      private_class_method :result

      def normalize_repository(value)
        repository = value.to_s.strip.downcase
        segments = repository.split("/", -1)
        valid = segments.size == 2 && segments.all? { |segment| segment.match?(/\A[a-z0-9][a-z0-9_.-]*\z/) }
        raise ArgumentError, "repository must be an owner/name identity" unless valid

        repository
      end
      private_class_method :normalize_repository

      def normalize_host(value)
        host = value.to_s.strip.downcase
        uri = URI.parse("https://#{host}")
        valid = !host.empty? && uri.host == host && uri.path.empty? &&
                uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "host must be an exact hostname" unless valid

        host
      rescue URI::InvalidURIError
        raise ArgumentError, "host must be an exact hostname"
      end
      private_class_method :normalize_host

      def normalize_component(value)
        component = value.to_s.strip.tr("\\", "/").downcase
        segments = component.split("/").map do |segment|
          segment.strip.gsub(/[^a-z0-9_.@-]+/, "-").gsub(/\A-+|-+\z/, "")
        end.reject(&:empty?)
        raise ArgumentError, "component must be a non-empty stable boundary id" if segments.empty?

        segments.join("/")
      end
      private_class_method :normalize_component

      def normalize_anchor(value)
        anchor = value.to_s.strip.tr("\\", "/")
        anchor = anchor.sub(%r{\A(?:\./)+}, "").gsub(%r{/+}, "/")
        segments = anchor.split("/", -1)
        if anchor.empty? || anchor.start_with?("/") || segments.any? { |segment| segment.empty? || segment == ".." }
          raise ArgumentError, "anchor must be a repository-relative target; got #{value.inspect}"
        end

        anchor
      end
      private_class_method :normalize_anchor

      def concept_tokens(values)
        Array(values).flat_map do |value|
          value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").split
        end.reject(&:empty?).uniq.sort
      end
      private_class_method :concept_tokens

      def normalized_strings(values, label)
        Array(values).map { |value| nonempty_string(value, label) }.uniq.sort
      end
      private_class_method :normalized_strings

      def nonempty_string(value, label)
        string = value.to_s.strip
        raise ArgumentError, "#{label} must be a non-empty string" if string.empty?

        string
      end
      private_class_method :nonempty_string

      def fetch_key(hash, key)
        return hash.fetch(key) if hash.key?(key)
        return hash.fetch(key.to_sym) if hash.key?(key.to_sym)

        raise KeyError.new(key: key)
      end
      private_class_method :fetch_key

      def optional_key(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_sym] if hash.key?(key.to_sym)

        nil
      end
      private_class_method :optional_key

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
      private_class_method :deep_freeze
    end
  end
end
