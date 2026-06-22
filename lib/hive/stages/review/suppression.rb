require "digest"
require "fileutils"
require "securerandom"
require "set"
require "hive/findings"

module Hive
  module Stages
    module Review
      module Suppression
        Entry = Data.define(:key, :severity, :text, :first_pass, :active)

        VERSION = "v1".freeze
        HEADER_RE = /\A<!--\s+HIVE-SUPPRESS\s+v1\s+base=([^ ]+)\s+-->\s*\z/.freeze
        CHECKBOX_LINE_RE = /\A\s*-\s+\[([ xX])\]\s+(.*?)(?:\s*<!--(.*?)-->)?\s*\z/.freeze
        UNCHECKED_LINE_RE = /\A(\s*)-\s+\[\s*\]\s+(.*?)(\r?\n?)\z/.freeze
        RESOLVED_NO_FIX_LINE_RE = /\A\s*-\s+\[x\]\s+RESOLVED\/NO-FIX:\s+(.*?)(?:\r?\n)?\z/i.freeze
        FP_RE = /\bfp=([0-9a-f]{16})\b/i.freeze
        FIRST_PASS_RE = /\bfirst-pass=(\d+)\b/.freeze
        DISPOSITION_PREFIX_RE = /\A(?:AUTO-FIX|RESOLVED\/NO-FIX|RESOLVED|NO-FIX|ESCALATE|SUPPRESSED):\s*/i.freeze
        # Matches a single HTML comment anywhere in the text (non-greedy,
        # multiline-dotall). clean_finding_text strips ALL comments with a
        # global sub, not just a trailing one: an anchored `...-->\z` match
        # would collapse the span from the first `<!--` to the last `-->`,
        # swallowing any visible text between two comments. Harmless for a
        # lone trailing comment, but a latent footgun if a finding ever
        # embeds a mid-text comment.
        HTML_COMMENT_RE = /<!--.*?-->/m.freeze
        # Recognizes a file reference so its `:line[:col]` suffix can be
        # stripped before fingerprinting. Two alternatives:
        #   1. a dotted path (`lib/foo.rb`, `a/b/c.tsx:12:3`) — extension
        #      required, line/col optional;
        #   2. an extensionless basename that carries a `:line[:col]`
        #      suffix (`Gemfile:12`, `Dockerfile:8`, `path/Makefile:5`) —
        #      the suffix is mandatory here so a bare word never reads as a
        #      path, but a line-drifted re-emission on a common
        #      extensionless config file still folds to the same key.
        PATH_TOKEN_RE = %r{
          (?:`)?
          (
            [A-Za-z0-9_.@+\-]+(?:/[A-Za-z0-9_.@+\-]+)*\.[A-Za-z0-9_+\-]+(?::\d+(?::\d+)?)?
            |
            [A-Za-z0-9_.@+\-]+(?:/[A-Za-z0-9_.@+\-]+)*:\d+(?::\d+)?
          )
          (?:`)?
        }x.freeze
        LINE_NUMBER_SUFFIX_RE = /:\d+(?::\d+)?\z/.freeze
        # Equal-length placeholder used to mask file-ref tokens while
        # locating the real title/justification separator (see
        # title_region). A NUL never appears in reviewer text, so it can't
        # be mistaken for a genuine character preceding the separator.
        FILE_REF_MASK = "\x00".freeze
        PUNCT_RE = /[[:punct:]]+/.freeze
        # Canonical severity list for the suppressed doc — the single
        # source of truth. Section headings, inline labels, the heading
        # recognizer (parse_section), the inline-severity gate
        # (split_entry_severity) and normalize_severity all derive from
        # this list, so they can never disagree. Critically it includes
        # "unknown", so a `## Unknown` section render_document writes is
        # re-recognized by parse_section on read-back (it would not when
        # the recognizer reused Findings::KNOWN_SEVERITIES, which omits
        # "unknown").
        SEVERITY_ORDER = %w[high medium low nit unknown].freeze
        SECTION_TITLES = SEVERITY_ORDER.to_h { |severity|
          title = severity == "high" ? "## High - prominent active suppressions" : "## #{severity.capitalize}"
          [ severity, title ]
        }.freeze
        SEVERITY_LABELS = SEVERITY_ORDER.to_h { |severity| [ severity, severity.capitalize ] }.freeze

        module_function

        def suppressed_path(ctx)
          File.join(ctx.task_folder, "reviews", "suppressed.md")
        end

        # Stable fingerprint for a finding line. Two normalizations make it
        # robust: the justification body (everything after the first
        # title/justification ": ") is excluded so a re-emitted finding
        # with a reworded rationale keeps the same key (A3), and file refs
        # are folded to a normalized, line-number-free set so the same
        # finding at a drifted line still matches.
        #
        # Both the file-ref set AND the title come from `title_region` —
        # the part of the line before the real title/justification
        # separator. The body never feeds the key, so a finding whose
        # rationale happens to mention a different path keeps the same key
        # (A3). title_region masks `file:line:` tokens before locating the
        # separator, so a reviewer line shaped `file:line: description` is
        # not collapsed by the artifact colon of the `file:line:` token —
        # preserving the plan's "different-title re-loops" guarantee.
        #
        # Symbol-level enrichment of the key (e.g. the enclosing method
        # name) is a deferred A3 nice-to-have, intentionally NOT in v1.
        def key_for(text, severity:)
          region = title_region(clean_finding_text(text))
          files = region.scan(PATH_TOKEN_RE).flatten
                        .map { |path| path.sub(LINE_NUMBER_SUFFIX_RE, "").downcase }
                        .uniq
                        .sort
                        .join(",")
          title = region.gsub(PATH_TOKEN_RE, " ")
                        .downcase
                        .gsub(PUNCT_RE, " ")
                        .gsub(/\s+/, " ")
                        .strip
          severity_key = normalize_severity(severity)
          ::Digest::SHA256.hexdigest("#{severity_key}\x01#{files}\x01#{title}")[0, 16]
        end

        def read_active_keys(ctx)
          read_active_entries(ctx).keys.to_set
        end

        def read_active_entries(ctx)
          read_entries(suppressed_path(ctx)).select(&:active).to_h { |entry| [ entry.key, entry ] }
        end

        def reset_if_base_changed!(ctx, base_sha)
          path = suppressed_path(ctx)
          return false if suppressed_doc_unreadable?(path)

          existing_base = recorded_base(path)
          return false if existing_base == base_sha

          write_entries(path, base_sha, [])
          true
        end

        def append_entries!(ctx, base_sha, entries)
          path = suppressed_path(ctx)
          # Bail before mutating if the file is present but unreadable, so a
          # transient read error can't turn an append into a destructive
          # overwrite that silently loses operator-edited tombstones.
          return 0 if suppressed_doc_unreadable?(path)

          reset_if_base_changed!(ctx, base_sha)
          existing = read_entries(path)
          known_keys = existing.map(&:key).to_set

          additions = entries.filter_map do |entry|
            normalized = normalize_entry(entry)
            next if known_keys.include?(normalized.key)

            known_keys << normalized.key
            normalized
          end

          return 0 if additions.empty?

          write_entries(path, base_sha, existing + additions)
          additions.size
        end

        def strip_suppressed!(cfg:, ctx:, base_sha:)
          return 0 unless enabled?(cfg)

          reviewer_files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
          return 0 if reviewer_files.empty?

          reset_if_base_changed!(ctx, base_sha)
          active_entries = read_active_entries(ctx)
          return 0 if active_entries.empty?

          reviewer_files.sum do |path|
            strip_file!(path, active_entries, ctx.pass)
          end
        end

        def seed_from_triage!(cfg:, ctx:, base_sha:)
          return 0 unless enabled?(cfg)

          reviewer_files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
          entries = reviewer_files.flat_map { |path| no_fix_entries(path, ctx.pass) }
          return 0 if entries.empty?

          append_entries!(ctx, base_sha, entries)
        end

        def clean_finding_text(text)
          cleaned = text.to_s.strip
          cleaned = cleaned.sub(/\A\s*-\s+\[[ xX]\]\s+/, "")
          loop do
            before = cleaned
            # Strip ALL HTML comments (replaced with a space so adjacent
            # tokens never glue), then a leading disposition prefix; repeat
            # until stable so stacked prefixes/comments fully unwrap.
            cleaned = cleaned.gsub(HTML_COMMENT_RE, " ").strip
            cleaned = cleaned.sub(DISPOSITION_PREFIX_RE, "").strip
            break if cleaned == before
          end
          cleaned.gsub(/\s+/, " ")
        end

        # Title region of a finding line: everything before the first real
        # ": " (colon-space) separator that reviewers use to split a
        # finding's title from its justification body, with file refs left
        # INTACT so key_for can extract them from here (and only here).
        # Excluding the justification is what keeps the key stable when
        # triage re-emits the same finding with a reworded rationale (A3);
        # scoping the file-ref scan to this region is what keeps a reworded
        # rationale that mentions a different path from changing the key.
        # This split is load-bearing for suppression matching, and a change
        # here silently shifts every key. Mirrors
        # Hive::Findings::Document#split_title_justification.
        #
        # A `file:line:` ref ends in a colon that, followed by a space,
        # is indistinguishable from the title/justification separator. We
        # mask every file-ref token with an equal-length run of NULs
        # (offsets preserved) and take the first ": " whose colon is not
        # the masked tail of a ref. So `file:line: description` keeps the
        # whole description as the title while `file:line: title:
        # justification` still drops the justification.
        def title_region(cleaned)
          masked = cleaned.gsub(PATH_TOKEN_RE) { |m| FILE_REF_MASK * m.length }
          search_from = 0
          while (idx = masked.index(": ", search_from))
            return cleaned[0...idx] if idx.zero? || masked[idx - 1] != FILE_REF_MASK

            search_from = idx + 1
          end
          cleaned
        end

        def normalize_severity(severity)
          value = severity.to_s.downcase.strip
          # Clamp to the canonical set (default "unknown") so an
          # out-of-enum severity — e.g. an operator-hand-added
          # `- [x] Critical: ...` — can never be silently dropped by
          # render_document, which only iterates SEVERITY_ORDER.
          SEVERITY_ORDER.include?(value) ? value : "unknown"
        end

        def enabled?(cfg)
          cfg.dig("review", "triage", "enabled") != false &&
            cfg.dig("review", "triage", "suppress_no_fix") != false
        end

        def recorded_base(path)
          return nil unless File.exist?(path)

          first = File.open(path, &:readline)
          match = HEADER_RE.match(first.strip)
          match && match[1]
        rescue EOFError
          # 0-byte file: no header line and no entries to lose, so the
          # ensuing reset is legitimate — stay silent.
          nil
        rescue SystemCallError, IOError => e
          # A genuine read error (or a partial read that slipped past the
          # 1-byte probe in suppressed_doc_unreadable?) makes
          # reset_if_base_changed! treat the doc as base-mismatched and
          # overwrite it, silently dropping operator-edited entries. Warn
          # like the sibling reviewer_lines rescue rather than fail quietly.
          warn "[hive.review] reviews/suppressed.md header unreadable " \
               "(#{e.class}: #{e.message}); treating the compare base as " \
               "changed, which resets the suppression list"
          nil
        end

        # True when the suppressed doc is present but a genuine read error
        # (permissions, I/O — NOT ENOENT, which is the legitimate
        # first-run case) blocks reading it. Mutation paths (reset/append)
        # must skip rather than clobber operator-edited tombstones they
        # cannot see; query paths (read_active_*) still fail safe to empty
        # so findings re-surface. Distinguishing absent from unreadable is
        # what keeps a transient read error from wiping the list.
        def suppressed_doc_unreadable?(path)
          return false unless File.exist?(path)

          File.open(path) { |io| io.read(1) }
          false
        rescue Errno::ENOENT
          false
        rescue SystemCallError, IOError => e
          warn "[hive.review] reviews/suppressed.md present but unreadable " \
               "(#{e.class}: #{e.message}); skipping suppression update to " \
               "preserve operator-edited entries"
          true
        end

        def read_entries(path)
          return [] unless File.exist?(path)

          entries = []
          each_content_line(File.readlines(path)) do |line, current_severity|
            entry = parse_entry_line(line, current_severity)
            entries << entry if entry
          end
          entries
        rescue SystemCallError, IOError => e
          # On the mutate path (append_entries!) a swallowed read here means
          # write_entries persists only the additions and drops every
          # existing entry. Warn like reviewer_lines so the loss is visible.
          warn "[hive.review] reviews/suppressed.md entries unreadable " \
               "(#{e.class}: #{e.message}); treating the list as empty, " \
               "which can drop operator-edited entries on the next write"
          []
        end

        # Reads a reviewer file's lines, degrading to an empty list (with a
        # warning) when the file is present but unreadable, so one bad
        # reviewer file can't abort the whole review pass with a top-level
        # REVIEW_ERROR — matching the deliberate rescue on the suppression
        # doc. ENOENT (absent) is the silent empty case.
        def reviewer_lines(path)
          File.readlines(path)
        rescue Errno::ENOENT
          []
        rescue SystemCallError, IOError => e
          warn "[hive.review] could not read reviewer file #{path} " \
               "(#{e.class}: #{e.message}); skipping it for this suppression pass"
          []
        end

        # Shared non-fence line iterator. Tracks fenced-code regions and
        # the current severity heading once (mirroring
        # Hive::Findings::Document#parse_lines) and yields
        # [line, current_severity] for each CONTENT line — fence and
        # heading lines are consumed, not yielded. Used by read_entries and
        # no_fix_entries so a `## High` or `- [ ] foo` example inside a
        # ``` fenced block is treated as content, not structure.
        # strip_file! keeps its own walk because it rewrites lines and must
        # re-emit the structural lines this iterator skips.
        def each_content_line(lines)
          current_severity = nil
          in_fence = false
          lines.each do |line|
            in_fence = !in_fence if Hive::Findings::FENCE_RE.match?(line)
            next if in_fence

            if (section = parse_section(line))
              current_severity = section
              next
            end

            yield line, current_severity
          end
        end

        def parse_section(line)
          match = Hive::Findings::SEVERITY_HEADING_RE.match(line)
          return nil unless match

          first_word = match[1].split(/\s+/).first&.downcase
          SEVERITY_ORDER.include?(first_word) ? first_word : nil
        end

        def parse_entry_line(line, current_severity)
          match = CHECKBOX_LINE_RE.match(line)
          return nil unless match

          active = match[1].downcase == "x"
          visible = clean_finding_text(match[2])
          comment = match[3].to_s
          severity, text = split_entry_severity(visible, current_severity)
          key = comment[FP_RE, 1] || key_for(text, severity: severity)
          first_pass = comment[FIRST_PASS_RE, 1]&.to_i
          Entry.new(key: key, severity: severity, text: text, first_pass: first_pass, active: active)
        end

        def strip_file!(path, active_entries, pass)
          lines = reviewer_lines(path)
          current_severity = nil
          in_fence = false
          changed = false
          stripped = 0

          lines.map! do |line|
            in_fence = !in_fence if Hive::Findings::FENCE_RE.match?(line)
            if !in_fence && (section = parse_section(line))
              current_severity = section
              next line
            end
            next line if in_fence

            rewritten = suppressed_line(line, current_severity, active_entries, pass)
            if rewritten
              changed = true
              stripped += 1
              rewritten
            else
              line
            end
          end

          write_atomic(path, lines.join) if changed
          stripped
        end

        def suppressed_line(line, current_severity, active_entries, pass)
          match = UNCHECKED_LINE_RE.match(line)
          return nil unless match

          original = match[2].strip
          key = key_for(original, severity: current_severity)
          entry = active_entries[key]
          return nil unless entry

          first_pass = entry.first_pass || pass
          "#{match[1]}- [x] SUPPRESSED: #{original} <!-- suppressed: fp=#{key} first-pass=#{format('%02d', first_pass)} -->#{match[3]}"
        end

        def no_fix_entries(path, pass)
          entries = []
          each_content_line(reviewer_lines(path)) do |line, current_severity|
            match = RESOLVED_NO_FIX_LINE_RE.match(line)
            next unless match

            text = clean_finding_text(match[1])
            severity = normalize_severity(current_severity)
            entries << Entry.new(
              key: key_for(text, severity: severity),
              severity: severity,
              text: text,
              first_pass: pass,
              active: true
            )
          end
          entries
        end

        def split_entry_severity(visible, fallback)
          m = visible.match(/\A([A-Za-z]+):\s+(.+)\z/)
          # Only treat a leading `Word:` as the severity when it is a known
          # severity (matching parse_section's gate). Otherwise a hand-added
          # `- [x] Bug: ...` under `## High` would key with severity "bug"
          # while strip_suppressed! keys the same finding with the section
          # severity "high", so the operator's suppression would never match.
          if m && SEVERITY_ORDER.include?(m[1].downcase)
            [ normalize_severity(m[1]), m[2].strip ]
          else
            [ normalize_severity(fallback), visible.strip ]
          end
        end

        def normalize_entry(entry)
          severity = normalize_severity(entry.severity)
          text = clean_finding_text(entry.text)
          key = entry.key.to_s.empty? ? key_for(text, severity: severity) : entry.key
          Entry.new(
            key: key,
            severity: severity,
            text: text,
            first_pass: entry.first_pass,
            active: entry.active != false
          )
        end

        def write_entries(path, base_sha, entries)
          FileUtils.mkdir_p(File.dirname(path))
          body = render_document(base_sha, entries.map { |entry| normalize_entry(entry) })
          write_atomic(path, body)
        end

        def render_document(base_sha, entries)
          body = +"<!-- HIVE-SUPPRESS #{VERSION} base=#{base_sha} -->\n"
          body << "\n"
          body << "# Suppressed review findings\n\n"
          body << "Hive suppresses checked entries here before triage when reviewers re-emit a finding triage already marked no-fix.\n"
          body << "Uncheck an entry (keep the `- [ ]` tombstone) to durably un-suppress: the tombstone stays in the list, so triage sees the finding on the next pass and never re-suppresses it.\n"
          body << "Deleting an entry only un-suppresses until the next no-fix pass, which re-seeds and re-suppresses it.\n"
          body << "This file is orchestrator-owned and is reset when the reviewer compare base changes.\n\n"

          grouped = entries.group_by(&:severity)
          SEVERITY_ORDER.each do |severity|
            body << "#{SECTION_TITLES.fetch(severity)}\n\n"
            grouped.fetch(severity, []).each do |entry|
              checkbox = entry.active ? "x" : " "
              body << "- [#{checkbox}] #{SEVERITY_LABELS.fetch(severity)}: #{entry.text}"
              body << " <!-- fp=#{entry.key}"
              body << " first-pass=#{format('%02d', entry.first_pass)}" if entry.first_pass
              body << " -->\n"
            end
            body << "\n"
          end

          body
        end

        def write_atomic(path, body)
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
          File.write(tmp, body)
          File.rename(tmp, path)
        ensure
          FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
        end
      end
    end
  end
end
