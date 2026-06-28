require "time"
require "yaml"
require_relative "markers"
require_relative "secret_patterns"

module Hive
  module DiagnosticEvidence
    SUMMARY_MAX = 120
    TAIL_BYTES = 8_192
    LOG_GLOB_CAP = 20
    FRONTMATTER_SCAN_BYTES = 16_384
    STATE_FILE_NAMES = %w[brainstorm.md plan.md task.md pr.md artifacts.md idea.md notes.md].freeze

    module_function

    def summarize(folder:, marker_summary: nil)
      root = folder.to_s
      return nil if root.strip.empty? || !File.directory?(root)

      red_status = red_status_summary(root)
      return red_status if red_status

      state_file = marker_state_file(root)
      marker_text = present(marker_summary) || marker_summary_from_state_file(state_file)
      log = latest_log_summary(root, marker_text)
      return log if log
      return nil unless state_file && marker_text

      summary_payload([ marker_text ], state_file)
    end

    def red_status_summary(folder)
      path = File.join(folder, "diagnostics", "red-status.md")
      return nil unless File.file?(path)

      text = red_status_frontmatter_summary(path) || red_status_body_summary(path)
      return nil unless text

      summary_payload([ text ], path)
    end

    def red_status_frontmatter_summary(path)
      match = safe_read_head(path).match(/\A---\n(.*?)\n---\n/m)
      return nil unless match

      parsed = YAML.safe_load(match[1], permitted_classes: [ Time ]) || {}
      return nil unless parsed.is_a?(Hash)

      present(parsed["summary"] || parsed[:summary])
    rescue Psych::Exception
      nil
    end

    def red_status_body_summary(path)
      in_frontmatter = false
      safe_read_head(path).each_line do |line|
        stripped = line.strip
        if stripped == "---"
          in_frontmatter = !in_frontmatter
          next
        end
        next if in_frontmatter || stripped.empty?

        return stripped
      end
      nil
    end

    def latest_log_summary(folder, marker_text)
      log_candidates(folder).each do |path|
        line = last_meaningful_line(path)
        next unless line

        return summary_payload([ marker_text, line ], path)
      end
      nil
    end

    def log_candidates(folder)
      candidates = log_dirs(folder).flat_map { |dir| Dir[File.join(dir, "*.log")] }
      return [] if candidates.empty?

      candidates.sort.last(LOG_GLOB_CAP)
                .sort_by { |path| safe_mtime(path) || Time.at(0) }
                .reverse
    rescue SystemCallError
      []
    end

    def log_dirs(folder)
      [ inferred_task_log_dir(folder), File.join(folder, "logs") ].compact.uniq
    end

    def inferred_task_log_dir(folder)
      match = folder.match(%r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/[^/]+/(?<slug>[^/]+)\z})
      return nil unless match

      File.join(match[:root], match[:state_dir], "logs", match[:slug])
    end

    def marker_state_file(folder)
      state_file_candidates(folder).find do |path|
        marker = current_marker(path)
        marker && !marker.none?
      end
    end

    def state_file_candidates(folder)
      known = STATE_FILE_NAMES.map { |name| File.join(folder, name) }
      (known + Dir[File.join(folder, "*.md")].sort).uniq
    rescue SystemCallError
      []
    end

    def marker_summary_from_state_file(path)
      marker = current_marker(path)
      return nil unless marker

      attrs = Hive::Markers.display_attrs(marker.attrs)
                           .map { |key, value| "#{key}=#{value}" }
                           .join(" ")
      marker_name = marker.name.to_s.upcase
      attrs.empty? ? marker_name : "#{marker_name} #{attrs}"
    end

    def current_marker(path)
      return nil if path.to_s.empty?

      marker = Hive::Markers.current(path)
      marker.none? ? nil : marker
    rescue SystemCallError, EncodingError, ArgumentError
      nil
    end

    def last_meaningful_line(path)
      tail_file(path).lines.reverse_each do |line|
        stripped = line.strip
        return stripped unless stripped.empty?
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    def tail_file(path)
      raw = File.open(path, "rb") do |file|
        begin
          file.seek(-TAIL_BYTES, IO::SEEK_END)
        rescue Errno::EINVAL
          file.rewind
        end
        file.read.to_s
      end
      utf8(raw)
    end

    def safe_read_head(path)
      raw = File.open(path, "rb") { |file| file.read(FRONTMATTER_SCAN_BYTES).to_s }
      utf8(raw)
    rescue SystemCallError, IOError
      ""
    end

    def safe_mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end

    def summary_payload(parts, source_path)
      summary = parts.compact.map { |part| one_line(part) }.reject(&:empty?).join(": ")
      summary = truncate(Hive::SecretPatterns.redact(summary), SUMMARY_MAX)
      { summary: summary, source_path: source_path }
    end

    def present(value)
      text = one_line(value)
      text.empty? ? nil : text
    end

    def one_line(value)
      utf8(value.to_s).gsub(/\s+/, " ").strip
    end

    def utf8(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0, max - 1]}…"
    end
  end
end
