require "securerandom"
require "hive/attempts/context"

module Hive
  module Markers
    # Marker names live in two places: this list (validates writes via
    # Markers.set) and the MARKER_RE alternation (parses reads via
    # Markers.current). Both must list the same names — adding to one
    # without the other causes silent parse failures.
    #
    # REVIEW_* markers (added in U3) carry the 6-review stage's state
    # machine. REVIEW_WORKING is transient (set at phase entry, replaced
    # at phase exit by writing the next marker per ADR-005's last-marker-
    # wins rule). REVIEW_WAITING / REVIEW_CI_STALE / REVIEW_STALE /
    # REVIEW_COMPLETE / REVIEW_ERROR are terminal — the orchestrator
    # owns the terminal marker and the runner returns until the next
    # `hive run` re-evaluates.
    KNOWN_NAMES = %w[
      WAITING COMPLETE AGENT_WORKING ERROR
      MANUAL_STEERING
      EXECUTE_WAITING EXECUTE_COMPLETE EXECUTE_STALE
      REVIEW_WORKING REVIEW_WAITING REVIEW_CI_STALE
      REVIEW_STALE REVIEW_COMPLETE REVIEW_ERROR
    ].freeze
    MARKER_RE = /<!--\s*(?<name>WAITING|COMPLETE|AGENT_WORKING|ERROR|MANUAL_STEERING|EXECUTE_WAITING|EXECUTE_COMPLETE|EXECUTE_STALE|REVIEW_WORKING|REVIEW_WAITING|REVIEW_CI_STALE|REVIEW_STALE|REVIEW_COMPLETE|REVIEW_ERROR)(?=\s|-->)(?<attrs>(?:(?!<!--).)*?)\s*-->/m
    # Markers whose presence means "this stage is done; the next verb
    # may advance the task". Single source of truth — previously this
    # list was duplicated across `Hive::Commands::StageAction#terminal_marker?`,
    # `Hive::Commands::Run#json_next_action`, and the TUI's `TaskAction`
    # classifier; the `:review_complete` whitelist gap that produced the
    # U10/U11-era "Ready for PR row dispatches WrongStage" bug was a
    # drift between two of these copies. Add a marker here and every
    # consumer picks it up.
    TERMINAL_MARKER_NAMES = %i[complete execute_complete review_complete].freeze

    # POSIX exit codes produced by signal kills (130 = SIGINT, 137 =
    # SIGKILL, 143 = SIGTERM). Only ERROR markers shaped as
    # `reason=exit_code exit_code=<kill-class>` are treated as
    # interrupted, not "broken" — the file-system state is intact and
    # the marker is stale. The numeric list is shared by
    # `Hive::Tui::BubbleModel#auto_heal_kill_class_errors` (background
    # heal that clears those explicit signal-kill markers) and
    # `Hive::Tui::KeyMap.error_message` (routes Enter on those rows to
    # OpenLogTail rather than RecoverError so Enter doesn't race the
    # auto-healer for the same markers-lock). Adding a new kill-class
    # code here updates both consumers; previously each module had its
    # own private copy and would drift on edit.
    KILL_CLASS_EXIT_CODES = %w[130 137 143].freeze
    INTERNAL_ATTR_KEYS = %w[marker_id attempt_id task_generation ownership_generation].freeze

    State = Struct.new(:name, :attrs, :raw, keyword_init: true) do
      def none?
        name == :none
      end
    end

    module_function

    def current(state_file_path)
      return State.new(name: :none, attrs: {}, raw: nil) unless File.exist?(state_file_path)

      content = File.read(state_file_path, encoding: "UTF-8")
      last = nil
      content.scan(MARKER_RE) do
        match = Regexp.last_match
        last = match
      end
      return State.new(name: :none, attrs: {}, raw: nil) unless last

      State.new(
        name: last[:name].downcase.to_sym,
        attrs: parse_attrs(last[:attrs]),
        raw: last[0]
      )
    end

    # Atomic update: write to a sibling tempfile then File.rename. A torn
    # write (ENOSPC, crash mid-write) leaves the original state file intact.
    # The lock file (a sidecar) serialises concurrent writers; the data file
    # itself is replaced atomically.
    def set(state_file_path, name, attrs = {})
      marker_name = name.to_s.upcase
      raise ArgumentError, "unknown marker #{marker_name}" unless KNOWN_NAMES.include?(marker_name)

      attrs = attrs_with_recovery_marker_id(marker_name, attrs)
              .to_h
              .merge(Hive::Attempts::Context.projection)
      new_marker = build_marker(marker_name, attrs)
      ensure_dir(state_file_path)
      with_markers_lock(state_file_path) do
        body = File.exist?(state_file_path) ? File.read(state_file_path, encoding: "UTF-8") : ""
        replaced, count = replace_last_marker(body, new_marker)
        body = if count.positive?
                 replaced
        else
                 separator = body.empty? || body.end_with?("\n") ? "" : "\n"
                 "#{body}#{separator}#{new_marker}\n"
        end
        write_atomic(state_file_path, body)
      end
      new_marker
    end

    def clear_current(state_file_path, expected_name:, match_attrs: {}, purge_history: false)
      with_markers_lock(state_file_path) do
        marker = current(state_file_path)
        return false unless marker.name.to_s == expected_name.to_s.downcase

        expected = match_attrs.to_h.transform_keys(&:to_s)
        return false unless expected.all? { |key, value| marker.attrs[key].to_s == value.to_s }

        if purge_history
          remove_all_markers(state_file_path)
        else
          remove_marker(state_file_path, marker.raw)
        end
        true
      end
    end

    # Serialize concurrent state-file writers via a sidecar `.markers-lock`
    # flock'd exclusively. Public so `hive markers clear` can wrap its own
    # read+match+rewrite under the same lock that `set` uses — without
    # this, `clear` reads the body, validates the marker, then rereads
    # and rewrites in a separate window during which a concurrent
    # `Markers.set` can land a fresh marker that the rewrite then erases.
    #
    # The lockfile is left on disk after the flock releases. flock
    # semantics are tied to the inode, not the path; deleting the file
    # lets a racing contender create a NEW inode and `flock` it
    # independently while another process is still serializing on the
    # old one — both could enter the critical section. Sticky lockfiles
    # are fine here because they're already gitignored
    # (`.hive-state/stages/*/*/*.markers-lock` in `Hive::GitOps`).
    def with_markers_lock(state_file_path)
      ensure_dir(state_file_path)
      lock_path = "#{state_file_path}.markers-lock"
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write_atomic(path, body)
      dir = File.dirname(path)
      tmp = File.join(dir, ".#{File.basename(path)}.tmp.#{Process.pid}")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o644, encoding: "UTF-8") do |f|
        f.write(body)
        f.flush
        begin
          f.fsync
        rescue StandardError
          nil
        end
      end
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def attrs_with_recovery_marker_id(marker_name, attrs)
      attrs = attrs ? attrs.to_h : {}
      return attrs unless %w[ERROR REVIEW_ERROR REVIEW_WORKING].include?(marker_name)
      return attrs unless attrs["marker_id"].to_s.empty? && attrs[:marker_id].to_s.empty?

      attrs.merge("marker_id" => SecureRandom.hex(8))
    end

    def display_attrs(attrs)
      attrs.to_h.reject { |key, _value| INTERNAL_ATTR_KEYS.include?(key.to_s) }
    end

    # Single-line uppercase marker summary: the marker NAME plus its display
    # attrs rendered as `key=value` pairs. This is the canonical rendering
    # shared by every diagnose surface — `Diagnostic#marker_summary`,
    # `Status#marker_summary`, and `DiagnosticEvidence` — so the bot reply, the
    # envelope's `marker_summary` field, and `diagnostic.summary` can't drift on
    # attr rendering (plan R-5). Returns nil for the :none marker (and a nil
    # marker) so a markerless task yields "no summary" instead of "NONE".
    def summary(marker)
      return nil if marker.nil? || marker.name == :none

      attrs = display_attrs(marker.attrs)
              .map { |key, value| "#{key}=#{value}" }
              .join(" ")
      marker_name = marker.name.to_s.upcase
      attrs.empty? ? marker_name : "#{marker_name} #{attrs}"
    end

    def error_recovery_match_attr(attrs)
      attrs = attrs ? attrs.to_h.transform_keys(&:to_s) : {}
      marker_id = attrs["marker_id"].to_s
      reason = attrs["reason"].to_s
      # When a `marker_id` is present, callers want it as the primary
      # `--match-attr` guard so race-y recoveries can't clear a newer
      # marker by accident. But the inline-button callback path needs
      # the `reason` too — `manual_only?` checks `attrs["reason"]` on
      # the reconstructed attrs hash to route
      # `ensure_clean_on_exit_failed` / `dirty_worktree` into the
      # operator-only reply. Encode both as a comma-separated pair so
      # `RecoverySequence.attrs_from_match_attr` reconstructs both
      # keys, and `Hive::Bot::AlertStore.parse_match_attr` keeps using
      # the leading `marker_id=...` token as the canonical guard.
      if !marker_id.empty?
        return "marker_id=#{marker_id}" if reason.empty?

        return "marker_id=#{marker_id},reason=#{reason}"
      end

      parts = []
      %w[reason exit_code].each do |key|
        value = attrs[key].to_s
        parts << "#{key}=#{value}" unless value.empty?
      end
      parts.empty? ? nil : parts.join(",")
    end

    def build_marker(name, attrs)
      pairs = attrs.compact.map { |k, v| "#{k}=#{format_attr(v)}" }
      pairs.empty? ? "<!-- #{name} -->" : "<!-- #{name} #{pairs.join(' ')} -->"
    end

    def parse_attrs(raw_attrs)
      attrs = {}
      raw_attrs.to_s.scan(/(\w[\w-]*)=("[^"]*"|\S+)/).each do |k, v|
        attrs[k] = v.start_with?('"') ? v[1..-2] : v
      end
      attrs
    end

    # The three gsubs below are boundary escapes, not data transformations.
    # `"` -> `'` keeps the outer attr quoting unambiguous for parse_attrs.
    # `<!--` -> `< !--` and `-->` -> `-- >` prevent attr-value text from
    # being mistaken for a marker boundary by MARKER_RE. The mapping is
    # lossy/one-way; readers may see `< !--` in state files and that is intentional.
    def format_attr(value)
      str = value.to_s.gsub('"', "'").gsub("<!--", "< !--").gsub("-->", "-- >")
      str =~ /\s/ ? "\"#{str}\"" : str
    end

    def ensure_dir(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
    end

    def replace_last_marker(body, new_marker)
      matches = body.to_enum(:scan, MARKER_RE).map { Regexp.last_match }
      return [ body, 0 ] if matches.empty?

      last = matches.last
      [ body[0...last.begin(0)] + new_marker + body[last.end(0)..], 1 ]
    end

    def remove_marker(state_file_path, raw_marker)
      return unless File.exist?(state_file_path)
      return if raw_marker.to_s.empty?

      body = File.read(state_file_path, encoding: "UTF-8")
      cleaned = body.sub(/#{Regexp.escape(raw_marker)}\n?/, "")
      write_atomic(state_file_path, cleaned)
    end

    # Healer-managed retries need a markerless artifact after a guarded clear.
    # Generic state-file agents append their terminal marker after Hive's
    # AGENT_WORKING marker, so repeated runs can leave older working/error
    # markers shadowed below the current terminal marker. Removing only the
    # current marker would expose that stale history as live state and strand
    # redispatch behind another grace/recovery cycle.
    def remove_all_markers(state_file_path)
      return unless File.exist?(state_file_path)

      body = File.read(state_file_path, encoding: "UTF-8")
      write_atomic(state_file_path, body.gsub(MARKER_RE, ""))
    end
  end
end
