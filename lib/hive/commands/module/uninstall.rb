require "hive/commands/module/state_change"

module Hive
  module Commands
    class Module
      class Uninstall < StateChange
        def initialize(name, **options) = super("uninstall", name, **options)
      end
    end
  end
end
