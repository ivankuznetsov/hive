module Hive
  module Stages
    module Inbox
      module_function

      def run!(task, _cfg)
        target = File.join(task.hive_state_path, "stages", "2-brainstorm")
        warn "hive: 1-inbox/ is an inert capture zone. To start work:"
        warn "  mv #{task.folder} #{target}/"
        warn "  hive run #{File.join(target, task.slug)}"
        { commit: nil, status: :inert }
      end
    end
  end
end
