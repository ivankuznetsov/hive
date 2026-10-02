require "etc"

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

      def default_runs_dir
        File.join(e2e_root, "runs")
      end

      def runs_dir
        # `HIVE_E2E_RUNS_DIR` lets tests redirect the runs directory to a
        # temp dir so they cannot accidentally delete real forensic
        # artifacts via `hive-e2e clean`. Cleanup validates this path before
        # deleting anything.
        ENV["HIVE_E2E_RUNS_DIR"] || default_runs_dir
      end

      def replay_control_dir(env: ENV, euid: Process.euid,
                             account_lookup: Etc.method(:getpwuid))
        configured = env["XDG_STATE_HOME"]
        state_home = if configured&.start_with?(File::SEPARATOR)
          File.expand_path(configured)
        else
          account_home = account_lookup.call(euid).dir
          raise ArgumentError, "effective-user home must be absolute" unless
            account_home.start_with?(File::SEPARATOR)

          File.join(account_home, ".local", "state")
        end
        File.join(
          state_home,
          "hive-e2e",
          "replay-#{euid}",
          "locks-v1"
        )
      end

      def fake_claude
        File.join(repo_root, "test", "fixtures", "fake-claude")
      end

      def editor_shim
        File.join(e2e_root, "fixtures", "editor-shim")
      end

      def fixtures_dir
        File.join(e2e_root, "fixtures")
      end

      def gh_shim
        File.join(fixtures_dir, "gh")
      end
    end
  end
end
