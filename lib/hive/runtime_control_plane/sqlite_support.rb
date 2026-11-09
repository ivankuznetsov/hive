# frozen_string_literal: true

require "sqlite3"

module Hive
  module RuntimeControlPlane
    module SQLiteSupport
      # Upper bound on Exception#cause links inspected by caused_by?. Ruby
      # permits cyclic cause chains (e.g. an error re-raised as its own
      # cause's cause), so the walk is bounded and identity-deduplicated.
      MAX_CAUSE_DEPTH = 16

      module_function

      def pragma_integer(connection, name)
        Integer(connection.fetch("PRAGMA #{name}").first.values.first)
      end

      # Sequel's table_exists? rescues DatabaseError, including SQLite busy.
      # Query the catalog so contention cannot masquerade as a missing table.
      def table_exists?(connection, name)
        !connection[:sqlite_master].where(type: "table", name: name.to_s).get(:name).nil?
      end

      def busy_error?(error)
        caused_by?(error) do |current|
          (defined?(Busy) && current.is_a?(Busy)) ||
            current.is_a?(SQLite3::BusyException) ||
            (defined?(Sequel::DatabaseLockTimeout) &&
             current.is_a?(Sequel::DatabaseLockTimeout))
        end
      end

      def raise_if_busy!(error)
        raise error if error.is_a?(Busy)
        raise Busy.new if busy_error?(error)
      end

      def storage_exhaustion_error?(error)
        caused_by?(error) do |current|
          current.is_a?(SQLite3::FullException) || current.is_a?(Errno::ENOSPC) ||
            current.is_a?(Errno::EDQUOT)
        end
      end

      def caused_by?(error)
        current = error
        seen = {}.compare_by_identity
        MAX_CAUSE_DEPTH.times do
          return false if current.nil? || seen.key?(current)
          return true if yield(current)

          seen[current] = true
          current = current.cause
        end
        false
      end
      private_class_method :caused_by?
    end
  end
end
