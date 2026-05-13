require "fileutils"
require "securerandom"
require "tmpdir"

require "hive"

module Hive
  module Tui
    # Per-session scratch space for image attachments accumulated in
    # the new-idea composer. Files are written to a Process-PID + random
    # suffix tmpdir; the BubbleModel cleans up on submit (success or
    # validation failure) and on Esc/cancel.
    class ComposerStaging
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

      # File-name prefix for staged image attachments. Neutral —
      # earlier drafts used `bug-N` which presumed the use case is bug
      # reports; a user pasting a design screenshot or architecture
      # diagram should not see a misleading filename.
      ATTACHMENT_BASENAME = "image".freeze
      DEFAULT_EXTENSION = "png".freeze

      class << self
        # Returns `[dir, model_or_nil]`. The second slot is the LOAD-BEARING
        # signal — non-nil means the caller MUST adopt the returned
        # model (the staging dir was created and is recorded on it);
        # nil means the model already carried a valid staging dir and
        # the caller should keep the model it already has.
        #
        # The two-tuple contract exists so the caller can short-circuit
        # without redundant `model.with` calls when the staging dir is
        # already pinned.
        def ensure_dir!(model)
          return [ model.new_idea_staging_dir, nil ] unless model.new_idea_staging_dir.to_s.empty?

          dir = Dir.mktmpdir("hive-tui-composer-#{Process.pid}-#{SecureRandom.hex(4)}-")
          [ dir, model.with(new_idea_staging_dir: dir) ]
        end

        # Build the next placeholder label and absolute disk path for an
        # attachment. The label format `imageN` is exactly what the
        # composer buffer renders as `[imageN]`; the disk path uses the
        # neutral `image-N.<ext>` basename so a non-bug attachment
        # doesn't get a misleading filename. Extension defaults are
        # routed through `normalized_extension` so every site that
        # needs an extension-fallback shares one definition.
        def next_label_and_path(staging_dir, attachments_count, ext: DEFAULT_EXTENSION)
          number = attachments_count.to_i + 1
          clean_ext = normalized_extension(ext)
          [ "image#{number}", File.join(staging_dir, "#{ATTACHMENT_BASENAME}-#{number}.#{clean_ext}") ]
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

        def cleanup!(staging_dir)
          return if staging_dir.to_s.empty?

          path = File.expand_path(staging_dir)
          tmp = File.expand_path(Dir.tmpdir)
          # Refuse to clean if `path` IS the tmpdir root (would
          # rm_rf /tmp), or anywhere outside the tmpdir subtree.
          unless path != tmp && path.start_with?("#{tmp}#{File::SEPARATOR}")
            raise ArgumentError, "refusing to clean staging dir outside tmpdir: #{staging_dir}"
          end

          FileUtils.rm_rf(path)
        end
      end
    end
  end
end
