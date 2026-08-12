require "json"
require "pathname"
require "hive/secret_patterns"
require "hive/task_workspace/source_error"

module Hive
  module TaskWorkspace
    # Descriptor-backed suffix reader for task-local observational ledgers.
    # It returns only complete JSON objects, bounds both bytes and records, and
    # reports torn or malformed evidence without making the consuming panel
    # fail. Newest records are retained when either limit is exceeded.
    class JsonlReader
      Result = Data.define(
        :records, :diagnostics, :truncated, :observed_bytes, :observed_records
      )

      def initialize(root:, reference:, max_bytes:, max_records:, source:,
                     redactor: Hive::SecretPatterns.method(:redact))
        @root = File.realpath(File.expand_path(root))
        raise ArgumentError, "JSONL reader root must be a directory" unless File.directory?(@root)

        @reference = safe_reference(reference)
        @max_bytes = Integer(max_bytes)
        @max_records = Integer(max_records)
        raise ArgumentError, "JSONL limits must be positive" unless
          @max_bytes.positive? && @max_records.positive?

        @source = source.to_s
        @redactor = redactor
      rescue SystemCallError => e
        raise ArgumentError, "invalid JSONL reader root: #{e.class}"
      end

      def call
        path = contained_path
        before = File.lstat(path)
        if before.symlink?
          raise SourceError.new(source: @source, reason: "symlink_refused")
        end
        unless before.file? && !before.symlink?
          raise SourceError.new(source: @source, reason: "not_regular")
        end

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        raw, offset = File.open(path, flags) do |io|
          opened = io.stat
          unless opened.file? && opened.dev == before.dev && opened.ino == before.ino
            raise SourceError.new(source: @source, reason: "descriptor_changed")
          end

          offset = [ opened.size - @max_bytes, 0 ].max
          bytes = io.pread([ opened.size - offset, @max_bytes ].min, offset).to_s
          after = io.stat
          unless stable?(opened, after)
            raise SourceError.new(source: @source, reason: "source_changed")
          end
          [ bytes, offset ]
        end

        diagnostics = []
        truncated = offset.positive?
        if offset.positive?
          raw = raw.split("\n", 2).fetch(1, "")
          diagnostics << cap_diagnostic("journal_suffix_bytes", before.size)
        end
        unless raw.empty? || raw.end_with?("\n")
          raw = raw.lines[0...-1].join
          diagnostics << diagnostic("torn_trailing_record")
          truncated = true
        end

        lines = raw.lines(chomp: true).reject(&:empty?)
        observed_records = lines.length
        if lines.length > @max_records
          lines = lines.last(@max_records)
          diagnostics << cap_diagnostic("journal_events", observed_records, limit: @max_records)
          truncated = true
        end

        records = []
        malformed = 0
        lines.each do |line|
          value = JSON.parse(line)
          if value.is_a?(Hash)
            records << redact_value(value)
          else
            malformed += 1
          end
        rescue JSON::ParserError
          malformed += 1
        end
        diagnostics << diagnostic("malformed_record", "count" => malformed) if malformed.positive?

        Result.new(
          records: records.freeze,
          diagnostics: diagnostics.freeze,
          truncated: truncated,
          observed_bytes: before.size,
          observed_records: observed_records
        )
      rescue Errno::ENOENT
        Result.new(
          records: [].freeze, diagnostics: [].freeze, truncated: false,
          observed_bytes: 0, observed_records: 0
        )
      rescue Errno::ELOOP
        failed("symlink_refused")
      rescue SourceError => e
        Result.new(
          records: [].freeze, diagnostics: [ e.diagnostic ].freeze,
          truncated: false, observed_bytes: 0, observed_records: 0
        )
      rescue SystemCallError, IOError => e
        failed("read_failed", "error_class" => e.class.name)
      end

      private

      def safe_reference(value)
        string = value.to_s.tr("\\", "/")
        path = Pathname.new(string)
        if string.empty? || string.include?("\0") || path.absolute? ||
           path.each_filename.any? { |part| part == ".." }
          raise ArgumentError, "JSONL reference is unsafe"
        end
        string
      end

      def contained_path
        candidate = File.join(@root, @reference)
        parent = File.realpath(File.dirname(candidate))
        unless parent == @root || parent.start_with?("#{@root}#{File::SEPARATOR}")
          raise SourceError.new(source: @source, reason: "containment_escape")
        end
        candidate
      rescue Errno::ENOENT
        File.join(@root, @reference)
      end

      def stable?(before, after)
        before.dev == after.dev && before.ino == after.ino &&
          before.size == after.size && before.mtime == after.mtime
      end

      def redact_value(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).to_h do |key, child|
            [ key, redact_value(child) ]
          end
        when Array
          value.map { |child| redact_value(child) }
        when String
          @redactor.call(value).to_s.force_encoding(Encoding::UTF_8).scrub("")
        else
          value
        end
      end

      def failed(reason, details = {})
        Result.new(
          records: [].freeze,
          diagnostics: [ diagnostic(reason, details) ].freeze,
          truncated: false, observed_bytes: 0, observed_records: 0
        )
      end

      def diagnostic(reason, details = {})
        {
          "source" => @source, "reason" => reason,
          "message" => "bounded #{@source.tr('_', ' ')} evidence is #{reason.tr('_', ' ')}",
          "details" => details
        }
      end

      def cap_diagnostic(cap, observed, limit: @max_bytes)
        diagnostic(
          "limit_exhausted",
          "cap" => cap, "limit" => limit, "observed" => observed
        )
      end
    end
  end
end
