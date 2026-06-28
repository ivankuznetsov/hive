require "time"
require "yaml"
require_relative "markers"
require_relative "secret_patterns"
require_relative "diagnostic_helpers"

module Hive
  # Best-effort on-disk evidence resolver for the `--diagnose` read path. When
  # a task's current marker no longer classifies as a red recovery action,
  # Hive::TaskAction#diagnostic returns nil; this module fills that gap from
  # whatever evidence is already on disk, in tier order:
  #   1. diagnostics/red-status.md  (a prior agent verdict)  -> kind :red_status
  #   2. the newest meaningful logs/*.log line               -> kind :log
  #   3. the current marker on the task state file           -> kind :marker
  # Each result carries an explicit `kind` so consumers label the source
  # correctly (Diagnostics:/Log:/Marker:) instead of hardcoding "Log:".
  #
  # Contract: summarize NEVER raises — it degrades to nil (or a best-effort
  # lower tier) on any error, because the CLI re-wraps a raise as InternalError
  # (exit 70) and the bot drops every other child's reply in the same tick.
  module DiagnosticEvidence
    # Aliased to the shared single source so the schema-pinned cap and the
    # boundary-safe tail helper can't drift from Hive::TaskAction::Diagnostic.
    SUMMARY_MAX = Hive::DiagnosticHelpers::SUMMARY_MAX
    TAIL_BYTES = Hive::DiagnosticHelpers::TAIL_BYTES
    LOG_GLOB_CAP = Hive::DiagnosticHelpers::LOG_GLOB_CAP
    FRONTMATTER_SCAN_BYTES = Hive::DiagnosticHelpers::FRONTMATTER_SCAN_BYTES
    STATE_FILE_NAMES = %w[brainstorm.md plan.md task.md pr.md artifacts.md idea.md notes.md].freeze

    # Human-facing prefix per evidence tier. Shared by the CLI detail line and
    # the bot reply so the two surfaces label a tier identically.
    SOURCE_LABELS = { red_status: "Diagnostics", log: "Log", marker: "Marker" }.freeze

    module_function

    def source_label(kind)
      SOURCE_LABELS.fetch(kind, "Source")
    end

    # `state_file` is the caller's authoritative task state file (the bot only
    # has the folder string, so it stays nil there). When supplied it pins the
    # marker tier's source_path and marker, so the marker-tier summary,
    # source_path, and the caller's marker_signature all describe the same file
    # rather than whatever `marker_state_file` happens to glob first.
    def summarize(folder:, marker_summary: nil, state_file: nil)
      root = folder.to_s
      return nil if root.strip.empty? || !File.directory?(root)

      red_status = red_status_summary(root)
      return red_status if red_status

      authoritative = present(state_file)
      resolved_state_file = authoritative || marker_state_file(root)
      marker_text = present(marker_summary) || marker_summary_from_state_file(resolved_state_file)
      log = latest_log_summary(root, marker_text)
      return log if log
      return nil unless resolved_state_file && marker_text

      summary_payload([ marker_text ], resolved_state_file, :marker)
    rescue StandardError => e
      # Never crash a reply (plan R-4): the CLI re-wraps a raise as exit 70 and
      # the bot's reap loop has no per-child rescue. Surface a breadcrumb, but
      # degrade to nil so the caller falls back to its try-again copy.
      warn "hive: diagnose-evidence: summarize degraded for #{root} (#{e.class}: #{e.message})"
      nil
    end

    def red_status_summary(folder)
      path = File.join(folder, "diagnostics", "red-status.md")
      return nil unless File.file?(path)
      return nil unless contained?(path, folder)

      text = red_status_frontmatter_summary(path) || red_status_body_summary(path)
      return nil unless text

      summary_payload([ text ], path, :red_status)
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
        next unless contained?(path, folder)

        line = last_meaningful_line(path)
        next unless line

        return summary_payload([ marker_text, line ], path, :log)
      end
      nil
    end

    def log_candidates(folder)
      candidates = log_dirs(folder).flat_map { |dir| Dir[File.join(dir, "*.log")] }
      return [] if candidates.empty?

      candidates.sort.last(LOG_GLOB_CAP)
                .sort_by { |path| safe_mtime(path) || Time.at(0) }
                .reverse
    rescue SystemCallError => e
      # Dir[] returns [] for a missing dir (never ENOENT) and safe_mtime swallows
      # its own faults, so anything reaching here (EIO/EACCES on the glob) is a
      # real fault worth a breadcrumb, not a benign empty result.
      warn "hive: diagnose-evidence: log glob failed under #{folder} (#{e.class}: #{e.message})"
      []
    end

    def log_dirs(folder)
      [ inferred_task_log_dir(folder), File.join(folder, "logs") ].compact.uniq
    end

    # The global per-task log dir is `<root>/.hive-state/logs/<slug>`. Rather
    # than hand-roll that layout literal (which the stage-literal guard exists
    # to prevent), reuse the canonical Hive::Task::PATH_RE — the same regex
    # Hive::Task#log_dir derives the path from — so if the layout ever moves
    # this resolver follows instead of silently probing the old location. The
    # require is lazy because the bot/CLI only hand this module a folder string,
    # not a Hive::Task, and we don't want a load-time dependency on Task.
    def inferred_task_log_dir(folder)
      require "hive/task"
      match = Hive::Task::PATH_RE.match(folder.to_s)
      return nil unless match

      File.join(match[:root], match[:state_dir], "logs", match[:slug])
    end

    def marker_state_file(folder)
      state_file_candidates(folder).find do |path|
        next false unless contained?(path, folder)

        marker = current_marker(path)
        marker && !marker.none?
      end
    end

    def state_file_candidates(folder)
      known = STATE_FILE_NAMES.map { |name| File.join(folder, name) }
      (known + Dir[File.join(folder, "*.md")].sort).uniq
    rescue SystemCallError => e
      # As in log_candidates: Dir[] never raises ENOENT, so a SystemCallError
      # here is a real I/O fault that should leave a breadcrumb.
      warn "hive: diagnose-evidence: state-file glob failed under #{folder} (#{e.class}: #{e.message})"
      []
    end

    def marker_summary_from_state_file(path)
      marker = current_marker(path)
      return nil unless marker

      Hive::Markers.summary(marker)
    end

    def current_marker(path)
      return nil if path.to_s.empty?

      marker = Hive::Markers.current(path)
      marker.none? ? nil : marker
    rescue SystemCallError => e
      # A real, readable-but-unreadable state file (EISDIR/EACCES, or a rare
      # TOCTOU ENOENT after Markers.current's File.exist? guard) must not vanish
      # silently; leave a breadcrumb and degrade to "no marker". Markers.current
      # guards File.exist?, so a plain missing file returns :none without raising
      # — there is no separate benign-ENOENT clause to split off here.
      warn "hive: diagnose-evidence: cannot read marker at #{path} (#{e.class}: #{e.message})"
      nil
    rescue ArgumentError
      # Markers.current reads with encoding: "UTF-8", which tags (not
      # transcodes) the bytes; an invalid UTF-8 sequence then makes the internal
      # `scan` raise ArgumentError ("invalid byte sequence in UTF-8"). Treat a
      # malformed state file as "no marker" rather than crash. (EncodingError is
      # not rescued: tagging never raises it here, so the old rescue was dead.)
      nil
    end

    def last_meaningful_line(path)
      Hive::DiagnosticHelpers.tail_file(path).lines.reverse_each do |line|
        stripped = line.strip
        return stripped unless stripped.empty?
      end
      nil
    rescue Errno::ENOENT
      nil
    rescue SystemCallError, IOError => e
      warn "hive: diagnose-evidence: cannot read log tail at #{path} (#{e.class}: #{e.message})"
      nil
    end

    def safe_read_head(path)
      raw = File.open(path, "rb") { |file| file.read(FRONTMATTER_SCAN_BYTES).to_s }
      utf8(raw)
    rescue Errno::ENOENT
      ""
    rescue SystemCallError, IOError => e
      warn "hive: diagnose-evidence: cannot read head of #{path} (#{e.class}: #{e.message})"
      ""
    end

    def safe_mtime(path) = Hive::DiagnosticHelpers.safe_mtime(path)

    # Symlink-escape guard, mirroring Hive::TaskAction::Diagnostic's
    # safe_diagnostic_artifact?. A `*.log`, `*.md`, or red-status.md symlink
    # under the task folder or its log dirs could otherwise point at an
    # arbitrary readable host file and leak it through CLI JSON or the Telegram
    # fallback. Require the realpath to sit inside one of the (also realpath'd)
    # evidence roots before any read.
    def contained?(path, folder)
      real = File.realpath(path)
      evidence_roots(folder).any? { |root| path_inside?(real, root) }
    rescue Errno::ENOENT
      false
    rescue SystemCallError => e
      warn "hive: diagnose-evidence: cannot realpath #{path} (#{e.class}: #{e.message}); skipping"
      false
    end

    def evidence_roots(folder)
      ([ folder ] + log_dirs(folder)).filter_map { |root| realpath_or_expand(root) }.uniq
    end

    def realpath_or_expand(path)
      return nil if path.nil? || path.to_s.empty?

      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    def path_inside?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end

    def summary_payload(parts, source_path, kind)
      summary = parts.compact.map { |part| one_line(part) }.reject(&:empty?).join(": ")
      summary = Hive::DiagnosticHelpers.truncate(Hive::SecretPatterns.redact(summary), SUMMARY_MAX)
      { summary: summary, source_path: source_path, kind: kind }
    end

    def present(value)
      text = one_line(value)
      text.empty? ? nil : text
    end

    def one_line(value)
      utf8(value.to_s).gsub(/\s+/, " ").strip
    end

    def utf8(value)
      Hive::DiagnosticHelpers.utf8(value)
    end
  end
end
