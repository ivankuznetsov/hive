require "securerandom"
require "hive/attempts/context"
require "hive/recovery"

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

    INTERNAL_ATTR_KEYS = %w[
      marker_id attempt_id task_generation ownership_generation task_input_epoch
    ].freeze

    State = Struct.new(:name, :attrs, :raw, keyword_init: true) do
      def none?
        name == :none
      end
    end

    module_function

    def current(state_file_path)
      return State.new(name: :none, attrs: {}, raw: nil) unless File.exist?(state_file_path)

      current_from_content(File.binread(state_file_path))
    end

    def current_from_content(content)
      last = nil
      # Agent-authored artifacts are not trusted to be valid UTF-8. Marker
      # syntax is ASCII, so scan a binary view: an invalid certificate can
      # still expose its trailing COMPLETE marker to the bounded terminal
      # outcome classifier instead of crashing before normalization.
      binary_content = content.to_s
      binary_content = binary_content.b unless binary_content.encoding == Encoding::BINARY
      binary_content.scan(MARKER_RE) do
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

    # One-off recovery migration compare-and-swap. The caller supplies the
    # exact id-less marker it observed; after taking the same sidecar lock used
    # by every marker writer, we re-read and upgrade only if that exact marker
    # is still current. A concurrent agent/operator write therefore wins
    # instead of being overwritten by a stale migration read.
    def upgrade_recovery_marker_id(state_file_path, observed:)
      with_markers_lock(state_file_path) do
        current_marker = current(state_file_path)
        return false unless current_marker.raw == observed&.raw
        return false unless Hive::Recovery.recoverable_marker?(current_marker.name)
        return false unless current_marker.attrs["marker_id"].to_s.empty?

        marker_name = current_marker.name.to_s.upcase
        attrs = attrs_with_recovery_marker_id(marker_name, current_marker.attrs)
        new_marker = build_marker(marker_name, attrs)
        body = File.read(state_file_path, encoding: "UTF-8")
        replaced, count = replace_last_marker(body, new_marker)
        return false unless count == 1

        write_atomic(state_file_path, replaced)
        true
      end
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

    # Return the exact body that `clear_current(..., purge_history: true)`
    # would persist. Recovery code uses this before the clear to derive the
    # post-clear durable attempt generation, so a queued continuation can be
    # bound to the artifact it will actually execute without creating a
    # markerless crash window first.
    def without_markers(body)
      body.to_s.b.gsub(MARKER_RE, "")
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
      # Preserve the artifact byte-for-byte around the marker. An opted-in
      # terminal classifier may need to replace COMPLETE with ERROR precisely
      # because the producer wrote invalid UTF-8; transcoding here would make
      # that fail-closed normalization impossible.
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |f|
        f.binmode
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
      needs_id = marker_name == "REVIEW_WORKING" ||
                 Hive::Recovery.recoverable_marker?(marker_name)
      return attrs unless needs_id
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

    def recovery_match_attr(attrs)
      attrs = attrs ? attrs.to_h.transform_keys(&:to_s) : {}
      marker_id = attrs["marker_id"].to_s
      reason = attrs["reason"].to_s
      # When a `marker_id` is present, callers want it as the primary
      # `--match-attr` guard so race-y recoveries can't clear a newer
      # marker by accident. Keep `reason` as a secondary assertion and audit
      # breadcrumb. `AlertStore.parse_match_attr` continues to use the leading
      # marker_id token as its canonical alert-generation guard.
      return nil if marker_id.empty?
      return "marker_id=#{marker_id}" if reason.empty?

      "marker_id=#{marker_id},reason=#{reason}"
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
      binary_body = body.to_s.b
      matches = binary_body.to_enum(:scan, MARKER_RE).map { Regexp.last_match }
      return [ body, 0 ] if matches.empty?

      last = matches.last
      [ binary_body[0...last.begin(0)] + new_marker.b + binary_body[last.end(0)..], 1 ]
    end

    def remove_marker(state_file_path, raw_marker)
      return unless File.exist?(state_file_path)
      return if raw_marker.to_s.empty?

      body = File.binread(state_file_path)
      marker = raw_marker.to_s.b
      offset = body.index(marker)
      return unless offset

      suffix = offset + marker.bytesize
      suffix += 1 if body.getbyte(suffix) == 10
      cleaned = body.byteslice(0, offset).to_s + body.byteslice(suffix..).to_s
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
      write_atomic(state_file_path, without_markers(body))
    end
  end
end
