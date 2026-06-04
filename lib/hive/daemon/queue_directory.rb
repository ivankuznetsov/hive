require "fileutils"
require "hive/paths"

module Hive
  module Daemon
    # Shared helper for the file-backed dispatch queues
    # (`DispatchRequestQueue` / `DispatchResultQueue`). Both resolve a
    # per-queue directory under `<state_home>` with the owner-only (0700)
    # permission invariant — keep that invariant in ONE place (#253) so the
    # two queues can never drift apart on the mode that is the de-facto auth
    # boundary for the dispatch channel.
    module QueueDirectory
      module_function

      # Resolve (creating if needed, mode 0700) `<state_home>/<dirname>`.
      # `mkdir_p`'s `mode:` only applies to directories it creates, so an
      # explicit `chmod` re-asserts 0700 on a pre-existing directory too.
      def directory_for(dirname:, state_home: Hive::Paths.state_home)
        path = File.join(state_home, dirname)
        FileUtils.mkdir_p(path, mode: 0o700)
        File.chmod(0o700, path) if File.directory?(path)
        path
      end
    end
  end
end
