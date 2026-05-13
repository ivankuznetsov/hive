require "fileutils"
require "securerandom"
require "tmpdir"

require "hive"

module Hive
  module Tui
    class ComposerStaging
      class WriteError < Hive::Error; end

      class << self
        def ensure_dir!(model)
          return [ model.new_idea_staging_dir, nil ] unless model.new_idea_staging_dir.to_s.empty?

          dir = Dir.mktmpdir("hive-tui-composer-#{Process.pid}-#{SecureRandom.hex(4)}-")
          [ dir, model.with(new_idea_staging_dir: dir) ]
        end

        def next_label_and_path(staging_dir, attachments_count, ext: "png")
          number = attachments_count.to_i + 1
          clean_ext = ext.to_s.downcase.delete_prefix(".")
          clean_ext = "png" if clean_ext.empty?
          [ "image#{number}", File.join(staging_dir, "bug-#{number}.#{clean_ext}") ]
        end

        def write_bytes!(abs_path, bytes)
          File.binwrite(abs_path, bytes)
        rescue SystemCallError, IOError => e
          raise WriteError, e.message
        end

        def copy_file!(src, abs_path)
          FileUtils.cp(src, abs_path)
        rescue SystemCallError, IOError => e
          raise WriteError, e.message
        end

        def cleanup!(staging_dir)
          return if staging_dir.to_s.empty?

          path = File.expand_path(staging_dir)
          tmp = File.expand_path(Dir.tmpdir)
          unless path == tmp || path.start_with?("#{tmp}#{File::SEPARATOR}")
            raise ArgumentError, "refusing to clean staging dir outside tmpdir: #{staging_dir}"
          end

          FileUtils.rm_rf(path)
        end
      end
    end
  end
end
