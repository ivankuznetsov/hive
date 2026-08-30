require "digest"
require "fileutils"
require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Digest-authenticated, immutable phase checkpoint.
    class CutoverManifest
      SCHEMA = "hive-runtime-cutover-manifest".freeze
      ENVELOPE_SCHEMA = "hive-runtime-cutover-envelope".freeze
      VERSION = 1
      PHASES = %w[ready intended active].freeze
      MAX_BYTES = 16 * 1024 * 1024
      class Error < RuntimeControlPlane::Error; end
      class PublicationError < Error; end
      class IntegrityError < Error; end

      attr_reader :path

      def self.build(phase:, installation_id:, lineage_id:, source_release:, target_release:,
                     exclusions:, task_authority:, evidence: {}, created_at: Time.now.utc)
        validate!({
          "schema" => SCHEMA, "schema_version" => VERSION, "phase" => phase.to_s,
          "created_at" => Codec.dump_time(created_at), "installation_id" => installation_id,
          "lineage_id" => lineage_id, "source_release" => source_release,
          "target_release" => target_release, "exclusions" => exclusions,
          "task_authority" => task_authority, "evidence" => evidence
        }, Error)
      end

      def self.validate!(value, error_class = IntegrityError)
        document = Codec.normalize(value)
        valid = document.keys.sort == %w[
          created_at evidence exclusions installation_id lineage_id phase schema
          schema_version source_release target_release task_authority
        ] && document["schema"] == SCHEMA && document["schema_version"] == VERSION &&
          PHASES.include?(document["phase"]) && document["evidence"].is_a?(Hash) &&
          %w[exclusions task_authority].all? { |key| document[key].is_a?(Array) } &&
          %w[installation_id lineage_id source_release target_release].all? do |key|
            document[key].is_a?(String) && document[key].bytesize.between?(1, 512)
          end
        Codec.load_time(document.fetch("created_at"))
        raise error_class.new("cutover manifest is invalid", code: :manifest_invalid) unless valid
        document.freeze
      rescue CodecError, KeyError, TypeError
        raise error_class.new("cutover manifest is invalid", code: :manifest_invalid)
      end

      def initialize(path:, before_publish: nil)
        @path = File.expand_path(path)
        @before_publish = before_publish
      end

      def publish(value)
        document = self.class.validate!(value)
        envelope = { "schema" => ENVELOPE_SCHEMA, "schema_version" => VERSION,
                     "sha256" => Digest::SHA256.hexdigest(Codec.dump_json(document)),
                     "document" => document }
        parent = File.dirname(path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        fail!(:unsafe_parent, publication: true) unless File.directory?(parent) && !File.symlink?(parent)
        fail!(:already_published, publication: true) if File.exist?(path) || File.symlink?(path)
        temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
        Hive::AtomicFile.write(temporary, "#{Codec.dump_json(envelope)}\n", mode: 0o600)
        @before_publish&.call(temporary)
        File.link(temporary, path)
        Hive::AtomicFile.fsync_directory(parent)
        Codec.normalize(envelope).freeze
      rescue Errno::EEXIST
        fail!(:already_published, publication: true)
      rescue PublicationError
        raise
      rescue SystemCallError, IOError => error
        raise PublicationError.new("cutover manifest publication failed: #{error.message}",
                                   code: :publication_failed)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def load
        flags = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
        File.open(path, flags) do |file|
          stat = file.stat
          fail!(:manifest_unsafe) unless stat.file? && stat.nlink == 1 && stat.uid == Process.euid &&
            (stat.mode & 0o077).zero? && stat.size <= MAX_BYTES
          parsed = JSON.parse(file.read)
          fail!(:manifest_unsafe) unless stat == file.stat
          valid = parsed.is_a?(Hash) && parsed.keys.sort == %w[document schema schema_version sha256] &&
            parsed["schema"] == ENVELOPE_SCHEMA && parsed["schema_version"] == VERSION
          fail!(:manifest_corrupt) unless valid
          document = self.class.validate!(parsed.fetch("document"))
          fail!(:manifest_corrupt) unless parsed["sha256"] == Digest::SHA256.hexdigest(Codec.dump_json(document))
          Codec.normalize(parsed).freeze
        end
      rescue Errno::ENOENT
        fail!(:manifest_missing)
      rescue Errno::ELOOP
        fail!(:manifest_unsafe)
      rescue JSON::ParserError, KeyError, CodecError
        fail!(:manifest_corrupt)
      end

      private

      def fail!(code, publication: false)
        klass = publication ? PublicationError : IntegrityError
        raise klass.new("cutover manifest #{code.to_s.tr('_', ' ')}", code: code)
      end
    end
  end
end
