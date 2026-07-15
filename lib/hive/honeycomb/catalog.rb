require "rubygems"
require "hive/honeycomb/reference"

module Hive
  module Honeycomb
    Release = Data.define(:name, :version, :tag, :sha, :digest)
    ResolvedPin = Data.define(
      :source, :name, :sha, :version, :tag, :digest, :selector_kind, :selector_value
    )

    class Catalog
      ROOT_KEYS = %w[version workflows].freeze
      WORKFLOW_KEYS = %w[latest releases].freeze
      RELEASE_KEYS = %w[version tag sha digest].freeze
      SHA_RE = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
      DIGEST_RE = /\A[0-9a-f]{64}\z/
      TAG_RE = /\A(?![-.])(?!.*(?:\.\.|\/\/|@\{|\\))[A-Za-z0-9][A-Za-z0-9._\/-]*[A-Za-z0-9]\z/

      attr_reader :workflows, :raw

      def self.load(raw)
        parsed = Honeycomb.safe_yaml_load(raw, label: "honeycomb catalog", error_class: CatalogError)
        new(parsed, raw: raw)
      end

      def initialize(data, raw: nil)
        @raw = raw
        root = mapping!(data, "catalog")
        exact_keys!(root, ROOT_KEYS, "catalog")
        raise CatalogError, "honeycomb catalog version must be #{CATALOG_VERSION}" unless root["version"] == CATALOG_VERSION

        workflow_map = mapping!(root["workflows"], "catalog workflows")
        raise CatalogError, "honeycomb catalog workflows must not be empty" if workflow_map.empty?

        @workflows = workflow_map.keys.sort.to_h do |name|
          validate_name!(name)
          [ name, parse_workflow(name, workflow_map.fetch(name)) ]
        end.freeze
      end

      def workflow_names = workflows.keys

      def releases_for(name)
        workflow = workflows[name]
        raise ResolutionError, "unknown honeycomb workflow #{name.inspect}" unless workflow

        workflow.fetch(:releases)
      end

      def latest_for(name)
        workflow = workflows[name]
        raise ResolutionError, "unknown honeycomb workflow #{name.inspect}" unless workflow

        workflow.fetch(:by_version).fetch(workflow.fetch(:latest))
      end

      def resolve(reference, allow_unknown_full_sha: false)
        ref = reference.is_a?(Reference) ? reference : Reference.parse(reference)
        release, kind = select_release(ref)
        if release
          return ResolvedPin.new(
            source: SOURCE,
            name: ref.name,
            sha: release.sha,
            version: release.version,
            tag: release.tag,
            digest: release.digest,
            selector_kind: kind,
            selector_value: ref.selector
          )
        end

        if allow_unknown_full_sha && ref.selector && [ 40, 64 ].include?(ref.selector.length)
          return ResolvedPin.new(
            source: SOURCE, name: ref.name, sha: ref.selector, version: nil, tag: nil,
            digest: nil, selector_kind: "sha", selector_value: ref.selector
          )
        end

        raise ResolutionError, "selector #{ref.selector.inspect} is not recorded for honeycomb/#{ref.name}"
      end

      private

      def parse_workflow(name, value)
        data = mapping!(value, "workflow #{name.inspect}")
        exact_keys!(data, WORKFLOW_KEYS, "workflow #{name.inspect}")
        latest = exact_semver!(data["latest"], "workflow #{name.inspect} latest")
        releases_data = data["releases"]
        unless releases_data.is_a?(Array) && releases_data.any?
          raise CatalogError, "workflow #{name.inspect} releases must be a non-empty array"
        end

        releases = releases_data.map.with_index { |release, index| parse_release(name, release, index) }
        reject_duplicates!(releases, :version, name)
        reject_duplicates!(releases, :tag, name)
        reject_duplicates!(releases, :sha, name)
        reject_duplicates!(releases, :digest, name)
        by_version = releases.to_h { |release| [ release.version, release ] }
        raise CatalogError, "workflow #{name.inspect} latest #{latest.inspect} does not name a release" unless by_version.key?(latest)

        { latest: latest, releases: releases.freeze, by_version: by_version.freeze }.freeze
      end

      def parse_release(name, value, index)
        label = "workflow #{name.inspect} release #{index}"
        data = mapping!(value, label)
        exact_keys!(data, RELEASE_KEYS, label)
        version = exact_semver!(data["version"], "#{label} version")
        tag = string!(data["tag"], "#{label} tag")
        raise CatalogError, "#{label} tag #{tag.inspect} is unsafe" unless TAG_RE.match?(tag) && !tag.end_with?(".lock")

        sha = string!(data["sha"], "#{label} sha").downcase
        digest = string!(data["digest"], "#{label} digest").downcase
        raise CatalogError, "#{label} sha must be a full Git object id" unless SHA_RE.match?(sha)
        raise CatalogError, "#{label} digest must be a SHA-256 hex digest" unless DIGEST_RE.match?(digest)

        Release.new(name: name, version: version, tag: tag, sha: sha, digest: digest)
      end

      def select_release(ref)
        workflow = workflows[ref.name]
        raise ResolutionError, "unknown honeycomb workflow #{ref.name.inspect}" unless workflow
        return [ workflow.fetch(:by_version).fetch(workflow.fetch(:latest)), "latest" ] unless ref.selector

        if ref.version_selector?
          return [ workflow.fetch(:by_version)[ref.selector], "version" ]
        end

        releases = workflow.fetch(:releases)
        digest = releases.find { |release| release.digest == ref.selector }
        return [ digest, "digest" ] if digest

        exact_sha = releases.find { |release| release.sha == ref.selector }
        return [ exact_sha, "sha" ] if exact_sha

        unless [ 40, 64 ].include?(ref.selector.length)
          matches = releases.select do |release|
            ref.selector.length < release.sha.length && release.sha.start_with?(ref.selector)
          end
          raise ResolutionError, "SHA prefix #{ref.selector.inspect} is ambiguous" if matches.length > 1
          return [ matches.first, "sha" ] if matches.one?
        end
        [ nil, nil ]
      end

      def mapping!(value, label)
        raise CatalogError, "#{label} must be a mapping" unless value.is_a?(Hash)
        value.each_key do |key|
          raise CatalogError, "#{label} contains non-string key #{key.inspect}" unless key.is_a?(String)
        end
        value
      end

      def exact_keys!(data, keys, label)
        missing = keys - data.keys
        unknown = data.keys - keys
        raise CatalogError, "#{label} missing key(s) #{missing.inspect}" unless missing.empty?
        raise CatalogError, "#{label} contains unknown key(s) #{unknown.inspect}" unless unknown.empty?
      end

      def validate_name!(name)
        unless name.is_a?(String) && REFERENCE_NAME_RE.match?(name)
          raise CatalogError, "invalid catalog workflow name #{name.inspect}"
        end
      end

      def string!(value, label)
        return value if value.is_a?(String) && !value.empty?
        raise CatalogError, "#{label} must be a non-empty string"
      end

      def exact_semver!(value, label)
        string = string!(value, label)
        raise CatalogError, "#{label} must be an exact SemVer" unless SEMVER_RE.match?(string)
        string
      end

      def reject_duplicates!(releases, field, name)
        values = releases.map { |release| release.public_send(field) }
        duplicate = values.group_by(&:itself).find { |_value, copies| copies.length > 1 }&.first
        raise CatalogError, "workflow #{name.inspect} has duplicate release #{field} #{duplicate.inspect}" if duplicate
      end
    end
  end
end
