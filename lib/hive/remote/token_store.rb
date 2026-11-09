# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "hive/remote/registry_lock"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/paths"
require "hive/remote/authorization"

module Hive
  module Remote
    class TokenStore
      SCHEMA_VERSION = 1
      BEARER = /\A([0-9a-f]{24})\.([0-9a-f]{64})\z/

      attr_reader :path

      def initialize(root: File.join(Hive::Paths.state_home, "remote-access"),
                     projects: Hive::Config.method(:registered_projects),
                     owner: TokenStore.method(:configured_owner),
                     clock: -> { Time.now.utc })
        @root = root
        @path = File.join(root, "tokens.json")
        @projects = projects
        @owner = owner
        @clock = clock
      end

      def create(name:, scopes:, projects: [], all_projects: false, expires_at: nil)
        if @owner.call.to_s.strip.empty?
          raise Hive::ConfigError, "configure a non-blank web.github.owner before creating API tokens"
        end
        validate_name!(name)
        scopes = Array(scopes).uniq
        unless scopes.all? { |scope| Authorization::SCOPES.include?(scope) }
          raise Hive::UsageError, "scopes must be read, create, act, or answer"
        end
        names = Array(projects).uniq
        if (all_projects && !names.empty?) || (!all_projects && names.empty?)
          raise Hive::UsageError, "supply named projects or explicit --all-projects"
        end
        grants = names.map { |name| project_grant!(name) }
        expiry = normalize_expiry(expires_at)
        public_id = SecureRandom.hex(12)
        secret = SecureRandom.hex(32)
        row = {
          "id" => public_id, "name" => name, "secret_sha256" => Digest::SHA256.hexdigest(secret),
          "scopes" => scopes, "projects" => grants, "all_projects" => all_projects == true,
          "expires_at" => expiry, "revoked" => false, "created_at" => @clock.call.utc.iso8601
        }
        update do |data|
          data.fetch("tokens") << row
        end
        public_record(row).merge("token" => "#{public_id}.#{secret}")
      end

      def self.configured_owner
        Hive::Config.load_global_web.dig("github", "owner")
      rescue Hive::ConfigError => error
        raise unless error.message.start_with?("web.github.owner in ")
        raise Hive::ConfigError, "configure a non-blank web.github.owner before creating API tokens"
      end

      def list
        with_lock(File::LOCK_SH) { read.fetch("tokens").map { |row| public_record(row) } }
      end

      def revoke(id)
        result = nil
        update do |data|
          row = data.fetch("tokens").find { |entry| entry.fetch("id") == id }
          raise Hive::UsageError, "unknown token public ID" unless row

          row["revoked"] = true
          result = public_record(row)
        end
        result
      end

      def authenticate(bearer)
        match = BEARER.match(bearer.to_s)
        return unless match

        row = with_lock(File::LOCK_SH) do
          read.fetch("tokens").find { |entry| entry.fetch("id") == match[1] }
        end
        return unless row && !row.fetch("revoked")
        return if row["expires_at"] && Time.iso8601(row.fetch("expires_at")) <= @clock.call
        expected = row.fetch("secret_sha256")
        actual = Digest::SHA256.hexdigest(match[2])
        return unless expected.bytesize == actual.bytesize &&
          expected.bytes.zip(actual.bytes).reduce(0) { |difference, (left, right)| difference | (left ^ right) }.zero?

        public_record(row)
      end

      private

      def validate_name!(name)
        unless name.is_a?(String) && name.bytesize.between?(1, 128) &&
               (name.encoding == Encoding::UTF_8 || name.ascii_only?) && name.valid_encoding? &&
               !name.match?(/[[:cntrl:]]/) && !name.strip.empty?
          raise Hive::UsageError, "token name must be 1 to 128 printable bytes"
        end
      end

      def normalize_expiry(value)
        return nil if value.nil?

        time = Time.iso8601(value.to_s)
        raise ArgumentError unless time > @clock.call

        time.utc.iso8601(6)
      rescue ArgumentError
        raise Hive::UsageError, "expiry must be a future ISO 8601 timestamp"
      end

      def project_grant!(name)
        matches = @projects.call.select { |project| project["name"] == name }
        fingerprint = Authorization.fingerprint(matches.first) if matches.length == 1
        unless fingerprint
          raise Hive::UsageError, "project grants require exact, registered project names with current identity"
        end
        { "name" => name, "fingerprint" => fingerprint }
      end

      def public_record(row)
        row.reject { |key, _| key == "secret_sha256" }
      end

      def with_lock(mode)
        FileUtils.mkdir_p(@root, mode: 0o700)
        stat = File.lstat(@root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::ConfigError, "API token directory must belong to the current operator"
        end
        File.chmod(0o700, @root)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(File.join(@root, ".tokens.lock"), flags, 0o600) do |lock|
          Hive::Remote::RegistryLock.acquire!(lock, mode)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise Hive::ConfigError, "API token registry cannot use a symlink"
      end

      def read
        return { "schema_version" => SCHEMA_VERSION, "tokens" => [] } unless File.exist?(path)

        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise Hive::ConfigError, "API token registry must be an owner-only regular file"
        end
        data = JSON.parse(File.read(path))
        if data.is_a?(Hash) && data["schema_version"].is_a?(Integer) && data["schema_version"] > SCHEMA_VERSION
          raise Hive::ConfigError, "API token registry is newer; upgrade Hive before using it"
        end
        unless valid_registry?(data)
          raise Hive::ConfigError, "invalid API token registry; restore the operator's registry"
        end
        data
      rescue JSON::ParserError
        raise Hive::ConfigError, "invalid API token registry; restore the operator's registry"
      end

      def valid_registry?(data)
        return false unless data.is_a?(Hash) && data["schema_version"] == SCHEMA_VERSION && data["tokens"].is_a?(Array)

        ids = []
        data.fetch("tokens").all? do |row|
          next false unless row.is_a?(Hash) && row["id"].to_s.match?(/\A[0-9a-f]{24}\z/) &&
            row["secret_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && row["name"].is_a?(String) &&
            row["scopes"].is_a?(Array) && (row["scopes"] - Authorization::SCOPES).empty? &&
            [ true, false ].include?(row["all_projects"]) && [ true, false ].include?(row["revoked"]) &&
            row["projects"].is_a?(Array) && row["projects"].all? { |grant|
              grant.is_a?(Hash) && grant["name"].is_a?(String) && grant["fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/)
            }
          next false if ids.include?(row["id"])
          ids << row["id"]
          Time.iso8601(row.fetch("created_at"))
          Time.iso8601(row["expires_at"]) if row["expires_at"]
          true
        end
      rescue ArgumentError, KeyError, TypeError
        false
      end

      def update
        with_lock(File::LOCK_EX) do
          data = read
          yield data
          Hive::AtomicFile.write(path, JSON.generate(data), mode: 0o600)
          Hive::AtomicFile.fsync_directory(@root)
        end
      end
    end
  end
end
