module Hive
  # Input-agnostic size caps and text/IO helpers shared by the two diagnose
  # surfaces: Hive::TaskAction::Diagnostic (the red-status producer) and
  # Hive::DiagnosticEvidence (the on-disk fallback resolver). Lifting these into
  # one home keeps SUMMARY_MAX coupled to the schema's `maxLength: 120` in a
  # single place so the two surfaces can never truncate differently, and gives
  # the boundary-safe `tail_file` exactly one implementation (plan R-5). Both
  # consumers reference these constants and methods rather than re-declaring
  # them.
  module DiagnosticHelpers
    # Coupled to hive-status-diagnose.v2 `Diagnostic.summary.maxLength`.
    SUMMARY_MAX = 120
    TAIL_BYTES = 8_192
    LOG_GLOB_CAP = 20
    FRONTMATTER_SCAN_BYTES = 16_384

    module_function

    # Read the last TAIL_BYTES of a file as UTF-8 (invalid bytes replaced).
    # When the file is larger than TAIL_BYTES the read starts mid-file, so the
    # first line of the returned text is a partial fragment whose leading bytes
    # were chopped. SecretPatterns is prefix-anchored (`sk-`, `AKIA`,
    # `Authorization: Bearer`, PEM headers), so a credential whose identifying
    # prefix landed just before the seek boundary would survive redaction and
    # leak its trailing portion. We therefore drop that partial first line
    # before returning, so neither the log-tail summary nor the artifact detail
    # can surface a boundary-split secret (plan R-6 redaction intent). Raises
    # SystemCallError/IOError on read failure; callers degrade.
    def tail_file(path)
      partial = false
      raw = File.open(path, "rb") do |file|
        begin
          file.seek(-TAIL_BYTES, IO::SEEK_END)
          partial = file.pos.positive?
        rescue Errno::EINVAL
          file.rewind
        end
        file.read.to_s
      end
      text = utf8(raw)
      partial ? drop_first_line(text) : text
    end

    # Drop everything up to and including the first newline. When the buffer is
    # a single partial line with no newline (a log line longer than TAIL_BYTES),
    # the whole fragment is dropped — surfacing a partial line is never safe.
    def drop_first_line(text)
      newline = text.index("\n")
      newline ? text[(newline + 1)..].to_s : ""
    end

    def safe_mtime(path)
      return nil if path.nil? || path.to_s.empty?

      File.mtime(path)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      # A real-but-unstattable evidence file (EACCES/EIO/ELOOP) must not be
      # silently stamped as just-generated; surface a breadcrumb but still
      # degrade to nil so callers fall back rather than crash.
      warn "hive: diagnostic: cannot stat #{path} (#{e.class}: #{e.message})"
      nil
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0, max - 1]}…"
    end

    def utf8(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    end

    # Resolve an evidence root to its realpath for the symlink-escape
    # containment check shared by both diagnose surfaces
    # (Hive::TaskAction::Diagnostic#diagnostic_roots and
    # Hive::DiagnosticEvidence#evidence_roots). One implementation so the
    # security-relevant guard can't drift and leave one surface exploitable
    # (plan R-5).
    #
    # `trust_anchor:` distinguishes the task folder from the subdirectory
    # evidence roots:
    #   * The task folder IS the trust anchor — realpath it UNCONDITIONALLY.
    #     Task uses File.expand_path, which does not resolve symlinks, so an
    #     operator-symlinked task folder (or a `.hive-state -> /vol` ancestor)
    #     must still resolve to its real location rather than being dropped
    #     from the trusted roots — dropping it silently discards every artifact
    #     under that folder.
    #   * The logs/ subdir roots are NOT trust anchors — reject one whose own
    #     leaf is a symlink, so a `logs -> /outside` dir symlink can't resolve
    #     into the trusted set and let containment approve every file under the
    #     link target. A symlinked *ancestor* still resolves normally because
    #     File.symlink? checks only the leaf.
    def evidence_root_realpath(path, trust_anchor:)
      return nil if path.nil? || path.to_s.empty?
      return nil if !trust_anchor && File.symlink?(path)

      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    def path_inside?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end
  end
end
