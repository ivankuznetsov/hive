# frozen_string_literal: true

require "json"
require "hive/atomic_file"
require "hive/brainstorm_suggestions"

module Hive
  module BrainstormSuggestions
    # Owner-private canonical runtime store. The document contains validated
    # lifecycle state only; context bundles and provider output never enter it.
    class Store
      FILENAME = STORE_FILENAME
      DOCUMENT_KEYS = %w[
        schema schema_version task_incarnation task_generation
        brainstorm_generation recipe_version records updated_at
      ].freeze
      RECORD_KEYS = %w[
        question_id ordinal round question_number question_fingerprint
        input_binding suggestion_binding state text rationale provenance
        safe_reason retryable dismissed attempt_id candidate_id requested_at
        updated_at next_retry_at automatic_attempts input_epoch error_code
        total_automatic_attempts
      ].freeze
      REQUIRED_RECORD_KEYS = %w[
        question_id ordinal input_binding state text rationale provenance
        safe_reason retryable dismissed
      ].freeze
      DIGEST_RE = /\A[0-9a-f]{64}\z/

      attr_reader :root, :path

      def initialize(task_root)
        @root = File.expand_path(task_root)
        @path = File.join(@root, FILENAME)
      end

      def read
        return empty_document unless File.exist?(path) || File.symlink?(path)

        status = File.lstat(path)
        return corrupt_document unless self.class.owned_private_file?(status)
        return corrupt_document if status.size > MAX_STORE_BYTES

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        raw = File.open(path, flags) { |file| file.read(MAX_STORE_BYTES + 1) }
        return corrupt_document if raw.bytesize > MAX_STORE_BYTES

        validate_document(JSON.parse(raw))
      rescue JSON::ParserError, SystemCallError, IOError, InvalidState
        corrupt_document
      end

      def write(attributes)
        validate_root!
        document = normalize_document(attributes)
        validate_document(document)
        payload = "#{JSON.pretty_generate(document)}\n"
        raise InvalidState, "suggestion sidecar exceeds #{MAX_STORE_BYTES} bytes" if
          payload.bytesize > MAX_STORE_BYTES

        reject_unsafe_target!
        Hive::AtomicFile.write(path, payload, mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(root)
        document
      end

      def update
        document = read
        document = empty_document if document["corrupt"]
        updated = yield(deep_copy(document))
        return document if updated == document

        write(updated)
      end

      def delete_question!(ordinal: nil, question_id: nil)
        document = read
        return false if document["corrupt"] || document.fetch("records").empty?

        before = document.fetch("records").length
        document["records"] = document.fetch("records").reject do |record|
          (ordinal && record["ordinal"] == ordinal) ||
            (question_id && record["question_id"] == question_id)
        end
        return false if document.fetch("records").length == before

        document.fetch("records").empty? ? delete! : write(document)
        true
      end

      def delete!
        reject_unsafe_target!
        return false unless File.exist?(path)

        File.unlink(path)
        Hive::AtomicFile.fsync_directory(root)
        true
      rescue Errno::ENOENT
        false
      end

      private

      def empty_document
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "records" => []
        }
      end

      def corrupt_document
        empty_document.merge("corrupt" => true)
      end

      def normalize_document(attributes)
        input = stringify_keys(attributes)
        input.delete("corrupt")
        empty_document.merge(input)
      end

      def validate_document(document)
        raise InvalidState, "suggestion sidecar must be an object" unless document.is_a?(Hash)

        unknown = document.keys - DOCUMENT_KEYS
        raise InvalidState, "unknown suggestion sidecar fields: #{unknown.join(', ')}" unless unknown.empty?
        raise InvalidState, "invalid suggestion sidecar schema" unless
          document["schema"] == SCHEMA && document["schema_version"] == SCHEMA_VERSION
        raise InvalidState, "suggestion records must be an array" unless document["records"].is_a?(Array)

        document["records"].each { |record| validate_record(record) }
        document
      end

      def validate_record(record)
        raise InvalidState, "suggestion record must be an object" unless record.is_a?(Hash)

        unknown = record.keys - RECORD_KEYS
        missing = REQUIRED_RECORD_KEYS - record.keys
        raise InvalidState, "unknown suggestion record fields: #{unknown.join(', ')}" unless unknown.empty?
        raise InvalidState, "missing suggestion record fields: #{missing.join(', ')}" unless missing.empty?
        raise InvalidState, "invalid suggestion question id" if record["question_id"].to_s.empty?
        raise InvalidState, "invalid suggestion ordinal" unless record["ordinal"].is_a?(Integer) && record["ordinal"].positive?
        raise InvalidState, "invalid suggestion input binding" unless record["input_binding"].to_s.match?(DIGEST_RE)
        raise InvalidState, "invalid suggestion state" unless STATES.include?(record["state"])
        raise InvalidState, "invalid suggestion flags" unless
          [ true, false ].include?(record["retryable"]) && [ true, false ].include?(record["dismissed"])

        validate_state_payload(record)
      end

      def validate_state_payload(record)
        if record["state"] == "fresh"
          raise InvalidState, "fresh suggestion requires a binding" unless
            record["suggestion_binding"].to_s.match?(DIGEST_RE)
          validate_bounded_text(record.fetch("text"))
          validate_rationale(record.fetch("rationale"))
          provenance = record.fetch("provenance")
          raise InvalidState, "fresh suggestion requires admitted provenance" unless
            provenance.is_a?(Array) && !provenance.empty? &&
              provenance.uniq == provenance && (provenance - SOURCE_CLASSES).empty?
          raise InvalidState, "fresh suggestion cannot carry a safe reason" unless record["safe_reason"].nil?
        else
          raise InvalidState, "non-fresh suggestion cannot expose text" unless record["text"].nil?
          raise InvalidState, "non-fresh suggestion cannot expose rationale" unless record["rationale"].nil?
          raise InvalidState, "non-fresh suggestion cannot expose provenance" unless record["provenance"] == []
          validate_safe_reason(record["safe_reason"])
        end
      end

      def validate_bounded_text(value)
        raise InvalidState, "suggestion text must be a string" unless value.is_a?(String)

        text = value
        raise InvalidState, "suggestion text must be valid UTF-8" unless text.valid_encoding?
        raise InvalidState, "suggestion text must not be empty" if text.strip.empty?
        raise InvalidState, "suggestion text exceeds character limit" if text.length > MAX_TEXT_CHARACTERS
        raise InvalidState, "suggestion text exceeds line limit" if text.lines.length > MAX_TEXT_LINES
        raise InvalidState, "suggestion text failed safety policy" unless Safety.safe_content?(text)
      end

      def validate_rationale(value)
        raise InvalidState, "suggestion rationale must be a string" unless value.is_a?(String)

        rationale = value
        raise InvalidState, "fresh suggestion requires a rationale" if rationale.strip.empty?
        raise InvalidState, "suggestion rationale exceeds limit" if rationale.length > MAX_RATIONALE_CHARACTERS
        raise InvalidState, "suggestion rationale failed safety policy" unless
          Safety.safe_rationale?(rationale)
      end

      def validate_safe_reason(value)
        return if value.nil?

        raise InvalidState, "safe reason must be a string" unless value.is_a?(String)

        reason = value
        raise InvalidState, "safe reason must not be empty" if reason.strip.empty?
        raise InvalidState, "safe reason exceeds limit" if reason.length > MAX_SAFE_REASON_CHARACTERS
      end

      def validate_root!
        status = File.lstat(root)
        raise UnsafePath, "suggestion task root must be an owned directory" unless
          status.directory? && !status.symlink? && status.uid == Process.uid
      rescue Errno::ENOENT
        raise UnsafePath, "suggestion task root does not exist"
      end

      def reject_unsafe_target!
        return unless File.exist?(path) || File.symlink?(path)

        status = File.lstat(path)
        raise UnsafePath, "suggestion sidecar must be an owned regular file" unless
          self.class.owned_private_file?(status)
      end

      def self.owned_private_file?(status)
        status.file? && !status.symlink? && status.uid == Process.uid && (status.mode & 0o077).zero?
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = stringify_keys(item) }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
