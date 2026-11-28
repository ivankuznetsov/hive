require "tmpdir"

module Hive
  module RuntimeControlPlane
    # Even SQLite's readonly open can initialize a WAL index on a writable
    # filesystem. Give doctor a private, consistent copy for those opens.
    module InspectionSnapshot
      def with_inspection_snapshot
        ensure_process_owner!
        return yield self, diagnosis(:missing) unless lstat_if_present(path)
        if confirmed_read_only_storage?
          inspection_unavailable!("rollback journal present") if lstat_if_present("#{path}-journal")
          return yield self
        end
        validate_database_custody!
        parent = File.realpath(File.dirname(path))
        temporary_root = [ Dir.tmpdir, "/tmp" ].lazy.select { |dir| File.directory?(dir) }.map { |dir| File.realpath(dir) }.find do |dir|
          dir != parent && !dir.start_with?(File.join(parent, ""))
        end
        inspection_unavailable!("no temporary directory outside the state root") unless temporary_root
        Dir.mktmpdir("hive-doctor-", temporary_root) do |temporary|
          copy = File.join(temporary, File.basename(path))
          writer_fence(timeout_sec: 0).observe_exclusively do
            directory = File.stat(parent)
            before = inspection_source
            before.each do |source, signature|
              File.open(source, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
                inspection_unavailable!("source changed: #{source}") unless inspection_signature(input.stat) == signature
                File.open(File.join(temporary, File.basename(source)), "wx", 0o600) do |output|
                  IO.copy_stream(input, output)
                end
              end
            end
            current = File.lstat(File.dirname(path))
            unless [ directory.dev, directory.ino ] == [ current.dev, current.ino ] && before == inspection_source
              inspection_unavailable!("source changed during copy")
            end
          end
          snapshot = Database.new(path: copy)
          begin
            yield snapshot
          ensure
            snapshot.disconnect
          end
        end
      rescue FileFence::Busy, Hive::ConfigError, SystemCallError, IOError => error
        inspection_unavailable!(error.message)
      end

      private

      def inspection_source
        validate_database_custody!
        inspection_unavailable!("rollback journal present") if lstat_if_present("#{path}-journal")
        files = [ path, "#{path}-wal", "#{path}-shm" ].to_h do |file|
          status = lstat_if_present(file)
          validate_file_custody!(file, status) if status
          [ file, status && inspection_signature(status) ]
        end
        inspection_unavailable!("database disappeared") unless files[path]
        inspection_unavailable!("unpaired WAL/SHM") if files.values_at("#{path}-wal", "#{path}-shm").compact.one?
        files.compact
      end

      def inspection_signature(stat) = [ stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime ]

      def inspection_unavailable!(reason)
        raise Unavailable.new("Could not inspect #{path}: #{reason}",
                              code: :inspection_unavailable, action: "retry hive doctor when storage is stable")
      end
    end
  end
end
