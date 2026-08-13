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
        :records, :diagnostics, :truncated, :observed_bytes, :observed_records,
        :window_start, :window_end
      )

      def initialize(root:, reference:, max_bytes:, max_records:, source:,
                     redactor: Hive::SecretPatterns.method(:redact), preserve: nil)
        @root = File.realpath(File.expand_path(root))
        raise ArgumentError, "JSONL reader root must be a directory" unless File.directory?(@root)

        @reference = safe_reference(reference)
        @max_bytes = Integer(max_bytes)
        @max_records = Integer(max_records)
        raise ArgumentError, "JSONL limits must be positive" unless
          @max_bytes.positive? && @max_records.positive?

        @source = source.to_s
        @redactor = redactor
        @preserve = preserve || ->(_record) { false }
      rescue SystemCallError => e
        raise ArgumentError, "invalid JSONL reader root: #{e.class}"
      end

      def call(before: nil)
        path = contained_path
        path_stat = File.lstat(path)
        if path_stat.symlink?
          raise SourceError.new(source: @source, reason: "symlink_refused")
        end
        unless path_stat.file? && !path_stat.symlink?
          raise SourceError.new(source: @source, reason: "not_regular")
        end

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        raw, offset, window_end = File.open(path, flags) do |io|
          opened = io.stat
          unless opened.file? && opened.dev == path_stat.dev && opened.ino == path_stat.ino
            raise SourceError.new(source: @source, reason: "descriptor_changed")
          end

          window_end = before.nil? ? opened.size : Integer(before)
          unless window_end.between?(0, opened.size)
            raise SourceError.new(source: @source, reason: "cursor_boundary_invalid")
          end
          offset = [ window_end - @max_bytes, 0 ].max
          bytes = io.pread(window_end - offset, offset).to_s
          after = io.stat
          unless stable?(opened, after)
            raise SourceError.new(source: @source, reason: "source_changed")
          end
          [ bytes, offset, window_end ]
        end

        diagnostics = []
        truncated = offset.positive?
        if offset.positive?
          fragment_bytes = raw.index("\n")
          if fragment_bytes
            fragment_bytes += 1
            raw = raw.byteslice(fragment_bytes..).to_s
            offset += fragment_bytes
          else
            raw = ""
            offset = window_end
          end
          diagnostics << cap_diagnostic("journal_suffix_bytes", path_stat.size)
        end
        unless raw.empty? || raw.end_with?("\n")
          raw = raw.lines[0...-1].join
          diagnostics << diagnostic("torn_trailing_record")
          truncated = true
        end

        lines = raw.lines(chomp: true)
        line_offsets = []
        cursor = offset
        lines.each do |line|
          line_offsets << cursor
          cursor += line.bytesize + 1
        end
        nonempty = lines.each_index.reject { |index| lines[index].empty? }
        observed_records = nonempty.length
        parsed = []
        malformed = 0
        nonempty.each do |index|
          line = lines.fetch(index)
          value = JSON.parse(line)
          if value.is_a?(Hash)
            parsed << [ index, redact_value(value) ]
          else
            malformed += 1
          end
        rescue JSON::ParserError
          malformed += 1
        end
        diagnostics << diagnostic("malformed_record", "count" => malformed) if malformed.positive?
        if parsed.length > @max_records
          preserved, ordinary = parsed.partition { |_index, record| @preserve.call(record) }
          retained = (preserved + ordinary.last(@max_records)).uniq(&:first).sort_by(&:first)
          diagnostics << cap_diagnostic("journal_events", observed_records, limit: @max_records)
          truncated = true
        else
          retained = parsed
        end
        records = retained.map(&:last)

        Result.new(
          records: records.freeze,
          diagnostics: diagnostics.freeze,
          truncated: truncated,
          observed_bytes: path_stat.size,
          observed_records: observed_records,
          window_start: offset, window_end: window_end
        )
      rescue Errno::ENOENT
        Result.new(
          records: [].freeze, diagnostics: [].freeze, truncated: false,
          observed_bytes: 0, observed_records: 0, window_start: 0, window_end: 0
        )
      rescue Errno::ELOOP
        failed("symlink_refused")
      rescue SourceError => e
        Result.new(
          records: [].freeze, diagnostics: [ e.diagnostic ].freeze,
          truncated: false, observed_bytes: 0, observed_records: 0,
          window_start: 0, window_end: 0
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
          truncated: false, observed_bytes: 0, observed_records: 0,
          window_start: 0, window_end: 0
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
