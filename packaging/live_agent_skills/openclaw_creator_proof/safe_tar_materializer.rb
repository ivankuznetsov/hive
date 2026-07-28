module HiveLiveAgentProof
  module OpenClawCreatorProof
    class SafeTarMaterializer
      FILE_LIMIT = SKILL_ARCHIVE_FILE_LIMIT
      TOTAL_LIMIT = SKILL_ARCHIVE_TOTAL_LIMIT

      def initialize(archive:, destination:)
        @archive = File.expand_path(archive)
        @destination = File.expand_path(destination)
      end

      def call
        validate_inputs!
        FileUtils.mkdir_p(@destination, mode: 0o700)
        seen = {}
        records = {}
        total_size = 0

        Zlib::GzipReader.open(@archive) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              name = normalized_name(entry.full_name)
              next if name.empty? && entry.directory?
              fail_archive!("unsafe archive entry #{entry.full_name.inspect}") if name.empty?
              fail_archive!("duplicate archive entry #{name.inspect}") if seen.key?(name)

              seen[name] = true
              destination = File.join(@destination, name)
              if entry.directory?
                create_directory(destination)
                next
              end
              unless entry.file? && regular_type?(entry.header.typeflag)
                fail_archive!("unsupported archive entry type for #{name.inspect}")
              end
              size = Integer(entry.header.size)
              fail_archive!("archive entry is too large: #{name.inspect}") if size > FILE_LIMIT
              total_size += size
              fail_archive!("archive expands beyond #{TOTAL_LIMIT} bytes") if total_size > TOTAL_LIMIT

              create_regular_file(entry, destination, size)
              records[name] = {
                "sha256" => Digest::SHA256.file(destination).hexdigest,
                "size" => File.size(destination)
              }
            end
          end
        end
        records
      rescue Failure
        FileUtils.rm_rf(@destination) if File.directory?(@destination)
        raise
      rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError,
             Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR, Errno::EEXIST,
             ArgumentError, IOError, RangeError => e
        FileUtils.rm_rf(@destination) if File.directory?(@destination)
        fail_archive!("cannot materialize skill archive: #{e.message}")
      end

      private

      def validate_inputs!
        unless File.file?(@archive) && !File.symlink?(@archive)
          fail_archive!("skill archive is not a regular file: #{@archive}")
        end
        fail_archive!("archive destination already exists: #{@destination}") if File.exist?(@destination)
      end

      def normalized_name(raw_name)
        raw = raw_name.to_s
        fail_archive!("unsafe archive entry #{raw_name.inspect}") if raw.include?("\0")
        fail_archive!("unsafe archive entry #{raw_name.inspect}") if raw.include?("\\")
        fail_archive!("unsafe archive entry #{raw_name.inspect}") if raw.start_with?("/") ||
                                                                 raw.match?(/\A[A-Za-z]:[\\\/]/)

        raw = raw.delete_prefix("./")
        return "" if raw.empty? || raw == "."

        parts = raw.split("/")
        if parts.any? { |part| part.empty? || part == "." || part == ".." }
          fail_archive!("unsafe archive entry #{raw_name.inspect}")
        end
        clean = Pathname.new(raw).cleanpath
        if clean.absolute? || clean.each_filename.include?("..")
          fail_archive!("unsafe archive entry #{raw_name.inspect}")
        end

        clean.to_s
      end

      def regular_type?(typeflag)
        typeflag == "0" || typeflag == "\0" || typeflag.to_s.empty?
      end

      def create_directory(path)
        ensure_controlled_parent!(File.dirname(path))
        if File.exist?(path)
          fail_archive!("archive path conflicts with an existing entry: #{path}")
        end

        Dir.mkdir(path, 0o700)
      end

      def create_regular_file(entry, path, expected_size)
        ensure_controlled_parent!(File.dirname(path))
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes_written = 0
        File.open(path, flags, 0o600) do |file|
          while bytes_written < expected_size
            chunk = entry.read([ 16 * 1024, expected_size - bytes_written ].min)
            fail_archive!("truncated archive entry #{entry.full_name.inspect}") if chunk.nil? || chunk.empty?

            file.write(chunk)
            bytes_written += chunk.bytesize
          end
        end
        unless bytes_written == expected_size && File.file?(path) && !File.symlink?(path)
          fail_archive!("invalid materialized file #{entry.full_name.inspect}")
        end
      end

      def ensure_controlled_parent!(path)
        relative = Pathname.new(path).relative_path_from(Pathname.new(@destination))
        current = @destination
        relative.each_filename do |part|
          current = File.join(current, part)
          if File.exist?(current)
            fail_archive!("archive parent is not a directory: #{current}") unless
              File.directory?(current) && !File.symlink?(current)
          else
            Dir.mkdir(current, 0o700)
          end
        end
      end

      def fail_archive!(detail)
        raise Failure.new(phase: "archive", reason: "unsafe_archive", detail: detail)
      end
    end
  end
end
