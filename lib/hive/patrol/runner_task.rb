module Hive
  module Patrol
    RunnerTask = Struct.new(:folder, :project_root, :state_file, :log_dir, :slug, keyword_init: true)
  end
end
