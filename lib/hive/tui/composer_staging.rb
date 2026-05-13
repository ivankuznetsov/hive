require "fileutils"
require "securerandom"
require "tmpdir"

require "hive"
require "hive/tui/text"

module Hive
  module Tui
    # Per-session scratch space for image attachments accumulated in
    # the new-idea composer. Files are written to a Process-PID + random
    # suffix tmpdir; the BubbleModel cleans up on submit (success or
    # validation failure) and on Esc/cancel.
    module ComposerStaging
      # Wraps a filesystem failure raised while staging an image.
      # `cause_class` preserves the original Errno class (ENOSPC,
      # EACCES, etc.) so rescue handlers can log a useful operator
      # message without walking `Exception#cause` manually.
      class WriteError < Hive::Error
        attr_reader :cause_class

        def initialize(message, cause_class: nil)
          super(message)
          @cause_class = cause_class
        end
      end

      # Neutral file-name prefix for staged image attachments —
      # composer is not bug-report-specific.
      ATTACHMENT_BASENAME = "image".freeze
      DEFAULT_EXTENSION = "png".freeze

      module_function

      # Returns the absolute staging dir and a Model carrying it. If
      # `model` already pins a non-empty `new_idea_staging_dir`, the
      # input is reused and the returned Model is unchanged (so a
      # caller `model = ComposerStaging.ensure_dir!(model).model`
      # assignment is always safe).
      Result = Data.define(:dir, :model)

      def ensure_dir!(model)
        return Result.new(dir: model.new_idea_staging_dir, model: model) unless model.new_idea_staging_dir.to_s.empty?

        dir = Dir.mktmpdir("hive-tui-composer-#{Process.pid}-#{SecureRandom.hex(4)}-")
        Result.new(dir: dir, model: model.with(new_idea_staging_dir: dir))
      end

      # Build the next placeholder label and absolute disk path for an
      # attachment. `number` is the monotonic 1-indexed sequence id
      # (e.g. the value held on `model.new_idea_attachment_counter` + 1)
      # — callers must increment a never-decrementing counter rather
      # than re-deriving from `attachments.size`, which would collide
      # after a prune.
      def next_label_and_path(staging_dir, number, ext: DEFAULT_EXTENSION)
        n = number.to_i
        clean_ext = normalized_extension(ext)
        [ "image#{n}", File.join(staging_dir, "#{ATTACHMENT_BASENAME}-#{n}.#{clean_ext}") ]
      end

      # Lowercase the extension, strip a leading dot, and fall back to
      # `png` when the input is empty/nil. Centralised so the
      # composer's placeholder builder, the disk basename builder,
      # and the rich-submit caller all share the same fallback.
      def normalized_extension(ext)
        clean = ext.to_s.downcase.delete_prefix(".")
        clean.empty? ? DEFAULT_EXTENSION : clean
      end

      def write_bytes!(abs_path, bytes)
        File.binwrite(abs_path, bytes)
      rescue SystemCallError, IOError => e
        raise WriteError.new(e.message, cause_class: e.class)
      end

      def copy_file!(src, abs_path)
        FileUtils.cp(src, abs_path)
      rescue SystemCallError, IOError => e
        raise WriteError.new(e.message, cause_class: e.class)
      end

      def cleanup!(staging_dir, tmproot: Dir.tmpdir)
        return if staging_dir.to_s.empty?

        path = File.expand_path(staging_dir)
        tmp = File.expand_path(tmproot)
        # Refuse to clean if `path` IS the tmpdir root (would rm_rf
        # /tmp), or anywhere outside the tmpdir subtree.
        unless path != tmp && path.start_with?("#{tmp}#{File::SEPARATOR}")
          # Truncate at a path separator (or hard 80-char cap if none
          # appears) so a leaked sensitive prefix can't surface in
          # stderr mid-component.
          safe_msg = truncate_at_separator(Hive::Tui::Text.sanitize(staging_dir.to_s))
          raise ArgumentError,
            "refusing to clean staging dir outside tmpdir: #{safe_msg}"
        end

        FileUtils.rm_rf(path)
      end

      def truncate_at_separator(str, max: 80)
        return str if str.length <= max

        head = str[0, max]
        last_sep = head.rindex(File::SEPARATOR)
        last_sep && last_sep > max / 2 ? "#{head[0, last_sep]}#{File::SEPARATOR}…" : "#{head}…"
      end
    end
  end
end
