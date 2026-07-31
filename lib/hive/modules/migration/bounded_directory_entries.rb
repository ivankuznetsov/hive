require "hive/errors"

module Hive
  module Modules
    module Migration
      # Collects one directory's names with an allocation bound enforced while
      # streaming from the directory handle. Callers may sort only after this
      # guard has proved the inventory fits in memory.
      module BoundedDirectoryEntries
        module_function

        MAX_NAME_BYTES = 4_096

        def names(path, limit:)
          path = path.to_s
          limit = Integer(limit)
          malformed! unless
            path == File.expand_path(path) &&
              limit >= 0
          before = File.lstat(path)
          malformed! unless safe_directory?(before)
          names = []
          Dir.open(path) do |directory|
            directory.each_child do |name|
              malformed! if
                names.length >= limit ||
                  name.bytesize > MAX_NAME_BYTES ||
                  name.include?("\0") ||
                  name.include?(File::SEPARATOR)
              names << name.dup.freeze
            end
          end
          after = File.lstat(path)
          malformed! unless same_directory?(before, after)

          names.sort.freeze
        rescue ArgumentError, TypeError, SystemCallError
          malformed!
        end

        def safe_directory?(stat)
          stat.directory? &&
            !stat.symlink? &&
            stat.uid == Process.euid &&
            (stat.mode & 0o022).zero?
        end
        private_class_method :safe_directory?

        def same_directory?(left, right)
          %i[
            dev ino mode nlink uid gid size mtime ctime
          ].all? do |field|
            left.public_send(field) == right.public_send(field)
          end
        end
        private_class_method :same_directory?

        def malformed!
          raise Hive::ConfigError,
                "bounded directory inventory is malformed"
        end
        private_class_method :malformed!
      end
    end
  end
end
