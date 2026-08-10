require "hive/commands/module/state_change"

module Hive
  module Commands
    class Module
      class Enable < StateChange
        def initialize(name, **options) = super("enable", name, **options)
      end
    end
  end
end
