module Hive
  module WorkflowPackage
    module SafeFile
      module_function

      def read(path, max_bytes:, error_class:, message:, mode: nil, owner_uid: nil)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        file = File.open(path, flags)
        before = file.stat
        valid = before.file? && before.nlink == 1 && before.size <= max_bytes
        valid &&= (before.mode & 0o777) == mode if mode
        valid &&= before.uid == owner_uid if owner_uid
        raise error_class, message unless valid

        bytes = file.read(max_bytes + 1)
        after = file.stat
        unchanged = %i[dev ino size mtime ctime].all? do |field|
          before.public_send(field) == after.public_send(field)
        end
        raise error_class, message unless unchanged && bytes.bytesize <= max_bytes

        [ bytes.b.freeze, before ]
      rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES, IOError
        raise error_class, message
      ensure
        file&.close
      end
    end
  end
end
