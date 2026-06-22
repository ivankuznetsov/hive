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
        SECTION_RE = /\A##\s+(.+?)\s*\z/.freeze
        FP_RE = /\bfp=([0-9a-f]{16})\b/i.freeze
        FIRST_PASS_RE = /\bfirst-pass=(\d+)\b/.freeze
        DISPOSITION_PREFIX_RE = /\A(?:AUTO-FIX|RESOLVED\/NO-FIX|RESOLVED|NO-FIX|ESCALATE|SUPPRESSED):\s*/i.freeze
        HTML_COMMENT_RE = /\s*<!--.*?-->\s*\z/.freeze
        PATH_TOKEN_RE = %r{
          (?:`)?
          ([A-Za-z0-9_.@+\-]+(?:/[A-Za-z0-9_.@+\-]+)*\.[A-Za-z0-9_+\-]+(?::\d+(?::\d+)?)?)
          (?:`)?
        }x.freeze
        LINE_NUMBER_SUFFIX_RE = /:\d+(?::\d+)?\z/.freeze
        PUNCT_RE = /[[:punct:]]+/.freeze
        SEVERITY_ORDER = %w[high medium low nit unknown].freeze
        SECTION_TITLES = {
          "high" => "## High - prominent active suppressions",
          "medium" => "## Medium",
          "low" => "## Low",
          "nit" => "## Nit",
          "unknown" => "## Unknown"
        }.freeze
        SEVERITY_LABELS = {
          "high" => "High",
          "medium" => "Medium",
          "low" => "Low",
          "nit" => "Nit",
          "unknown" => "Unknown"
        }.freeze

        module_function

        def suppressed_path(ctx)
          File.join(ctx.task_folder, "reviews", "suppressed.md")
        end

        def key_for(text, severity:)
          cleaned = title_text(clean_finding_text(text))
          files = cleaned.scan(PATH_TOKEN_RE).flatten
                         .map { |path| path.sub(LINE_NUMBER_SUFFIX_RE, "").downcase }
                         .uniq
                         .sort
                         .join(",")
          title = cleaned.gsub(PATH_TOKEN_RE, " ")
                         .downcase
                         .gsub(PUNCT_RE, " ")
                         .gsub(/\s+/, " ")
                         .strip
          severity_key = normalize_severity(severity)
          Digest::SHA256.hexdigest("#{severity_key}\x01#{files}\x01#{title}")[0, 16]
        end

        def read_active_keys(ctx)
          read_active_entries(ctx).keys.to_set
        end

        def read_active_entries(ctx)
          read_entries(suppressed_path(ctx)).select(&:active).to_h { |entry| [ entry.key, entry ] }
        end

        def reset_if_base_changed!(ctx, base_sha)
          path = suppressed_path(ctx)
          existing_base = recorded_base(path)
          return false if existing_base == base_sha

          write_entries(path, base_sha, [])
          true
        end

        def append_entries!(ctx, base_sha, entries)
          reset_if_base_changed!(ctx, base_sha)
          path = suppressed_path(ctx)
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
            cleaned = cleaned.sub(HTML_COMMENT_RE, "").strip
            cleaned = cleaned.sub(DISPOSITION_PREFIX_RE, "").strip
            break if cleaned == before
          end
          cleaned
        end

        def title_text(text)
          idx = text.index(": ")
          idx ? text[0...idx] : text
        end

        def normalize_severity(severity)
          value = severity.to_s.downcase.strip
          value.empty? ? "unknown" : value
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
        rescue EOFError, SystemCallError, IOError
          nil
        end

        def read_entries(path)
          return [] unless File.exist?(path)

          entries = []
          current_severity = nil
          File.readlines(path).each do |line|
            if (section = parse_section(line))
              current_severity = section
              next
            end

            entry = parse_entry_line(line, current_severity)
            entries << entry if entry
          end
          entries
        rescue SystemCallError, IOError
          []
        end

        def parse_section(line)
          match = SECTION_RE.match(line)
          return nil unless match

          first_word = match[1].split(/\s+/).first&.downcase
          Hive::Findings::KNOWN_SEVERITIES.include?(first_word) ? first_word : nil
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
          lines = File.readlines(path)
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

            rewritten = suppressed_line(line, current_severity, active_entries, pass, in_fence)
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

        def suppressed_line(line, current_severity, active_entries, pass, in_fence)
          return nil if in_fence

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
          current_severity = nil
          in_fence = false
          File.readlines(path).filter_map do |line|
            in_fence = !in_fence if Hive::Findings::FENCE_RE.match?(line)
            if !in_fence && (section = parse_section(line))
              current_severity = section
              next nil
            end
            next nil if in_fence

            match = RESOLVED_NO_FIX_LINE_RE.match(line)
            next nil unless match

            text = clean_finding_text(match[1])
            severity = normalize_severity(current_severity)
            Entry.new(
              key: key_for(text, severity: severity),
              severity: severity,
              text: text,
              first_pass: pass,
              active: true
            )
          end
        end

        def split_entry_severity(visible, fallback)
          if visible =~ /\A([A-Za-z]+):\s+(.+)\z/
            [ normalize_severity(Regexp.last_match(1)), Regexp.last_match(2).strip ]
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
          body << "Uncheck or delete an entry to let the finding reach triage on the next pass.\n"
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
