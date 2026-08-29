require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "hive/atomic_file"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Durable authority outside both legacy roots and the candidate database.
    # A published manifest is immutable; phase progress uses a new manifest.
    class CutoverManifest
      SCHEMA = "hive-runtime-cutover-manifest".freeze
      SCHEMA_VERSION = 1
      ENVELOPE_SCHEMA = "hive-runtime-cutover-envelope".freeze
      PHASES = %w[preparing ready intended active].freeze
      MAX_FILE_BYTES = 512 * 1024 * 1024

      class Error < RuntimeControlPlane::Error; end
      class InventoryError < Error; end
      class PublicationError < Error; end
      class IntegrityError < Error; end

      attr_reader :path

      def self.build(phase:, installation_id:, lineage_id:, source_release:, target_release:,
                     roots:, required_absences:, exclusions:, task_authority:, payloads:,
                     created_at: Time.now.utc)
        unless PHASES.include?(phase.to_s)
          raise InventoryError.new("cutover phase is invalid", code: :invalid_phase)
        end
        document = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "phase" => phase.to_s,
          "created_at" => Codec.dump_time(created_at),
          "installation_id" => required_string(installation_id, "installation identity"),
          "lineage_id" => required_string(lineage_id, "lineage identity"),
          "source_release" => required_string(source_release, "source release"),
          "target_release" => required_string(target_release, "target release"),
          "inventory" => inventory(roots),
          "required_absences" => normalize_absences(required_absences),
          "exclusions" => normalize_objects(exclusions, "exclusions"),
          "task_authority" => normalize_objects(task_authority, "task authority"),
          "payloads" => normalize_objects(payloads, "payloads")
        }
        Codec.normalize(document).freeze
      end

      def self.inventory(roots)
        unless roots.is_a?(Hash) && !roots.empty?
          raise InventoryError.new("cutover inventory requires named roots", code: :roots_missing)
        end
        entries = roots.sort_by { |label, _path| label.to_s }.flat_map do |label, raw_root|
          root = File.expand_path(raw_root)
          inventory_root(label.to_s, root)
        end
        entries.sort_by { |entry| [ entry.fetch("root"), entry.fetch("relative_path") ] }.freeze
      end

      def self.inventory_root(label, root)
        status = File.lstat(root)
        reject_entry!(root, :symlink, "inventory root is a symlink") if status.symlink?
        reject_entry!(root, :not_directory, "inventory root is not a directory") unless status.directory?
        entries = [ directory_entry(label, root, ".", status) ]
        pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
        until pending.empty?
          path = pending.pop
          status = File.lstat(path)
          relative = path.delete_prefix(root + File::SEPARATOR)
          reject_entry!(path, :symlink, "inventory contains a symlink") if status.symlink?
          if status.directory?
            entries << directory_entry(label, root, relative, status)
            Dir.children(path).sort.reverse_each { |name| pending << File.join(path, name) }
          elsif status.file?
            reject_entry!(path, :hardlink, "inventory contains a hard-linked file") unless status.nlink == 1
            entries << file_entry(label, root, relative, path, status)
          else
            reject_entry!(path, :unsupported_type, "inventory contains an unsupported entry type")
          end
        end
        entries
      rescue Errno::ENOENT
        raise InventoryError.new(
          "inventory source changed or is missing at #{root}", code: :source_changed,
          details: { path: root }
        )
      end

      def self.directory_entry(label, root, relative, status)
        {
          "root" => required_string(label, "root label"),
          "root_path" => root,
          "relative_path" => relative,
          "type" => "directory",
          "mode" => format("%04o", status.mode & 0o7777),
          "uid" => status.uid
        }
      end

      def self.file_entry(label, root, relative, path, before)
        if before.size > MAX_FILE_BYTES
          reject_entry!(path, :file_too_large, "inventory file exceeds #{MAX_FILE_BYTES} bytes")
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        digest = Digest::SHA256.new
        File.open(path, flags) do |file|
          opened = file.stat
          unless opened.dev == before.dev && opened.ino == before.ino
            reject_entry!(path, :source_changed, "inventory file changed before it was opened")
          end
          while (chunk = file.read(64 * 1024))
            digest.update(chunk)
          end
          after = file.stat
          after_path = File.lstat(path)
          unless snapshot(before) == snapshot(after) && snapshot(before) == snapshot(after_path)
            reject_entry!(path, :source_changed, "inventory file changed while being hashed")
          end
        end
        {
          "root" => required_string(label, "root label"),
          "root_path" => root,
          "relative_path" => relative,
          "type" => "file",
          "mode" => format("%04o", before.mode & 0o7777),
          "uid" => before.uid,
          "size" => before.size,
          "sha256" => digest.hexdigest
        }
      rescue Errno::ELOOP
        reject_entry!(path, :symlink, "inventory file became a symlink")
      end

      def self.snapshot(status)
        [ status.dev, status.ino, status.size, status.mtime, status.ctime, status.nlink ]
      end

      def self.reject_entry!(path, code, message)
        raise InventoryError.new("#{message}: #{path}", code: code, details: { path: path })
      end

      def self.required_string(value, label)
        string = value.to_s.strip
        if string.empty? || string.bytesize > 512
          raise InventoryError.new("#{label} is invalid", code: :invalid_manifest_value)
        end
        string
      end

      def self.normalize_absences(values)
        Array(values).map do |value|
          path = value.to_s
          if path.empty? || path.start_with?(File::SEPARATOR) || path.split(File::SEPARATOR).include?("..")
            raise InventoryError.new("required absence is not relative", code: :invalid_required_absence)
          end
          path
        end.uniq.sort.freeze
      end

      def self.normalize_objects(values, label)
        Array(values).map do |value|
          unless value.is_a?(Hash)
            raise InventoryError.new("#{label} entries must be objects", code: :invalid_manifest_value)
          end
          Codec.normalize(value).freeze
        end.sort_by { |value| Codec.dump_json(value) }.freeze
      end

      def initialize(path:, before_publish: nil)
        @path = File.expand_path(path)
        @before_publish = before_publish
      end

      def publish(document)
        normalized = validate_document!(document)
        bytes = Codec.dump_json(normalized)
        envelope = {
          "schema" => ENVELOPE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "sha256" => Digest::SHA256.hexdigest(bytes),
          "document" => normalized
        }
        publish_bytes("#{Codec.dump_json(envelope)}\n")
        Codec.normalize(envelope).freeze
      end

      def load
        status = File.lstat(path)
        integrity!("cutover manifest is not a regular owner-private file", :manifest_unsafe) if
          status.symlink? || !status.file? || status.nlink != 1 || status.uid != Process.euid ||
          (status.mode & 0o077) != 0
        parsed = JSON.parse(read_stable(status))
        envelope_keys = %w[document schema schema_version sha256]
        unless parsed.is_a?(Hash) && parsed.keys.sort == envelope_keys &&
               parsed["schema"] == ENVELOPE_SCHEMA &&
               parsed["schema_version"] == SCHEMA_VERSION && parsed["document"].is_a?(Hash) &&
               parsed["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          integrity!("cutover manifest envelope is invalid", :manifest_corrupt)
        end
        normalized = validate_document!(parsed.fetch("document"))
        digest = Digest::SHA256.hexdigest(Codec.dump_json(normalized))
        integrity!("cutover manifest digest does not match", :manifest_corrupt) unless
          parsed["sha256"] == digest
        Codec.normalize(parsed).freeze
      rescue Errno::ENOENT
        integrity!("cutover manifest is missing", :manifest_missing)
      rescue JSON::ParserError, KeyError, CodecError
        integrity!("cutover manifest is corrupt", :manifest_corrupt)
      end

      private

      def publish_bytes(bytes)
        parent = File.dirname(path)
        prepare_parent!(parent)
        if File.exist?(path) || File.symlink?(path)
          raise PublicationError.new("cutover manifest is already published", code: :already_published)
        end
        temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        @before_publish&.call(temporary)
        begin
          File.link(temporary, path)
        rescue Errno::EEXIST
          raise PublicationError.new("cutover manifest is already published", code: :already_published)
        end
        File.unlink(temporary)
        temporary = nil
        Hive::AtomicFile.fsync_directory(parent)
        path
      rescue PublicationError
        raise
      rescue SystemCallError, IOError => error
        raise PublicationError.new(
          "cutover manifest publication failed: #{error.message}",
          code: :publication_failed, details: { error_class: error.class.name }
        )
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def prepare_parent!(parent)
        FileUtils.mkdir_p(parent, mode: 0o700)
        status = File.lstat(parent)
        if status.symlink? || !status.directory? || status.uid != Process.euid
          raise PublicationError.new("cutover manifest parent is unsafe", code: :unsafe_parent)
        end
        File.chmod(0o700, parent)
      end

      def validate_document!(document)
        normalized = Codec.normalize(document)
        required = %w[
          schema schema_version phase created_at installation_id lineage_id
          source_release target_release inventory required_absences exclusions
          task_authority payloads
        ]
        unless normalized.keys.sort == required.sort && normalized["schema"] == SCHEMA &&
               normalized["schema_version"] == SCHEMA_VERSION && PHASES.include?(normalized["phase"])
          integrity!("cutover manifest document is invalid", :manifest_invalid)
        end
        Codec.load_time(normalized.fetch("created_at"))
        %w[inventory required_absences exclusions task_authority payloads].each do |key|
          integrity!("cutover manifest #{key} must be an array", :manifest_invalid) unless
            normalized[key].is_a?(Array)
        end
        validate_inventory!(normalized.fetch("inventory"))
        self.class.normalize_absences(normalized.fetch("required_absences"))
        %w[installation_id lineage_id source_release target_release].each do |key|
          self.class.required_string(normalized.fetch(key), key.tr("_", " "))
        end
        normalized.freeze
      rescue CodecError, KeyError, TypeError
        integrity!("cutover manifest document is invalid", :manifest_invalid)
      end

      def integrity!(message, code)
        raise IntegrityError.new(message, code: code)
      end

      def validate_inventory!(entries)
        integrity!("cutover manifest inventory is empty", :manifest_invalid) if entries.empty?
        identities = entries.map do |entry|
          integrity!("cutover manifest inventory entry is invalid", :manifest_invalid) unless
            entry.is_a?(Hash)
          type = entry["type"]
          required = %w[mode relative_path root root_path type uid]
          required += %w[sha256 size] if type == "file"
          unless entry.keys.sort == required.sort && %w[directory file].include?(type) &&
                 entry["mode"].to_s.match?(/\A[0-7]{4}\z/) && entry["uid"].is_a?(Integer) &&
                 entry["root_path"].to_s.start_with?(File::SEPARATOR)
            integrity!("cutover manifest inventory entry is invalid", :manifest_invalid)
          end
          relative = entry["relative_path"].to_s
          if relative.empty? || relative.start_with?(File::SEPARATOR) ||
             relative.split(File::SEPARATOR).include?("..")
            integrity!("cutover manifest inventory path is invalid", :manifest_invalid)
          end
          if type == "file" &&
             (!entry["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) ||
              !entry["size"].is_a?(Integer) || entry["size"].negative?)
            integrity!("cutover manifest file inventory is invalid", :manifest_invalid)
          end
          [ entry["root"], relative ]
        end
        integrity!("cutover manifest inventory contains duplicate paths", :manifest_invalid) unless
          identities.uniq.length == identities.length
      end

      def read_stable(path_status)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          before = file.stat
          integrity!("cutover manifest changed before it was opened", :manifest_unsafe) unless
            before.dev == path_status.dev && before.ino == path_status.ino
          integrity!("cutover manifest is too large", :manifest_corrupt) if before.size > 16 * 1024 * 1024
          bytes = file.read
          after = file.stat
          after_path = File.lstat(path)
          integrity!("cutover manifest changed while it was read", :manifest_unsafe) unless
            self.class.snapshot(before) == self.class.snapshot(after) &&
            self.class.snapshot(before) == self.class.snapshot(after_path)
          bytes
        end
      rescue Errno::ELOOP
        integrity!("cutover manifest became a symlink", :manifest_unsafe)
      end
    end
  end
end
