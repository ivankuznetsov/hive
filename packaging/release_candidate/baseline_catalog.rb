# frozen_string_literal: true

require "date"
require "bundler"
require "digest"
require "json"
require "pathname"
require "uri"
require "yaml"
require_relative "paths"

module HiveReleaseCandidate
  class BaselineCatalog
    Entry = Data.define(
      :id, :version, :tag, :owner, :reviewed_on, :rationale, :incident,
      :retirement, :required_platforms, :oracles, :packages, :dependency_closure
    )

    TOP_KEYS = %w[latest_stable rows schema schema_version].freeze
    ROW_KEYS = %w[
      dependency_closure id incident oracles owner packages rationale
      required_platforms retirement reviewed_on tag version
    ].freeze
    ORACLE_KEYS = %w[after before idempotency transition].freeze
    PACKAGE_KEYS = %w[artifact authentication tag version].freeze
    ARTIFACT_KEYS = %w[filename sha256 size url].freeze
    AUTH_KEYS = %w[certificate checksum identity issuer signature].freeze
    AUTH_ASSET_KEYS = %w[filename sha256 size url].freeze
    CLOSURE_KEYS = %w[lock observer_lock offline_cache ruby schema_version].freeze
    LOCK_KEYS = %w[path sha256 source_tag].freeze
    CACHE_KEYS = %w[
      completeness manifest_filename manifest_path manifest_sha256 network
      required_artifact_fields
    ].freeze
    SAFE_ID = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
    SAFE_TAG = /\Av[0-9]+\.[0-9]+\.[0-9]+\z/.freeze
    SHA256 = /\A[0-9a-f]{64}\z/.freeze
    PLATFORMS = %w[linux-x86_64 linux-arm64 macos-arm64].freeze
    REPOSITORY = "ivankuznetsov/hive"

    attr_reader :source, :raw, :entries, :digest, :dependency_closure_digest

    def self.load(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink?
        raise Error, "baseline catalog must be a regular file: #{path}"
      end

      parse(File.binread(path), source: path)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot read baseline catalog #{path}: #{e.message}"
    end

    def self.parse(content, source: "baselines.yml")
      raw = YAML.safe_load(content, permitted_classes: [ Date ], aliases: false)
      new(raw, source: source, content: content)
    rescue Psych::Exception => e
      raise Error, "invalid baseline catalog YAML in #{source}: #{e.message}"
    end

    def initialize(raw, source:, content:)
      @source = source
      @raw = string_hash(raw, "baseline catalog")
      exact_keys!(@raw, TOP_KEYS, "baseline catalog")
      unless @raw["schema"] == "hive-release-candidate-baselines" &&
             @raw["schema_version"] == SCHEMA_VERSION
        raise Error, "unsupported baseline catalog schema"
      end
      rows = @raw["rows"]
      raise Error, "baseline catalog rows must be a non-empty array" unless rows.is_a?(Array) && !rows.empty?

      @entries = rows.map.with_index { |row, index| parse_row(row, index) }
      duplicate = @entries.group_by(&:id).find { |_id, grouped| grouped.length > 1 }
      raise Error, "duplicate baseline id #{duplicate.first}" if duplicate
      unless @entries.one? { |entry| entry.id == @raw["latest_stable"] }
        raise Error, "latest_stable must resolve to exactly one baseline row"
      end
      @digest = Digest::SHA256.hexdigest(content)
      closures = @entries.sort_by(&:id).to_h { |entry| [ entry.id, entry.dependency_closure ] }
      @dependency_closure_digest = Digest::SHA256.hexdigest(JSON.generate(closures))
    end

    def latest_stable
      fetch(raw.fetch("latest_stable"))
    end

    def fetch(id)
      entries.find { |entry| entry.id == id.to_s } ||
        raise(UsageError, "unknown release baseline #{id.inspect}")
    end

    def all_artifacts
      entries.flat_map do |entry|
        entry.packages.values.map { |package| package.fetch("artifact") }
      end
    end

    def package_requirements
      entries.flat_map do |entry|
        entry.packages.map do |role, package|
          {
            "row_id" => entry.id,
            "role" => role,
            "tag" => package.fetch("tag"),
            "descriptors" => [
              package.fetch("artifact"),
              *%w[checksum signature certificate].map do |kind|
                package.fetch("authentication").fetch(kind)
              end
            ]
          }
        end
      end
    end

    def fetch_argv(cache_root:, missing: nil)
      missing_keys = missing&.map { |item| [ item.fetch("tag"), item.fetch("filename") ] }
      package_requirements.flat_map do |requirement|
        requirement.fetch("descriptors").map do |descriptor|
          filename = descriptor.fetch("filename")
          next if missing_keys && !missing_keys.include?([ requirement.fetch("tag"), filename ])

          [
            "gh", "release", "download", requirement.fetch("tag"),
            "--repo", REPOSITORY, "--pattern", filename,
            "--dir", File.join(File.expand_path(cache_root), requirement.fetch("tag"))
          ]
        end
      end.compact.uniq
    end

    def input_payload(path: "packaging/release_candidate/baselines.yml")
      {
        "schema" => "hive-release-candidate-baseline-input",
        "schema_version" => SCHEMA_VERSION,
        "status" => "available",
        "path" => path,
        "sha256" => digest,
        "catalog_dependency_closure_sha256" => dependency_closure_digest,
        "latest_stable_id" => latest_stable.id,
        "latest_stable_version" => latest_stable.version,
        "rows" => entries.map(&:id)
      }
    end

    def freshness(observed_tag:, observed_prerelease:)
      observed = observed_tag.to_s
      passed = !observed_prerelease && observed == latest_stable.tag
      {
        "status" => passed ? "passed" : "failed",
        "reason" => passed ? nil : "baseline_catalog_stale",
        "catalog_tag" => latest_stable.tag,
        "observed_tag" => observed,
        "observed_prerelease" => !!observed_prerelease,
        "catalog_mutated" => false
      }
    end

    def verify_dependency_closure!(entry, lock_contents:, expected_lock_sha256s: nil,
                                   cache_manifest_content:, artifact_root: nil)
      expected = expected_lock_sha256s || begin
        values = {
          "producer" => entry.dependency_closure.fetch("lock").fetch("sha256")
        }
        if entry.dependency_closure["observer_lock"]
          values["observer"] = entry.dependency_closure.fetch("observer_lock").fetch("sha256")
        end
        values
      end
      unless lock_contents.is_a?(Hash) && lock_contents.keys.sort == expected.keys.sort
        raise Error, "#{entry.id} dependency lock roles are incomplete"
      end
      actual = lock_contents.to_h do |role, content|
        [ role, Digest::SHA256.hexdigest(content) ]
      end
      mismatched = expected.keys.find { |role| actual.fetch(role) != expected.fetch(role) }
      raise Error, "#{entry.id} #{mismatched} dependency lock digest mismatch" if mismatched
      manifest = JSON.parse(cache_manifest_content)
      required = %w[artifacts completeness lock_sha256s network schema schema_version]
      unless manifest.is_a?(Hash) && manifest.keys.sort == required.sort &&
             manifest["schema"] == "hive-release-candidate-offline-gem-cache" &&
             manifest["schema_version"] == 1 &&
             manifest["lock_sha256s"] == actual &&
             manifest["completeness"] == "exact-locked-runtime-transitive-closure" &&
             manifest["network"] == "forbidden"
        raise Error, "#{entry.id} offline cache manifest identity is invalid"
      end
      artifacts = manifest["artifacts"]
      unless artifacts.is_a?(Array) && !artifacts.empty? &&
             artifacts.uniq { |item| item["filename"] }.length == artifacts.length
        raise Error, "#{entry.id} offline cache is not a complete unique closure"
      end
      expected_filenames = runtime_closure_filenames(lock_contents)
      actual_filenames = artifacts.map { |artifact| artifact["filename"] }.sort
      unless actual_filenames == expected_filenames
        raise Error, "#{entry.id} offline cache does not match the locked runtime closure"
      end
      artifacts.each do |artifact|
        unless artifact.is_a?(Hash) && artifact.keys.sort == %w[filename sha256 size] &&
               artifact["filename"].is_a?(String) &&
               artifact["filename"] == File.basename(artifact["filename"]) &&
               artifact["filename"].end_with?(".gem") &&
               artifact["size"].is_a?(Integer) && artifact["size"].positive? &&
               SHA256.match?(artifact["sha256"].to_s)
          raise Error, "#{entry.id} offline cache artifact is invalid"
        end
      end
      verify_closure_files!(entry, artifacts, artifact_root) if artifact_root
      true
    rescue JSON::ParserError => e
      raise Error, "#{entry.id} offline cache manifest JSON is invalid: #{e.message}"
    end

    def runtime_closure_filenames(lock_contents)
      runtime_closure_artifacts(lock_contents).map { |artifact| artifact.fetch("filename") }.sort
    end

    def runtime_closure_artifacts(lock_contents)
      specs = lock_contents.values.flat_map do |content|
        Bundler::LockfileParser.new(content).specs
      end
      by_name = specs.group_by(&:name)
      roots = by_name.fetch("hive-cli") do
        raise Error, "dependency lock omits hive-cli"
      end
      pending = roots.flat_map(&:dependencies)
      visited = {}
      selected = []
      until pending.empty?
        dependency = pending.shift
        name = dependency.name
        next if visited[name]
        visited[name] = true
        variants = by_name[name]
        unless variants
          selected << omitted_bundler_artifact(dependency)
          next
        end
        selected.concat(variants.map { |spec| artifact_for(spec) })
        pending.concat(variants.flat_map(&:dependencies))
      end
      selected.uniq { |artifact| artifact.fetch("filename") }.
        sort_by { |artifact| artifact.fetch("filename") }
    rescue Bundler::LockfileError => e
      raise Error, "dependency lock is invalid: #{e.message}"
    end

    private

    def artifact_for(spec)
      {
        "name" => spec.name,
        "version" => spec.version.to_s,
        "platform" => spec.platform.to_s,
        "filename" => "#{spec.full_name}.gem"
      }
    end

    # Bundler intentionally omits its own gem specification from Gemfile.lock,
    # even when an application gem has an exact runtime dependency on Bundler.
    # Accept only that one well-defined omission and derive the artifact from
    # the exact dependency requirement; every other missing runtime gem fails.
    def omitted_bundler_artifact(dependency)
      requirements = dependency.requirement.requirements
      unless dependency.name == "bundler" &&
             requirements.length == 1 &&
             requirements.first.first == "="
        raise Error, "dependency lock omits runtime gem #{dependency.name}"
      end
      version = requirements.first.last.to_s
      {
        "name" => "bundler",
        "version" => version,
        "platform" => "ruby",
        "filename" => "bundler-#{version}.gem"
      }
    end

    def verify_closure_files!(entry, artifacts, artifact_root)
      root = File.expand_path(artifact_root)
      stat = File.lstat(root)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "#{entry.id} offline gem cache must be an owned directory"
      end
      expected = artifacts.map { |artifact| artifact.fetch("filename") }.sort
      unless Dir.children(root).sort == expected
        raise Error, "#{entry.id} offline gem cache is incomplete or unmanifested"
      end
      artifacts.each do |artifact|
        path = File.join(root, artifact.fetch("filename"))
        file = File.lstat(path)
        unless file.file? && !file.symlink? && file.nlink == 1 && file.uid == Process.uid &&
               file.size == artifact.fetch("size") &&
               Digest::SHA256.file(path).hexdigest == artifact.fetch("sha256")
          raise Error, "#{entry.id} offline gem cache artifact mismatch"
        end
      end
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{entry.id} offline gem cache is missing or unsafe"
    end

    def parse_row(value, index)
      row = string_hash(value, "baseline row #{index}")
      exact_keys!(row, ROW_KEYS, "baseline row #{index}")
      id = required_string(row, "id", "baseline row #{index}")
      raise Error, "invalid baseline id #{id.inspect}" unless SAFE_ID.match?(id)
      version = required_string(row, "version", id)
      tag = required_string(row, "tag", id)
      raise Error, "#{id} tag must be v<version>" unless SAFE_TAG.match?(tag) && tag == "v#{version}"
      reviewed_on = row["reviewed_on"].to_s
      Date.iso8601(reviewed_on)
      platforms = row["required_platforms"]
      unless platforms.is_a?(Array) && !platforms.empty? && platforms.uniq == platforms &&
             (platforms - PLATFORMS).empty?
        raise Error, "#{id} required_platforms are invalid"
      end
      oracles = string_hash(row["oracles"], "#{id} oracles")
      exact_keys!(oracles, ORACLE_KEYS, "#{id} oracles")
      ORACLE_KEYS.each { |key| required_string(oracles, key, "#{id} oracles") }
      packages = parse_packages(row["packages"], id)
      closure = parse_closure(row["dependency_closure"], id, observer: packages.key?("observer"))

      Entry.new(
        id: id, version: version, tag: tag,
        owner: required_string(row, "owner", id),
        reviewed_on: reviewed_on,
        rationale: required_string(row, "rationale", id),
        incident: required_string(row, "incident", id),
        retirement: required_string(row, "retirement", id),
        required_platforms: platforms.freeze,
        oracles: oracles.freeze,
        packages: packages.freeze,
        dependency_closure: closure.freeze
      )
    rescue Date::Error
      raise Error, "#{id || "baseline row #{index}"} reviewed_on must be an ISO date"
    end

    def parse_packages(value, id)
      packages = string_hash(value, "#{id} packages")
      roles = packages.keys
      unless roles.include?("producer") && (roles - %w[observer producer]).empty? &&
             (id != "legacy-bench-v041" || roles.include?("observer"))
        raise Error, "#{id} packages must contain a producer and only reviewed roles"
      end
      packages.to_h do |role, package_value|
        package = string_hash(package_value, "#{id} #{role}")
        exact_keys!(package, PACKAGE_KEYS, "#{id} #{role}")
        version = required_string(package, "version", "#{id} #{role}")
        tag = required_string(package, "tag", "#{id} #{role}")
        raise Error, "#{id} #{role} tag/version mismatch" unless tag == "v#{version}"
        [
          role,
          package.merge(
            "artifact" => parse_artifact(package["artifact"], tag, "#{id} #{role}"),
            "authentication" => parse_auth(package["authentication"], tag, "#{id} #{role}")
          ).freeze
        ]
      end
    end

    def parse_artifact(value, tag, context)
      artifact = string_hash(value, "#{context} artifact")
      exact_keys!(artifact, ARTIFACT_KEYS, "#{context} artifact")
      filename = safe_filename!(required_string(artifact, "filename", context))
      expected_url = release_url(tag, filename)
      raise Error, "#{context} artifact URL must be canonical HTTPS release URL" unless artifact["url"] == expected_url
      unless artifact["size"].is_a?(Integer) && artifact["size"].positive?
        raise Error, "#{context} artifact size must be a positive integer"
      end
      raise Error, "#{context} artifact sha256 is invalid" unless SHA256.match?(artifact["sha256"].to_s)
      artifact.merge("repository" => REPOSITORY, "tag" => tag).freeze
    end

    def parse_auth(value, tag, context)
      auth = string_hash(value, "#{context} authentication")
      exact_keys!(auth, AUTH_KEYS, "#{context} authentication")
      %w[checksum signature certificate].each do |kind|
        descriptor = string_hash(auth[kind], "#{context} #{kind}")
        exact_keys!(descriptor, AUTH_ASSET_KEYS, "#{context} #{kind}")
        filename = safe_filename!(required_string(descriptor, "filename", "#{context} #{kind}"))
        unless descriptor["url"] == release_url(tag, filename)
          raise Error, "#{context} #{kind} URL must be canonical HTTPS release URL"
        end
        unless descriptor["size"].is_a?(Integer) && descriptor["size"].positive? &&
               SHA256.match?(descriptor["sha256"].to_s)
          raise Error, "#{context} #{kind} size/digest identity is invalid"
        end
        auth[kind] = descriptor.merge("repository" => REPOSITORY, "tag" => tag).freeze
      end
      required_string(auth, "issuer", "#{context} authentication")
      identity = required_string(auth, "identity", "#{context} authentication")
      unless identity.end_with?("@refs/tags/#{tag}") &&
             identity.start_with?("https://github.com/#{REPOSITORY}/.github/workflows/release.yml@")
        raise Error, "#{context} signing identity is invalid"
      end
      auth.freeze
    end

    def parse_closure(value, id, observer:)
      closure = string_hash(value, "#{id} dependency_closure")
      expected = observer ? CLOSURE_KEYS : CLOSURE_KEYS - [ "observer_lock" ]
      exact_keys!(closure, expected, "#{id} dependency_closure")
      raise Error, "#{id} dependency closure schema is invalid" unless closure["schema_version"] == 1
      raise Error, "#{id} dependency closure Ruby must be 3.4" unless closure["ruby"] == "3.4"
      closure["lock"] = parse_lock(closure["lock"], "#{id} lock")
      closure["observer_lock"] = parse_lock(closure["observer_lock"], "#{id} observer lock") if observer
      cache = string_hash(closure["offline_cache"], "#{id} offline_cache")
      exact_keys!(cache, CACHE_KEYS, "#{id} offline_cache")
      filename = safe_filename!(
        required_string(cache, "manifest_filename", "#{id} offline_cache")
      )
      manifest_path = required_string(cache, "manifest_path", "#{id} offline_cache")
      unless safe_repo_path?(manifest_path) &&
             manifest_path.start_with?("packaging/release_candidate/baseline_manifests/") &&
             File.basename(manifest_path) == filename
        raise Error, "#{id} offline cache manifest path is invalid"
      end
      unless SHA256.match?(cache["manifest_sha256"].to_s)
        raise Error, "#{id} offline cache manifest digest is invalid"
      end
      unless cache["completeness"] == "exact-locked-runtime-transitive-closure" &&
             cache["network"] == "forbidden" &&
             cache["required_artifact_fields"] == %w[filename size sha256]
        raise Error, "#{id} offline cache must be a complete digested no-network closure"
      end
      closure["offline_cache"] = cache.freeze
      closure
    end

    def parse_lock(value, context)
      lock = string_hash(value, context)
      exact_keys!(lock, LOCK_KEYS, context)
      raise Error, "#{context} path must be Gemfile.lock" unless lock["path"] == "Gemfile.lock"
      tag = required_string(lock, "source_tag", context)
      raise Error, "#{context} source tag is invalid" unless SAFE_TAG.match?(tag)
      raise Error, "#{context} sha256 is invalid" unless SHA256.match?(lock["sha256"].to_s)
      lock.freeze
    end

    def release_url(tag, filename)
      "https://github.com/#{REPOSITORY}/releases/download/#{tag}/#{filename}"
    end

    def safe_filename!(value)
      unless value == File.basename(value) && !%w[. ..].include?(value) && !value.include?("\\")
        raise Error, "unsafe baseline asset filename #{value.inspect}"
      end
      value
    end

    def safe_repo_path?(value)
      return false unless value.is_a?(String) && !value.empty? && !value.include?("\\")

      path = Pathname.new(value)
      !path.absolute? && path.cleanpath.to_s == value &&
        value != ".." && !value.start_with?("../")
    end

    def string_hash(value, context)
      raise Error, "#{context} must be a mapping" unless value.is_a?(Hash)
      unless value.keys.all? { |key| key.is_a?(String) }
        raise Error, "#{context} keys must be strings"
      end
      value
    end

    def exact_keys!(value, expected, context)
      missing = expected - value.keys
      extra = value.keys - expected
      return if missing.empty? && extra.empty?

      raise Error, "#{context} keys are invalid (missing: #{missing.join(', ')}; extra: #{extra.join(', ')})"
    end

    def required_string(value, key, context)
      result = value[key]
      raise Error, "#{context} #{key} must be non-empty" unless result.is_a?(String) && !result.strip.empty?
      result
    end
  end
end
