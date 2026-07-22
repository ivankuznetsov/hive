require "hive/commands/module/lifecycle"

module Hive
  module Commands
    class Module
      class Update < Lifecycle
        def initialize(name, **options)
          super(name, operation: "update", **options)
        end
      end
    end
  end
end
