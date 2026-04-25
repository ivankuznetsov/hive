require "fileutils"
require "securerandom"

module Hive
  # Parser + writer for the `reviews/ce-review-NN.md` finding files written
  # by the execute-stage reviewer. Each file is a markdown document with
  # severity headings (`## High` / `## Medium` / `## Nit`) and GFM-checkbox
  # findings (`- [ ]` / `- [x]`). Ticking `[x]` flags a finding to address
  # in the next implementation pass; ticked findings are re-injected into
  # the next prompt by `Hive::Stages::Execute#collect_accepted_findings`.
  #
  # IDs are 1-based and assigned in document order so callers can refer to
  # a finding by its position in `hive findings` output. They're stable as
  # long as findings aren't reordered or removed; the reviewer prompt
  # writes append-only so this holds in normal use.
  module Findings
    KNOWN_SEVERITIES = %w[high medium low nit].freeze
    SEVERITY_HEADING_RE = /\A##\s+(.+?)\s*\z/
    # Captures the leading prefix (`- `), the checkbox state, the title +
    # justification body, and the trailing line ending separately so the
    # writer can preserve `\n` vs `\r\n` when rebuilding the line.
    FINDING_RE = /\A(\s*-\s+)\[([ xX])\]\s+(.*?)([\r\n]*)\z/
    # Triple-backtick fence (and triple-tilde for completeness). Tracked
    # so a `## High` or `- [ ] foo` *inside* a fenced code block doesn't
    # accidentally register as a heading or a finding.
    FENCE_RE = /\A\s*(?:```|~~~)/

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

      # Flip the given finding's checkbox to the requested state. Idempotent
      # on a no-op (already in target state) — returns nil. Preserves the
      # original line ending (`\n` or `\r\n`) so a CRLF file round-trips
      # without flattening to LF.
      def toggle!(id, accepted:)
        finding = @findings.find { |f| f.id == id }
        raise Hive::UnknownFinding.new("no finding with id=#{id} in #{@path}", id: id) unless finding

        return nil if finding.accepted == accepted

        line = @lines[finding.line_index]
        new_line = line.sub(FINDING_RE) do
          prefix = ::Regexp.last_match(1)
          body   = ::Regexp.last_match(3)
          eol    = ::Regexp.last_match(4)
          "#{prefix}[#{accepted ? 'x' : ' '}] #{body}#{eol}"
        end
        @lines[finding.line_index] = new_line
        @findings = parse_lines(@lines)
        finding.id
      end

      # Atomic write: tempfile + rename. The reviewer agent might be
      # editing this file too in some failure modes, so we go through the
      # same tempfile + rename pattern Hive::Markers uses. The PID-plus-
      # random-suffix tempfile name defends against PID reuse: if a prior
      # process crashed between write and rename, leaving `.tmp.<pid>`
      # stale, a new process with the same PID won't collide.
      def write!
        tmp = "#{@path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
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
        in_fence = false
        next_id = 1
        lines.each_with_index.filter_map do |line, idx|
          if FENCE_RE.match?(line)
            in_fence = !in_fence
            next nil
          end
          # Inside a fenced code block, headings and finding-shaped lines
          # are content, not structure — skip them so a `## High` or a
          # `- [ ] foo` example in justification can't false-positive.
          next nil if in_fence

          if (m = SEVERITY_HEADING_RE.match(line))
            # Any `##` heading resets severity; a non-canonical heading
            # (e.g. `## Detailed Analysis`) clears it instead of leaking
            # the previous severity into the findings that follow.
            first_word = m[1].split(/\s+/).first&.downcase
            current_severity = KNOWN_SEVERITIES.include?(first_word) ? first_word : nil
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

    # Extract the integer pass number from a `ce-review-NN.md` filename.
    # Returns nil for paths whose basename doesn't match the convention.
    def pass_from_path(path)
      m = File.basename(path).match(/ce-review-(\d+)\.md/)
      m ? m[1].to_i : nil
    end
  end
end
