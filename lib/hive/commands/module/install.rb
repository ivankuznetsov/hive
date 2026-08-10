require "hive/commands/module/lifecycle"

module Hive
  module Commands
    class Module
      class Install < Lifecycle
        def initialize(source, **options)
          super(source, operation: "install", **options)
        end
      end
    end
  end
end
