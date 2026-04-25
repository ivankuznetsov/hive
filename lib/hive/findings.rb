require "fileutils"

module Hive
  # Parser + writer for the `reviews/ce-review-NN.md` finding files written
  # by the execute-stage reviewer. Each file is a markdown document with
  # severity headings (`## High` / `## Medium` / `## Nit`) and GFM-checkbox
  # findings (`- [ ]` / `- [x]`). The user (or, after this module, an
  # agent) ticks `[x]` for findings to address in the next implementation
  # pass; ticked findings are re-injected into the next prompt by
  # `Hive::Stages::Execute#collect_accepted_findings`.
  #
  # IDs are 1-based and assigned in document order so an agent can refer to
  # a finding by its position in `hive findings` output. They're stable as
  # long as findings aren't reordered or removed; the reviewer prompt
  # writes append-only so this holds in normal use.
  module Findings
    Finding = Data.define(:id, :severity, :accepted, :title, :justification, :line_index) do
      def to_h
        {
          "id" => id,
          "severity" => severity,
          "accepted" => accepted,
          "title" => title,
          "justification" => justification
        }
      end
    end

    SEVERITY_HEADING_RE = /\A##\s+(\S+)\s*\z/
    FINDING_RE = /\A(\s*-\s+)\[([ xX])\]\s+(.+?)\s*\z/

    # Parses a review file into a list of `Finding` records. Preserves the
    # raw line array so writes can flip a single checkbox character without
    # touching surrounding content.
    class Document
      attr_reader :path, :findings, :lines

      def initialize(path)
        raise Hive::NoReviewFile, "no review file at #{path}" unless File.exist?(path)

        @path = path
        @lines = File.readlines(path)
        @findings = parse
      end

      # Returns a new line array with the given finding's checkbox flipped
      # to the requested state. Idempotent — flipping a `[x]` to "accepted"
      # is a no-op. Returns nil if the finding line doesn't match the
      # expected shape (defensive — should never happen if parse succeeded).
      def toggle!(id, accepted:)
        finding = @findings.find { |f| f.id == id }
        raise Hive::UnknownFinding.new("no finding with id=#{id} in #{@path}", id: id) unless finding

        line = @lines[finding.line_index]
        new_line = line.sub(FINDING_RE) do
          prefix = ::Regexp.last_match(1)
          rest = "#{::Regexp.last_match(3)}\n"
          "#{prefix}[#{accepted ? 'x' : ' '}] #{rest}"
        end
        return nil if new_line == line && finding.accepted == accepted

        @lines[finding.line_index] = new_line
        @findings = parse_lines(@lines)
        finding.id
      end

      # Atomic write: tempfile + rename. The reviewer agent might be
      # editing this file too in some failure modes, so we go through the
      # same tempfile + rename pattern Hive::Markers uses.
      def write!
        tmp = "#{@path}.tmp.#{Process.pid}"
        File.write(tmp, @lines.join)
        File.rename(tmp, @path)
      ensure
        FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
      end

      def summary
        by_severity = Hash.new(0)
        accepted_count = 0
        @findings.each do |f|
          by_severity[f.severity] += 1
          accepted_count += 1 if f.accepted
        end
        {
          "total" => @findings.size,
          "accepted" => accepted_count,
          "by_severity" => by_severity
        }
      end

      private

      def parse
        parse_lines(@lines)
      end

      def parse_lines(lines)
        current_severity = nil
        next_id = 1
        lines.each_with_index.filter_map do |line, idx|
          if (m = SEVERITY_HEADING_RE.match(line))
            current_severity = m[1].downcase
            next nil
          end

          fm = FINDING_RE.match(line)
          next nil unless fm

          accepted = fm[2].downcase == "x"
          rest = fm[3]
          title, justification = split_title_justification(rest)
          finding = Finding.new(
            id: next_id, severity: current_severity, accepted: accepted,
            title: title, justification: justification, line_index: idx
          )
          next_id += 1
          finding
        end
      end

      # Split on the first `: ` (colon + space) so titles can contain
      # colons internally (e.g. file paths like `lib/foo.rb:12`). If
      # there's no `: ` separator, treat the whole line as title with no
      # justification.
      def split_title_justification(rest)
        if (idx = rest.index(": "))
          [ rest[0...idx], rest[(idx + 2)..] ]
        else
          [ rest, nil ]
        end
      end
    end

    module_function

    # Resolve which review file to load for a task. Defaults to the latest
    # pass present on disk; --pass N picks a specific one. Returns the
    # absolute path or raises NoReviewFile.
    def review_path_for(task, pass: nil)
      if pass
        path = File.join(task.reviews_dir, format("ce-review-%02d.md", pass))
        raise Hive::NoReviewFile, "no review file for pass #{pass}: #{path}" unless File.exist?(path)

        return path
      end

      candidates = Dir[File.join(task.reviews_dir, "ce-review-*.md")].sort
      raise Hive::NoReviewFile, "no review files in #{task.reviews_dir}" if candidates.empty?

      candidates.last
    end
  end
end
