require "thread"
require "hive/managed_directory"

module Hive
  module Modules
    module Migration
      # A process-local mutex paired with a stable, never-unlinked flock file.
      # The mutex supplies thread ownership (flock alone is not a Ruby-thread
      # authority); the file lock supplies process ownership and is released
      # by the kernel when a sender process exits.
      class StableProcessLock
        @registry_guard = Mutex.new
        @registry = {}

        class << self
          def synchronize(path)
            key = [ Process.pid, path ].freeze
            entry = register(key)
            entry.fetch(:mutex).synchronize { yield }
          ensure
            unregister(key, entry) if entry
          end

          private

          def register(key)
            @registry_guard.synchronize do
              entry = (@registry[key] ||= {
                mutex: Mutex.new,
                users: 0
              })
              entry[:users] += 1
              entry
            end
          end

          def unregister(key, entry)
            @registry_guard.synchronize do
              current = @registry[key]
              return unless current.equal?(entry)

              current[:users] -= 1
              @registry.delete(key) if current[:users].zero?
            end
          end
        end

        def initialize(root:, label:)
          @root = File.expand_path(root).freeze
          @label = label.to_s.freeze
        end

        def synchronize(name)
          lock_name = "#{validated_name(name)}.lock"
          directory = managed_directory
          path = File.join(directory.root, lock_name)
          self.class.synchronize(path) do
            directory.with_lock(lock_name) { yield }
          end
        end

        private

        def managed_directory
          @directory ||= Hive::ManagedDirectory.new(
            root: @root,
            label: @label
          )
        end

        def validated_name(value)
          name = value.to_s
          return name if name.match?(/\A[a-z0-9][a-z0-9.-]*\z/)

          raise Hive::ConfigError, "patrol stable lock identity is malformed"
        end
      end
    end
  end
end
