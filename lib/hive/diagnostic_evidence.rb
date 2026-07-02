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
  # Contract: summarize must not raise and must not block — it degrades to nil
  # (or a best-effort lower tier) on failure, because the CLI re-wraps a raise
  # as InternalError (exit 70) and the bot's reaper has no per-child rescue, so
  # a raise OR a blocking open(2) there drops every other child's reply.
  # `summarize` rescues StandardError at the boundary; the non-StandardError
  # vectors are closed at their sources instead: the lazy `require "hive/task"`
  # rescues LoadError, the evidence reads are byte-bounded so an oversized file
  # can't raise NoMemoryError, and every tier gates on File.file? (via
  # `contained?`) so a FIFO / device / directory named like evidence can't
  # wedge a blocking read.
  module DiagnosticEvidence
    # Aliased to the single shared source, Hive::DiagnosticHelpers — only
    # SUMMARY_MAX is additionally schema-pinned (to hive-status-diagnose.v2
    # `summary.maxLength`); LOG_GLOB_CAP and FRONTMATTER_SCAN_BYTES are not.
    # Aliasing keeps the two diagnose surfaces from drifting on these caps.
    # (TAIL_BYTES is intentionally NOT aliased: every tail read goes through
    # Hive::DiagnosticHelpers.tail_file, which uses the helper's own constant,
    # so a local alias would be dead.)
    SUMMARY_MAX = Hive::DiagnosticHelpers::SUMMARY_MAX
    LOG_GLOB_CAP = Hive::DiagnosticHelpers::LOG_GLOB_CAP
    FRONTMATTER_SCAN_BYTES = Hive::DiagnosticHelpers::FRONTMATTER_SCAN_BYTES

    # Cap on the marker-tier read. Markers live at a state file's tail and a
    # real hive state file is a few KB, so a candidate above this is junk (e.g.
    # a multi-MB artifacts.md the bot glob swept up): skip it rather than slurp
    # it whole on the no-timeout reaper thread, where an oversized read could
    # also raise NoMemoryError and escape the never-raise rescue.
    MARKER_READ_MAX = 1 << 20

    # How each evidence kind renders across the two diagnose surfaces: the
    # schema `source` enum value and the human-facing detail-line label. One
    # `.fetch`-ed table (no default) so a future kind that isn't mapped raises
    # loudly here instead of silently shipping source:"artifact"/label:"Source".
    KIND_RENDERING = {
      red_status: { source: "artifact", label: "Diagnostics" },
      log: { source: "artifact", label: "Log" },
      marker: { source: "marker", label: "Marker" }
    }.freeze

    module_function

    def source_label(kind)
      KIND_RENDERING.fetch(kind).fetch(:label)
    end

    def source_kind(kind)
      KIND_RENDERING.fetch(kind).fetch(:source)
    end

    # `state_file` is the caller's authoritative task state file. Older bot
    # envelopes predate the field and pass nil; current callers (the CLI and
    # the bot reaper, via the envelope `state_file` field) pass an authoritative
    # state file. When supplied it pins the marker tier's source_path and marker,
    # so the marker-tier summary, source_path, and the caller's marker_signature
    # all describe the same file rather than whatever `marker_state_file` happens
    # to glob first.
    def summarize(folder:, marker_summary: nil, state_file: nil)
      root = folder.to_s
      return nil if root.strip.empty? || !File.directory?(root)

      red_status = red_status_summary(root)
      return red_status if red_status

      authoritative = present_path(state_file)
      resolved_state_file = authoritative || marker_state_file(root)
      marker_text = present(marker_summary) || marker_summary_from_state_file(resolved_state_file)
      log = latest_log_summary(root, marker_text)
      return log if log
      return nil unless resolved_state_file && marker_text

      summary_payload([ marker_text ], resolved_state_file, :marker)
    rescue StandardError, SystemStackError, NoMemoryError => e
      # Never crash a reply (plan R-4): the CLI re-wraps a raise as exit 70 and
      # the bot's reap loop has no per-child rescue. SystemStackError and
      # NoMemoryError are NOT StandardError (deeply-nested frontmatter YAML can
      # raise the former on the no-timeout reaper thread), so catch them
      # explicitly here too. Surface a breadcrumb, but degrade to nil so the
      # caller falls back to its try-again copy.
      breadcrumb("summarize degraded for #{root} (#{e.class}: #{e.message})")
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
    rescue Psych::Exception, SystemStackError, NoMemoryError
      # YAML.safe_load on deeply-nested flow YAML (well inside the 16 KB scan
      # window) raises SystemStackError, NOT a Psych::Exception or any
      # StandardError — so it would escape both this rescue and summarize's
      # boundary and kill the no-timeout bot reaper thread. Catch it (and the
      # sibling NoMemoryError) at the parse site so a hostile red-status.md
      # degrades to "no frontmatter summary" instead.
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

      # Sort by mtime FIRST, then cap, so the newest log by mtime is always
      # considered even when its filename sorts earlier than an older log's
      # (plan R2 requires newest-log evidence). The diagnose read path runs
      # once per task on demand, so stat'ing every candidate is acceptable —
      # unlike Diagnostic#latest_log_artifacts, which caps by filename first to
      # avoid an O(N) stat sweep on every status poll.
      candidates.sort_by { |path| safe_mtime(path) || Time.at(0) }
                .last(LOG_GLOB_CAP)
                .reverse
    rescue SystemCallError => e
      # Dir[] returns [] for a missing dir (never ENOENT) and safe_mtime swallows
      # its own faults, so anything reaching here (EIO/EACCES on the glob) is a
      # real fault worth a breadcrumb, not a benign empty result.
      breadcrumb("log glob failed under #{folder} (#{e.class}: #{e.message})")
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
    rescue LoadError => e
      # `require` failure is a ScriptError, not a StandardError, so it would
      # escape summarize's StandardError boundary and (on the bot reaper) drop
      # sibling replies. Degrade this tier to nil instead. Unreachable in
      # production today (both entry points eager-require hive/task), but a cold
      # caller must not be able to reintroduce the escape.
      breadcrumb("cannot load hive/task (#{e.message}); skipping inferred log dir")
      nil
    end

    def marker_state_file(folder)
      state_file_candidates(folder).find do |path|
        next false unless contained?(path, folder)

        # current_marker already normalizes :none → nil, so a truthy return is
        # a real marker.
        current_marker(path)
      end
    end

    def state_file_candidates(folder)
      known = state_file_names.map { |name| File.join(folder, name) }
      (known + Dir[File.join(folder, "*.md")].sort).uniq
    rescue SystemCallError => e
      # As in log_candidates: Dir[] never raises ENOENT, so a SystemCallError
      # here is a real I/O fault that should leave a breadcrumb.
      breadcrumb("state-file glob failed under #{folder} (#{e.class}: #{e.message})")
      []
    end

    # Priority hint for the marker tier: try the canonical workflow state-file
    # names before the `*.md` glob fallback so the marker that matters is found
    # first. Derived from Hive::Task::STATE_FILES.values rather than a
    # hand-maintained literal — the old literal had already drifted
    # (`artifacts.md` plural never matched the coding `artifact.md`, `notes.md`
    # matched no workflow). The require is lazy and LoadError-guarded, exactly
    # like inferred_task_log_dir: the bot/CLI hand this module a folder string,
    # not a Hive::Task, and a require failure (a ScriptError, not a
    # StandardError) must degrade to the glob fallback rather than escape
    # summarize's StandardError boundary.
    def state_file_names
      require "hive/task"
      Hive::Task::STATE_FILES.values.uniq
    rescue LoadError => e
      breadcrumb("cannot load hive/task (#{e.message}); using *.md glob fallback only")
      []
    end

    def marker_summary_from_state_file(path)
      marker = current_marker(path)
      return nil unless marker

      Hive::Markers.summary(marker)
    end

    def current_marker(path)
      return nil if path.to_s.empty?
      # Never-block gate: the caller-supplied authoritative state_file reaches
      # here via marker_summary_from_state_file WITHOUT passing through
      # contained?, so this is the only regular-file gate on that path. A FIFO /
      # char-device at `path` would otherwise make Hive::Markers.current's
      # File.read block forever on the no-timeout reaper thread
      # (File.size(fifo)==0 sails past marker_file_oversized?). Reject any
      # non-regular file before any read.
      return nil unless regular_marker_file?(path)
      return nil if marker_file_oversized?(path)

      marker = Hive::Markers.current(path)
      marker.none? ? nil : marker
    rescue SystemCallError => e
      # A real, readable-but-unreadable state file (EACCES, or a rare TOCTOU
      # ENOENT after Markers.current's File.exist? guard) must not vanish
      # silently; leave a breadcrumb and degrade to "no marker". Markers.current
      # guards File.exist?, so a plain missing file returns :none without raising
      # — there is no separate benign-ENOENT clause to split off here.
      breadcrumb("cannot read marker at #{path} (#{e.class}: #{e.message})")
      nil
    rescue ArgumentError => e
      # Markers.current reads with encoding: "UTF-8", which tags (not
      # transcodes) the bytes; an invalid UTF-8 sequence then makes the internal
      # `scan` raise ArgumentError ("invalid byte sequence in UTF-8"). Treat a
      # malformed state file as "no marker" rather than crash — but leave a
      # breadcrumb (matching the SystemCallError branch) so a corrupt-encoding
      # state file doesn't drop out of the evidence with zero signal.
      breadcrumb("cannot parse marker at #{path} (#{e.class}: #{e.message})")
      nil
    end

    # File.file? follows symlinks and is false for a FIFO / char-device /
    # directory, so it is the regular-file gate the marker read needs. A
    # present-but-irregular path leaves a breadcrumb (preserving the prior
    # EISDIR-on-directory signal); a genuinely missing path stays silent
    # (Markers.current treats absence as :none). Both checks are non-blocking
    # stats, so the gate itself can never wedge on a FIFO.
    def regular_marker_file?(path)
      return true if File.file?(path)

      breadcrumb("cannot read marker at #{path} (not a regular file); skipping") if File.exist?(path)
      false
    end

    # Markers live at a state file's tail and a real one is a few KB, so a
    # candidate above MARKER_READ_MAX is junk (a multi-MB artifacts.md the bot
    # glob swept up). Skip it rather than slurp it whole: the marker read is
    # otherwise unbounded — asymmetric with the byte-capped red (16 KB) and log
    # (8 KB) tiers — and an oversized read on the no-timeout reaper thread could
    # raise NoMemoryError straight through the never-raise rescue.
    def marker_file_oversized?(path)
      size = File.size(path)
      return false unless size > MARKER_READ_MAX

      breadcrumb("state file #{path} is #{size}B (> #{MARKER_READ_MAX}B); skipping marker read")
      true
    rescue SystemCallError
      # Let the read attempt and its own rescue handle a stat fault; don't make
      # the size probe a second silent failure point.
      false
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
      breadcrumb("cannot read log tail at #{path} (#{e.class}: #{e.message})")
      nil
    end

    def safe_read_head(path)
      raw = File.open(path, "rb") { |file| file.read(FRONTMATTER_SCAN_BYTES).to_s }
      utf8(raw)
    rescue Errno::ENOENT
      ""
    rescue SystemCallError, IOError => e
      breadcrumb("cannot read head of #{path} (#{e.class}: #{e.message})")
      ""
    end

    def safe_mtime(path) = Hive::DiagnosticHelpers.safe_mtime(path)

    # Symlink-escape + regular-file guard, mirroring Hive::TaskAction::
    # Diagnostic's safe_diagnostic_artifact?. Two distinct hazards:
    #   * A `*.log` / `*.md` / red-status.md *file* symlink could point at an
    #     arbitrary readable host file; require the realpath to sit inside one
    #     of the (also realpath'd) evidence roots — and evidence_roots itself
    #     rejects an evidence *directory* that is a symlink, so a `logs ->
    #     /outside` dir symlink can't smuggle its target in as a trusted root.
    #   * A FIFO / socket / device / directory named like evidence would make
    #     the subsequent open(2) block or read unbounded (the never-block hazard
    #     the red tier already guarded with File.file?); gate on File.file? so
    #     the log and marker tiers reject non-regular files before any read.
    # realpath runs first so a symlink loop still surfaces its ELOOP breadcrumb;
    # File.file? then runs on the resolved path (FIFO/dir → false, no open).
    def contained?(path, folder)
      real = File.realpath(path)
      return false unless File.file?(real)

      evidence_roots(folder).any? { |root| Hive::DiagnosticHelpers.path_inside?(real, root) }
    rescue Errno::ENOENT
      false
    rescue SystemCallError => e
      breadcrumb("cannot realpath #{path} (#{e.class}: #{e.message}); skipping")
      false
    end

    # The task folder is the trust ANCHOR (realpath'd even when it is itself a
    # symlink — Task uses File.expand_path, which doesn't resolve symlinks, so
    # an operator-symlinked task folder must not be dropped from the trusted
    # set); the logs/ subdir roots reject a symlinked leaf so a `logs ->
    # /outside` dir symlink can't smuggle its target in as a trusted root. Both
    # rules live in Hive::DiagnosticHelpers.evidence_root_realpath so this
    # surface and the red-status producer can't drift (plan R-5).
    def evidence_roots(folder)
      roots = [ Hive::DiagnosticHelpers.evidence_root_realpath(folder, trust_anchor: true) ]
      roots.concat(
        log_dirs(folder).map { |dir| Hive::DiagnosticHelpers.evidence_root_realpath(dir, trust_anchor: false) }
      )
      roots.compact.uniq
    end

    def summary_payload(parts, source_path, kind)
      # Validate kind INSIDE the never-raise boundary: KIND_RENDERING is only
      # consulted later by the consumer render helpers (source_label/source_kind),
      # OUTSIDE summarize's rescue. A future tier minting an unmapped kind would
      # otherwise raise KeyError in exactly the reaper context the contract
      # protects; raising ArgumentError here degrades it to nil within the rescue.
      raise ArgumentError, "unknown evidence kind #{kind.inspect}" unless KIND_RENDERING.key?(kind)

      summary = parts.compact.map { |part| one_line(part) }.reject(&:empty?).join(": ")
      summary = Hive::DiagnosticHelpers.truncate(Hive::SecretPatterns.redact(summary), SUMMARY_MAX)
      { summary: summary, source_path: source_path, kind: kind }
    end

    def present(value)
      text = one_line(value)
      text.empty? ? nil : text
    end

    # Blank-check a filesystem path WITHOUT the display normaliser one_line
    # applies — a project root containing a tab or a run of spaces must reach
    # the marker read and the emitted source_path verbatim, not whitespace-
    # collapsed. present() stays reserved for display strings.
    def present_path(value)
      value unless value.to_s.strip.empty?
    end

    def one_line(value)
      utf8(value.to_s).gsub(/\s+/, " ").strip
    end

    def utf8(value)
      Hive::DiagnosticHelpers.utf8(value)
    end

    # Single spelling of the "hive: diagnose-evidence: " breadcrumb prefix so
    # the ~10 degrade sites can't drift on it; each passes its own per-site
    # message verbatim.
    def breadcrumb(message)
      warn "hive: diagnose-evidence: #{message}"
    end

    # The module's intended public surface is summarize (mint a result) plus the
    # two render helpers the CLI/bot label tiers with. Everything else is
    # internal: keep it private so an external caller can't invoke e.g.
    # summary_payload to mint a result that bypasses the redact/truncate +
    # closed-`kind` invariants.
    private_class_method :red_status_summary, :red_status_frontmatter_summary,
                         :red_status_body_summary, :latest_log_summary, :log_candidates,
                         :log_dirs, :inferred_task_log_dir, :marker_state_file,
                         :state_file_candidates, :state_file_names,
                         :marker_summary_from_state_file,
                         :current_marker, :regular_marker_file?, :marker_file_oversized?,
                         :last_meaningful_line, :safe_read_head, :safe_mtime, :contained?,
                         :evidence_roots, :summary_payload,
                         :present, :present_path, :one_line, :utf8, :breadcrumb
  end
end
