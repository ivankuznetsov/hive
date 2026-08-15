require "json"
require "pathname"
require "time"
require "hive/secret_patterns"
require "hive/task_workspace"

module Hive
  module ContextProvenance
    module ContextReceipt
      class InvalidReceipt < Hive::Error; end

      TOP_LEVEL_KEYS = %w[
        schema schema_version kind binding captured_at quality repository wiki
        selection diagnostics
      ].freeze
      BINDING_KEYS = %w[
        project task_slug task_id stage attempt_id task_generation ownership_generation
      ].freeze
      SELECTION_KEYS = %w[references queries rationale].freeze
      REFERENCE_KEYS = %w[path kind label].freeze
      QUERY_KEYS = %w[query result_labels].freeze
      MAX_REFERENCES = 20
      MAX_QUERIES = 20
      MAX_RATIONALE_BYTES = 4 * 1024
      MAX_TEXT_BYTES = 512
      STATES = %w[current partial missing unavailable conflicting].freeze
      WIKI_IDENTITY_KINDS = %w[
        git_tree managed_receipt bounded_digest missing unavailable
      ].freeze

      module_function

      def validate_agent!(value, task:, context:)
        receipt = stringify(value)
        exact_keys!(receipt, TOP_LEVEL_KEYS, "context receipt")
        unless receipt["schema"] == "hive-context-receipt" && receipt["schema_version"] == 1
          raise InvalidReceipt, "unsupported context receipt schema"
        end
        raise InvalidReceipt, "agent receipt kind is invalid" unless receipt["kind"] == "agent_selection"
        unless receipt["quality"] == "agent_asserted_used"
          raise InvalidReceipt, "agent receipt quality is invalid"
        end
        captured_at = receipt.fetch("captured_at")
        raise InvalidReceipt, "captured_at must be a string" unless captured_at.is_a?(String)
        Time.iso8601(captured_at)
        validate_binding!(receipt.fetch("binding"), task: task, context: context)
        receipt["repository"] = validate_repository(receipt["repository"])
        receipt["wiki"] = validate_wiki(receipt["wiki"])
        receipt["selection"] = validate_selection!(
          receipt.fetch("selection"), project_root: task.project_root
        )
        receipt["diagnostics"] = validate_diagnostics(receipt.fetch("diagnostics"))
        Hive::TaskWorkspace.safe_value!(receipt)
        receipt
      rescue KeyError, ArgumentError, TypeError => e
        raise InvalidReceipt, safe_message(e)
      end

      def validate_binding!(binding, task:, context:)
        binding = stringify(binding)
        exact_keys!(binding, BINDING_KEYS, "context receipt binding")
        expected = {
          "project" => task_project(task), "task_slug" => task.slug.to_s,
          "task_id" => task.id&.to_s, "stage" => context.intended_stage.to_s,
          "attempt_id" => context.attempt_id.to_s,
          "task_generation" => Integer(context.task_generation),
          "ownership_generation" => context.ownership_generation&.to_s
        }
        raise InvalidReceipt, "context receipt binding mismatch" unless binding == expected

        binding
      end

      def validate_selection!(selection, project_root:)
        selection = stringify(selection)
        exact_keys!(selection, SELECTION_KEYS, "context selection")
        references = typed_array(selection["references"], "selected references")
        queries = typed_array(selection["queries"], "context queries")
        raise InvalidReceipt, "too many selected references" if references.length > MAX_REFERENCES
        raise InvalidReceipt, "too many context queries" if queries.length > MAX_QUERIES

        normalized_references = references.map do |entry|
          row = stringify(entry)
          exact_keys!(row, REFERENCE_KEYS, "selected reference")
          path = validate_reference!(row.fetch("path"), project_root: project_root)
          kind = identifier(row.fetch("kind"), "selected reference kind")
          label = text(row.fetch("label"), "selected reference label")
          { "path" => path, "kind" => kind, "label" => label }
        end
        normalized_queries = queries.map do |entry|
          row = stringify(entry)
          exact_keys!(row, QUERY_KEYS, "context query")
          labels = typed_array(row["result_labels"], "context result labels")
          raise InvalidReceipt, "too many context result labels" if labels.length > MAX_REFERENCES
          {
            "query" => text(row.fetch("query"), "context query"),
            "result_labels" => labels.map { |label| text(label, "context result label") }
          }
        end
        rationale = text(
          selection.fetch("rationale"), "context rationale", max_bytes: MAX_RATIONALE_BYTES
        )
        {
          "references" => normalized_references,
          "queries" => normalized_queries,
          "rationale" => rationale
        }
      end

      def validate_reference!(value, project_root:)
        raise InvalidReceipt, "selected context reference must be a string" unless value.is_a?(String)

        reference = value.tr("\\", "/")
        path = Pathname.new(reference)
        if reference.empty? || reference.include?("\0") || path.absolute? ||
           path.each_filename.any? { |part| part == ".." } || Hive::SecretPatterns.match?(reference)
          raise InvalidReceipt, "selected context reference is unsafe"
        end
        root = File.realpath(File.expand_path(project_root))
        candidate = File.join(root, reference)
        before = File.lstat(candidate)
        raise InvalidReceipt, "selected context reference cannot be a symlink" if before.symlink?
        resolved = File.realpath(candidate)
        unless resolved.start_with?("#{root}#{File::SEPARATOR}") && before.file?
          raise InvalidReceipt, "selected context reference escapes the project"
        end
        after = File.stat(resolved)
        unless before.dev == after.dev && before.ino == after.ino
          raise InvalidReceipt, "selected context reference changed"
        end
        reference
      rescue SystemCallError
        raise InvalidReceipt, "selected context reference is unavailable"
      end

      def validate_repository(value)
        return nil if value.nil?
        row = stringify(value)
        allowed = %w[state head_oid branch repository observed_from diagnostics]
        exact_keys!(row, allowed, "repository context")
        {
          "state" => enum(row.fetch("state"), STATES, "repository state"),
          "head_oid" => oid(row["head_oid"], "repository head OID"),
          "branch" => optional_text(row["branch"], "repository branch", max_bytes: 255),
          "repository" => optional_text(
            row["repository"], "repository identity", max_bytes: 1_024
          ),
          "observed_from" => enum(
            row.fetch("observed_from"), %w[local_git], "repository observation source"
          ),
          "diagnostics" => validate_diagnostics(row.fetch("diagnostics"))
        }
      end

      def validate_wiki(value)
        return nil if value.nil?
        row = stringify(value)
        allowed = %w[state identity_kind identifier file_count byte_count truncated diagnostics]
        exact_keys!(row, allowed, "wiki context")
        {
          "state" => enum(row.fetch("state"), STATES, "wiki state"),
          "identity_kind" => enum(
            row.fetch("identity_kind"), WIKI_IDENTITY_KINDS, "wiki identity kind"
          ),
          "identifier" => optional_text(
            row["identifier"], "wiki identifier", max_bytes: 1_024
          ),
          "file_count" => optional_nonnegative_integer(row["file_count"], "wiki file count"),
          "byte_count" => optional_nonnegative_integer(row["byte_count"], "wiki byte count"),
          "truncated" => boolean(row.fetch("truncated"), "wiki truncation flag"),
          "diagnostics" => validate_diagnostics(row.fetch("diagnostics"))
        }
      end

      def validate_diagnostics(value)
        diagnostics = typed_array(value, "context diagnostics")
        raise InvalidReceipt, "too many context diagnostics" if diagnostics.length > 20

        diagnostics.map do |entry|
          row = stringify(entry)
          exact_keys!(row, %w[code detail], "context diagnostic")
          { "code" => identifier(row.fetch("code"), "diagnostic code"),
            "detail" => row["detail"].nil? ? nil : text(row["detail"], "diagnostic detail") }
        end
      end

      def task_project(task)
        value = task.respond_to?(:project_name) ? task.project_name : nil
        value = File.basename(task.project_root.to_s) if value.to_s.empty?
        value.to_s
      end

      def exact_keys!(hash, expected, label)
        raise InvalidReceipt, "#{label} must be an object" unless hash.is_a?(Hash)
        extra = hash.keys - expected
        missing = expected - hash.keys
        return if extra.empty? && missing.empty?

        raise InvalidReceipt, "#{label} keys are invalid"
      end

      def identifier(value, label)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/)
          raise InvalidReceipt, "#{label} is invalid"
        end
        Hive::SecretPatterns.redact(value)
      end

      def text(value, label, max_bytes: MAX_TEXT_BYTES)
        raise InvalidReceipt, "#{label} must be a string" unless value.is_a?(String)

        string = Hive::SecretPatterns.redact(value)
        raise InvalidReceipt, "#{label} is required" if string.empty?
        raise InvalidReceipt, "#{label} exceeds #{max_bytes} bytes" if string.bytesize > max_bytes
        if absolute_host_path?(string)
          raise InvalidReceipt, "#{label} contains an absolute host path"
        end

        string
      end

      def optional_text(value, label, max_bytes: MAX_TEXT_BYTES)
        return nil if value.nil?

        text(value, label, max_bytes: max_bytes)
      end

      def enum(value, allowed, label)
        raise InvalidReceipt, "#{label} is invalid" unless value.is_a?(String) && allowed.include?(value)

        value
      end

      def oid(value, label)
        return nil if value.nil?
        unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40,64}\z/)
          raise InvalidReceipt, "#{label} is invalid"
        end

        value
      end

      def optional_nonnegative_integer(value, label)
        return nil if value.nil?
        raise InvalidReceipt, "#{label} is invalid" unless value.is_a?(Integer) && value >= 0

        value
      end

      def boolean(value, label)
        raise InvalidReceipt, "#{label} is invalid" unless value == true || value == false

        value
      end

      def typed_array(value, label)
        raise InvalidReceipt, "#{label} must be an array" unless value.is_a?(Array)

        value
      end

      def stringify(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).to_h { |key, child| [ key, stringify(child) ] }
        when Array
          value.map { |child| stringify(child) }
        else
          value
        end
      end

      def absolute_host_path?(value)
        value.match?(%r{(?<![A-Za-z0-9./])/(?:[^\s/]+/)*[^\s/]+}) ||
          value.match?(%r{(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s]+}) ||
          value.match?(%r{(?<![A-Za-z0-9\\])\\\\[^\s\\/]+[\\/][^\s]+})
      end

      def safe_message(error)
        Hive::SecretPatterns.redact(error.message.to_s)[0, 512]
      end
    end
  end
end
