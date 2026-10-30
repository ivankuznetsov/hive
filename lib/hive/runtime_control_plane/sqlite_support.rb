# frozen_string_literal: true

require "sqlite3"

module Hive
  module RuntimeControlPlane
    module SQLiteSupport
      module_function

      def pragma_integer(connection, name)
        Integer(connection.fetch("PRAGMA #{name}").first.values.first)
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
        while current
          return true if yield(current)
          current = current.cause
        end
        false
      end
      private_class_method :caused_by?
    end
  end
end
