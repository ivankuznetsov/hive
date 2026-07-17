module Hive
  module Patrol
    # Bounded reader for repository source inspection. Architecture discovery
    # consumes project-controlled paths, including tracked symlinks, so every
    # content read resolves beneath the canonical project root, verifies a
    # regular file, and caps bytes before UTF-8 decoding.
    class SourceReader
      MAX_SOURCE_BYTES = 256 * 1024

      def initialize(project_root)
        @project_root = File.realpath(File.expand_path(project_root))
        @project_prefix = "#{@project_root}#{File::SEPARATOR}"
      end

      def regular_file?(path)
        !resolved_regular_path(path).nil?
      end

      def read_bytes(path, limit: MAX_SOURCE_BYTES)
        byte_limit = [ limit.to_i, MAX_SOURCE_BYTES ].min
        return "".b unless byte_limit.positive?

        resolved = resolved_regular_path(path)
        return "".b unless resolved

        File.open(resolved, read_flags) do |file|
          return "".b unless file.stat.file?

          file.read(byte_limit) || "".b
        end
      rescue SystemCallError, ArgumentError
        "".b
      end

      def read_utf8(path, limit: MAX_SOURCE_BYTES)
        read_bytes(path, limit: limit).force_encoding(Encoding::UTF_8).scrub("")
      end

      private

      def resolved_regular_path(path)
        candidate = File.expand_path(path.to_s, @project_root)
        resolved = File.realpath(candidate)
        return unless resolved.start_with?(@project_prefix)
        return unless File.stat(resolved).file?

        resolved
      rescue SystemCallError, ArgumentError
        nil
      end

      def read_flags
        flags = File::RDONLY | File::BINARY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
        flags
      end
    end
  end
end
