require "pathname"
require "hive/secret_patterns"
require "hive/task_workspace/source_error"

module Hive
  module TaskWorkspace
    class BoundedReader
      Result = Data.define(
        :content, :bytes, :truncated, :invalid_encoding, :binary, :evidence_ref
      )

      class Budget
        attr_reader :limit, :consumed

        def initialize(limit)
          @limit = Integer(limit)
          raise ArgumentError, "read budget must be positive" unless @limit.positive?

          @consumed = 0
        end

        def remaining
          limit - consumed
        end

        def consume!(bytes)
          amount = Integer(bytes)
          raise SourceError.new(source: "bounded_reader", reason: "aggregate_budget_exhausted") if
            amount.negative? || amount > remaining

          @consumed += amount
        end
      end

      def initialize(root:, redactor: Hive::SecretPatterns.method(:redact))
        @root = File.realpath(File.expand_path(root))
        raise ArgumentError, "bounded reader root must be a directory" unless File.directory?(@root)

        @redactor = redactor
      rescue SystemCallError => e
        raise ArgumentError, "invalid bounded reader root: #{e.message}"
      end

      def read(reference, max_bytes:, budget: nil)
        relative = safe_reference(reference)
        limit = Integer(max_bytes)
        raise ArgumentError, "source byte limit must be positive" unless limit.positive?

        budget ||= Budget.new(limit)
        allowed = [ limit, budget.remaining ].min
        if allowed <= 0
          raise SourceError.new(
            source: "bounded_reader", reason: "aggregate_budget_exhausted",
            details: { "limit" => budget.limit, "observed_bytes" => budget.consumed }
          )
        end

        path = contained_path(relative)
        before = File.lstat(path)
        if before.symlink?
          raise SourceError.new(source: "artifact", reason: "symlink_refused")
        end
        unless before.file? && !before.symlink?
          raise SourceError.new(source: "artifact", reason: "not_regular", message: relative)
        end

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |io|
          opened = io.stat
          unless opened.file? && opened.dev == before.dev && opened.ino == before.ino
            raise SourceError.new(source: "artifact", reason: "descriptor_changed")
          end

          raw = io.read(allowed + 1).to_s
          visible = raw.byteslice(0, allowed).to_s
          budget.consume!(visible.bytesize)
          after = io.stat
          unless stable?(opened, after)
            raise SourceError.new(source: "artifact", reason: "source_changed")
          end

          invalid_encoding = !visible.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          binary = visible.include?("\0")
          text = visible.dup.force_encoding(Encoding::UTF_8).scrub("?")
          redacted = @redactor.call(text).to_s
          truncated = raw.bytesize > allowed || opened.size > allowed
          redacted = redact_truncated_secret_tail(redacted) if truncated
          redacted = utf8_prefix(redacted, allowed)
          Result.new(
            content: redacted.freeze,
            bytes: visible.bytesize,
            truncated: truncated,
            invalid_encoding: invalid_encoding,
            binary: binary,
            evidence_ref: relative
          )
        end
      rescue SourceError
        raise
      rescue Errno::ELOOP
        raise SourceError.new(source: "artifact", reason: "symlink_refused")
      rescue Errno::ENOENT
        raise SourceError.new(source: "artifact", reason: "missing")
      rescue SystemCallError, IOError => e
        raise SourceError.new(
          source: "artifact", reason: "read_failed", message: e.class.name
        )
      end

      private

      def safe_reference(reference)
        value = reference.to_s
        path = Pathname.new(value)
        if value.empty? || value.include?("\0") || path.absolute? ||
           path.each_filename.any? { |part| part == ".." }
          raise SourceError.new(source: "bounded_reader", reason: "invalid_reference")
        end
        value.tr("\\", "/")
      end

      def contained_path(relative)
        candidate = File.join(@root, relative)
        parent = File.realpath(File.dirname(candidate))
        unless parent == @root || parent.start_with?("#{@root}#{File::SEPARATOR}")
          raise SourceError.new(source: "bounded_reader", reason: "containment_escape")
        end
        candidate
      rescue Errno::ENOENT
        raise SourceError.new(source: "artifact", reason: "missing")
      end

      def stable?(before, after)
        before.dev == after.dev && before.ino == after.ino &&
          before.size == after.size && before.mtime == after.mtime
      end

      def utf8_prefix(value, bytes)
        return value if value.bytesize <= bytes

        value.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub("")
      end

      # A display ceiling can cut a token before the shared full-token regex
      # has enough bytes to recognize it. Conservatively hide a credential-
      # shaped suffix at that exact boundary instead of publishing a useful
      # token prefix. This does not claim that the suffix was a valid secret.
      def redact_truncated_secret_tail(value)
        value.gsub(
          /(?:\b(?:github_pat_|gh[psou]_|sk-(?:ant-)?|(?:sk|rk|pk)_(?:live|test)_|xox[abprs]-)[A-Za-z0-9_.+\/=\-]*|\b(?:api[_-]?key|password|passwd|pwd)\s*[:=]\s*[^\s]*|\bauthorization\s*[:=]\s*(?:Bearer|Basic|Token)\s*[^\s]*)\z/i,
          "[REDACTED:truncated_secret]"
        )
      end
    end
  end
end
