require "hive/modules/adapters/patrol"
require "hive/modules/entrypoints"

module Hive
  module Modules
    module FirstParty
      module_function

      def load!
        adapter = Hive::Modules::Adapters::Patrol.new
        Hive::Modules::Adapters::Patrol::ENTRYPOINTS.each do |entrypoint, hook_id|
          Entrypoints.register(entrypoint) do |context|
            adapter.call(**context.merge(hook_id: hook_id))
          end
        end
        true
      end
    end
  end
end
