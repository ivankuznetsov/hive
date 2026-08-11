require "hive/attempts/store"
require "hive/point_storage"

module Hive
  module Attempts
    # Compatibility facade over the lower-level storage-key primitive. Its
    # wrappers preserve the Attempts::StoreError contract for existing callers.
    module StorageKey
      module_function

      %i[relative digest dump normalize component string].each do |method_name|
        define_method(method_name) do |*args|
          Hive::StorageKey.public_send(
            method_name,
            *args,
            error_class: Hive::Attempts::StoreError
          )
        end
      end
    end

    class PointStorage < Hive::PointStorage
      def initialize(root:, label:, create_directories: true)
        super(
          root: root,
          label: label,
          create_directories: create_directories,
          error_class: Hive::Attempts::StoreError
        )
      end
    end
  end
end
