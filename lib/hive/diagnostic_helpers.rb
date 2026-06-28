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
  end
end
