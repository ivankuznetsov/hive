require "digest"
require "json"
require "hive"
require "hive/managed_directory"

module Hive
  class PointStorageError < Hive::Error; end

  # Canonical, digest-addressed keys shared by bounded owner-private stores.
  # Callers supply their domain error class so this primitive does not make a
  # higher-level Attempts or routing error part of its own contract.
  module StorageKey
    module_function

    def relative(kind, key, error_class: PointStorageError)
      kind = component(kind, error_class: error_class)
      digest = digest(kind, key, error_class: error_class)
      File.join(kind, digest[0, 2], "#{digest}.json")
    end

    def digest(kind, key, error_class: PointStorageError)
      Digest::SHA256.hexdigest(dump(
        {
          "kind" => component(kind, error_class: error_class),
          "key" => normalize(key, error_class: error_class)
        },
        error_class: error_class
      ))
    end

    def dump(value, error_class: PointStorageError)
      "#{JSON.generate(normalize(value, error_class: error_class))}\n"
    end

    def normalize(value, error_class: PointStorageError)
      case value
      when Hash
        value.to_h do |key, child|
          [
            string(key, error_class: error_class),
            normalize(child, error_class: error_class)
          ]
        end.sort.to_h
      when Array
        value.map { |child| normalize(child, error_class: error_class) }
      when String, Symbol
        string(value, error_class: error_class)
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        raise error_class, "storage key contains an unsupported value"
      end
    end

    def component(value, error_class: PointStorageError)
      string = value.to_s
      return string if /\A[a-z][a-z0-9-]{0,63}\z/.match?(string)

      raise error_class, "storage key kind is invalid"
    end

    def string(value, error_class: PointStorageError)
      string = value.to_s.encode(Encoding::UTF_8).unicode_normalize(:nfc)
      raise error_class, "storage key string is empty" if string.empty?
      raise error_class, "storage key string is too long" if string.bytesize > 4_096

      string
    rescue EncodingError
      raise error_class, "storage key string is invalid"
    end
  end

  # Small adapter around ManagedDirectory that supplies per-cell
  # serialization. The caller-provided domain error class preserves the
  # surrounding component's public failure vocabulary.
  class PointStorage
    SHA256_FILE = /\A[0-9a-f]{64}\.json\z/
    SHARD = /\A[0-9a-f]{2}\z/

    attr_reader :root

    def initialize(root:, label:, create_directories: true,
                   error_class: PointStorageError)
      @root = File.expand_path(root).freeze
      @label = label.to_s.freeze
      @error_class = error_class
      unless @error_class.is_a?(Class) && @error_class <= StandardError
        raise ArgumentError, "point storage error class must be an exception class"
      end
      begin
        @directory = Hive::ManagedDirectory.new(root: @root, label: @label)
        @directory.prepare! if create_directories
      rescue Hive::ManagedDirectory::UnsafeError,
             SystemCallError, IOError, ArgumentError, TypeError => error
        unavailable!(error)
      end
    end

    def path_for(kind, key)
      File.join(root, storage_relative(kind, key))
    end

    def read(kind, key, max_bytes:)
      @directory.read(
        storage_relative(kind, key),
        max_bytes: max_bytes,
        missing: true
      )
    rescue Hive::ManagedDirectory::UnsafeError,
           SystemCallError, IOError, ArgumentError, TypeError => error
      unavailable!(error)
    end

    def write(kind, key, bytes, expected_bytes:, max_existing_bytes:)
      @directory.atomic_write(
        storage_relative(kind, key),
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
      digest = storage_digest(kind, key)
      @directory.with_lock(File.join("locks", digest[0, 2], "#{digest}.lock")) do
        yield
      end
    rescue Hive::ManagedDirectory::UnsafeError,
           SystemCallError, IOError, ArgumentError, TypeError => error
      unavailable!(error)
    end

    def delete(kind, key, expected_bytes:, max_bytes:)
      @directory.unlink(
        storage_relative(kind, key),
        missing: true,
        expected_digest: expected_bytes && Digest::SHA256.hexdigest(expected_bytes),
        max_bytes: max_bytes
      )
    rescue Hive::ManagedDirectory::UnsafeError,
           SystemCallError, IOError, ArgumentError, TypeError => error
      unavailable!(error)
    end

    # Bounded descriptor-relative enumeration for operator projections.
    # Admission and reconciliation stay point-addressed; callers must name
    # one kind and a hard maximum before any entries are read.
    def each_entry(kind, max_entries:, max_bytes:)
      return enum_for(
        __method__, kind, max_entries: max_entries, max_bytes: max_bytes
      ) unless block_given?

      component = Hive::StorageKey.component(kind, error_class: @error_class)
      maximum = Integer(max_entries)
      raise @error_class, "point-storage enumeration bound is invalid" unless maximum.positive?

      entries = []
      @directory.each_child(component, missing: true) do |shard|
        unavailable!(ArgumentError.new("invalid point-storage shard")) unless SHARD.match?(shard)
        unless @directory.entry_type(File.join(component, shard)) == :directory
          unavailable!(ArgumentError.new("point-storage shard is not a directory"))
        end
        @directory.each_child(File.join(component, shard)) do |name|
          unavailable!(ArgumentError.new("invalid point-storage entry")) unless SHA256_FILE.match?(name)
          entries << File.join(component, shard, name)
          if entries.length > maximum
            raise @error_class, "point-storage enumeration exceeds its bounded projection"
          end
        end
      end
      entries.sort.each do |relative|
        yield @directory.read(relative, max_bytes: max_bytes)
      end
      nil
    rescue Hive::ManagedDirectory::UnsafeError,
           SystemCallError, IOError, ArgumentError, TypeError => error
      unavailable!(error)
    end

    private

    def storage_relative(kind, key)
      Hive::StorageKey.relative(kind, key, error_class: @error_class)
    end

    def storage_digest(kind, key)
      Hive::StorageKey.digest(kind, key, error_class: @error_class)
    end

    def unavailable!(error)
      raise @error_class, "#{@label || 'point storage'} is unavailable: #{error.message}"
    end
  end
end
