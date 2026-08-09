require "digest"
require "json"
require "hive/attempts/store"
require "hive/managed_directory"

module Hive
  module Attempts
    # Descriptor-relative persistence shared by the point-addressed attempt
    # stores. Keys are canonical JSON digests, while every payload embeds the
    # unhashed key so an impossible digest collision still fails closed.
    module StorageKey
      module_function

      def relative(kind, key)
        kind = component(kind)
        digest = digest(kind, key)
        File.join(kind, digest[0, 2], "#{digest}.json")
      end

      def digest(kind, key)
        Digest::SHA256.hexdigest(dump(
          "kind" => component(kind),
          "key" => normalize(key)
        ))
      end

      def dump(value)
        "#{JSON.generate(normalize(value))}\n"
      end

      def normalize(value)
        case value
        when Hash
          value.to_h do |key, child|
            [ string(key), normalize(child) ]
          end.sort.to_h
        when Array
          value.map { |child| normalize(child) }
        when String, Symbol
          string(value)
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise StoreError, "attempt storage key contains an unsupported value"
        end
      end

      def component(value)
        string = value.to_s
        return string if /\A[a-z][a-z0-9-]{0,63}\z/.match?(string)

        raise StoreError, "attempt storage key kind is invalid"
      end

      def string(value)
        string = value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc)
        raise StoreError, "attempt storage key string is empty" if string.empty?
        raise StoreError, "attempt storage key string is too long" if string.bytesize > 4_096

        string
      rescue EncodingError
        raise StoreError, "attempt storage key string is invalid"
      end
    end

    # Small adapter around ManagedDirectory that translates its custody errors
    # into the Attempts storage contract and supplies per-cell serialization.
    class PointStorage
      attr_reader :root

      def initialize(root:, label:, create_directories: true)
        @root = File.expand_path(root).freeze
        @label = label.to_s.freeze
        @directory = Hive::ManagedDirectory.new(root: @root, label: @label)
        @directory.prepare! if create_directories
      rescue Hive::ManagedDirectory::UnsafeError,
             SystemCallError, IOError, ArgumentError, TypeError => error
        unavailable!(error)
      end

      def path_for(kind, key)
        File.join(root, StorageKey.relative(kind, key))
      end

      def read(kind, key, max_bytes:)
        @directory.read(
          StorageKey.relative(kind, key),
          max_bytes: max_bytes,
          missing: true
        )
      rescue Hive::ManagedDirectory::UnsafeError,
             SystemCallError, IOError, ArgumentError, TypeError => error
        unavailable!(error)
      end

      def write(kind, key, bytes, expected_bytes:, max_existing_bytes:)
        @directory.atomic_write(
          StorageKey.relative(kind, key),
          bytes,
          mode: 0o600,
          expected_digest: expected_bytes && Digest::SHA256.hexdigest(expected_bytes),
          max_existing_bytes: max_existing_bytes
        )
      rescue Hive::ManagedDirectory::UnsafeError,
             SystemCallError, IOError, ArgumentError, TypeError => error
        unavailable!(error)
      end

      def synchronize(kind, key)
        digest = StorageKey.digest(kind, key)
        @directory.with_lock(File.join("locks", digest[0, 2], "#{digest}.lock")) do
          yield
        end
      rescue Hive::ManagedDirectory::UnsafeError,
             SystemCallError, IOError, ArgumentError, TypeError => error
        unavailable!(error)
      end

      private

      def unavailable!(error)
        raise StoreError, "#{@label || 'attempt point storage'} is unavailable: #{error.message}"
      end
    end
  end
end
