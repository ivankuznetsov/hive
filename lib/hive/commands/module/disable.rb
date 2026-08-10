require "hive/commands/module/state_change"

module Hive
  module Commands
    class Module
      class Disable < StateChange
        def initialize(name, **options) = super("disable", name, **options)
      end
    end
  end
end
