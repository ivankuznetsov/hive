module Hive
  module E2E
    module Paths
      module_function

      def repo_root
        File.expand_path("../../..", __dir__)
      end

      def lib_dir
        File.join(repo_root, "lib")
      end

      def hive_bin
        File.join(repo_root, "bin", "hive")
      end

      def e2e_root
        File.expand_path("..", __dir__)
      end

      def sample_project
        File.join(e2e_root, "sample-project")
      end

      def scenarios_dir
        File.join(e2e_root, "scenarios")
      end

      def runs_dir
        File.join(e2e_root, "runs")
      end

      def fake_claude
        File.join(repo_root, "test", "fixtures", "fake-claude")
      end

      def editor_shim
        File.join(e2e_root, "fixtures", "editor-shim")
      end
    end
  end
end
