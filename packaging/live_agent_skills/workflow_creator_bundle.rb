# frozen_string_literal: true

require "digest"
require "json"
require_relative "workflow_creator"

module HiveLiveAgentProof
  class Error < StandardError; end unless const_defined?(:Error, false)

  class WorkflowCreatorBundle
    Result = Data.define(:primary, :bytes)
    private_constant :Result
    FILES = WorkflowCreator::Vocabulary.fetch("bundle_files")
    SUPPORT = %w[candidate_installation openclaw_installation execution_receipt].freeze
    MAX_DIRECTORY_ENTRIES = 16
    MAX_FILE_BYTES = 1_048_576
    READ_FLAGS = if defined?(File::NOFOLLOW) && defined?(File::NONBLOCK)
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    end

    class << self
      def source(directory:, manifest:, candidate_sha:)
        validate(directory:, manifest:, candidate_sha:, expected_primary: nil, private_source: true)
      end

      def retained(directory:, expected_primary:, manifest:, candidate_sha:)
        validate(directory:, manifest:, candidate_sha:, expected_primary:, private_source: false)
      end

      private

      def validate(directory:, manifest:, candidate_sha:, expected_primary:, private_source:)
        bytes, documents = read_bundle(directory, private_source)
        primary, bundle_records = validate_documents(documents, bytes, manifest, candidate_sha)
        unless private_source
          attested = WorkflowCreator.validate_primary!(
            row: expected_primary, manifest:, candidate_sha:, bundle_records:
          )
          unless primary.canonical_bytes == attested.canonical_bytes
            raise Error, "workflow-creator retained primary does not match the attestation"
          end
        end

        Result.new(primary: primary.value, bytes: bytes.transform_values { |content| content.b.freeze }.freeze).freeze
      rescue JSON::ParserError
        raise Error, "workflow-creator bundle JSON is invalid"
      rescue WorkflowCreator::Error, WorkflowCreator::Values::Error
        raise Error, "workflow-creator bundle contract is invalid"
      rescue KeyError, TypeError, ArgumentError
        raise Error, "workflow-creator bundle contract is invalid"
      rescue Errno::ELOOP
        raise Error, "workflow-creator bundle member is not a private regular file"
      rescue SystemCallError, IOError
        raise Error, "workflow-creator bundle cannot be read safely"
      end

      def read_bundle(directory, private_source)
        root = File.expand_path(directory)
        stat = File.lstat(root)
        valid = stat.directory? && stat.uid == Process.uid
        valid &&= (stat.mode & 0o077).zero? if private_source
        raise Error, "workflow-creator bundle root is not an owner-private directory" unless valid

        children = Dir.each_child(root).take(MAX_DIRECTORY_ENTRIES + 1)
        raise Error, "workflow-creator bundle inventory exceeds the limit" if children.length > MAX_DIRECTORY_ENTRIES
        admitted = private_source ? children.sort == FILES.sort : (FILES - children).empty?
        raise Error, "workflow-creator bundle inventory is invalid" unless admitted

        read_bundle_members(root, stat, private_source)
      end

      def read_bundle_members(root, stat, private_source)
        bytes = FILES.to_h { |name| [ name, read_member(root, name, private_source) ] }
        current = File.lstat(root)
        identity = [ stat.dev, stat.ino, stat.uid, stat.mode ]
        unless [ current.dev, current.ino, current.uid, current.mode ] == identity
          raise Error, "workflow-creator bundle root identity changed during validation"
        end
        [ bytes, parse_documents(bytes) ]
      end

      def parse_documents(bytes)
        bytes.to_h do |name, content|
          document = JSON.parse(content)
          canonical = WorkflowCreator::Values.capture(document).canonical_bytes
          raise Error, "workflow-creator bundle member is not canonical JSON" unless content == canonical
          [ name, document ]
        end
      end

      def validate_documents(documents, bytes, manifest, candidate_sha)
        installations = %w[candidate openclaw].map.with_index do |kind, index|
          WorkflowCreator.validate_installation!(
            document: documents.fetch(FILES.fetch(index + 1)), kind:, manifest:, candidate_sha:
          )
        end
        records = SUPPORT.each_with_index.map do |kind, index|
          content = bytes.fetch(FILES.fetch(index + 1))
          { "kind" => kind, "path" => FILES.fetch(index + 1),
            "sha256" => Digest::SHA256.hexdigest(content), "size" => content.bytesize }
        end
        primary = WorkflowCreator.validate_primary!(
          row: documents.fetch(FILES.fetch(0)), manifest:, candidate_sha:, bundle_records: records
        )
        validate_execution(documents, installations, records, primary, manifest, candidate_sha)
        [ primary, records ]
      end

      def validate_execution(documents, installations, records, primary, manifest, candidate_sha)
        WorkflowCreator.validate_execution!(
          receipt: documents.fetch(FILES.fetch(3)), row: primary.value, candidate_sha:, manifest:,
          installation_records: records.first(2), receipt_sha256: records.fetch(2).fetch("sha256"),
          candidate_installation: installations.fetch(0).value,
          openclaw_installation: installations.fetch(1).value
        )
      end

      def read_member(root, name, private_source)
        raise Error, "workflow-creator safe bundle file-open flags are unavailable" unless READ_FLAGS
        File.open(File.join(root, name), READ_FLAGS) do |file|
          stat = file.stat
          validate_member!(stat, private_source)
          content = file.read(MAX_FILE_BYTES + 1)
          if content.bytesize > MAX_FILE_BYTES
            raise Error, "workflow-creator bundle member exceeds the size limit"
          end
          current = file.stat
          identity = [ stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime ]
          unless [ current.dev, current.ino, current.size, current.mtime, current.ctime ] == identity
            raise Error, "workflow-creator bundle member identity changed during validation"
          end
          content
        end
      end

      def validate_member!(stat, private_source)
        valid = stat.file? && stat.nlink == 1 && stat.uid == Process.uid
        valid &&= (stat.mode & 0o077).zero? if private_source
        raise Error, "workflow-creator bundle member is not a private regular file" unless valid
        if stat.size > MAX_FILE_BYTES
          raise Error, "workflow-creator bundle member exceeds the size limit"
        end
      end
    end
  end
end
