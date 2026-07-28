module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class LedgerError < StandardError; end
    class InvalidLedger < LedgerError; end
    class LedgerWriteFailed < LedgerError; end

    class BoundedRegularReader
      def initialize(path:, max_bytes:, label:, lstat: File.method(:lstat),
                     open_file: File.method(:open))
        @path = File.expand_path(path)
        @max_bytes = Integer(max_bytes)
        @label = label.to_s
        @lstat = lstat
        @open_file = open_file
        raise ArgumentError, "reader byte limit must be positive" unless
          @max_bytes.positive?
      end

      def read
        begin
          before = @lstat.call(@path)
        rescue Errno::ENOENT
          return nil
        end
        reject_type!(before)
        reject_size!(before.size)

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = @open_file.call(@path, flags) do |file|
          opened = file.stat
          unless opened.file? &&
                 opened.dev == before.dev &&
                 opened.ino == before.ino &&
                 opened.size == before.size
            invalid!("#{@label} identity changed while opening")
          end
          reject_size!(opened.size)

          content = file.read(@max_bytes + 1) || +"".b
          reject_size!(content.bytesize)
          invalid!("#{@label} changed while reading") unless
            content.bytesize == opened.size &&
            file.stat.size == opened.size
          content
        end

        after = @lstat.call(@path)
        reject_type!(after)
        unless after.dev == before.dev &&
               after.ino == before.ino &&
               after.size == bytes.bytesize
          invalid!("#{@label} identity changed after reading")
        end
        bytes
      rescue InvalidLedger
        raise
      rescue SystemCallError, IOError => e
        invalid!("cannot read #{@label}: #{e.message}")
      end

      private

      def reject_type!(stat)
        invalid!("#{@label} is not a regular file") unless
          stat.file? && !stat.symlink?
      end

      def reject_size!(size)
        invalid!("#{@label} exceeds byte budget") if size > @max_bytes
      end

      def invalid!(detail)
        raise InvalidLedger, detail
      end
    end
  end
end
