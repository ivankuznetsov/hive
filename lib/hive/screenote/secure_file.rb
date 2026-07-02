require "fileutils"
require "json"

module Hive
  module Screenote
    # Writes pretty-printed JSON to a 0600 file, creating parent dirs.
    #
    # Two operations on purpose: `perm: 0o600` on File.write only applies
    # when the file is CREATED (it's ANDed with the umask), so it neither
    # tightens an existing looser file nor backstops a permissive umask.
    # The explicit chmod afterwards covers both — it re-tightens a file a
    # prior run left at 0644 and is umask-independent. Both Screenote secret
    # writers (the OAuth credential store and the ephemeral MCP config)
    # share this so the rationale lives in exactly one place.
    module SecureFile
      module_function

      def write_json(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(data)}\n", mode: "w", perm: 0o600)
        File.chmod(0o600, path)
        path
      rescue StandardError
        # The file is already created (it holds the secret — a bearer token or
        # OAuth credential) by the time chmod runs. If chmod (or any step after
        # create) raises, write_json never returns the path, so the caller
        # can't clean up a file it never learned about — orphaning a 0600
        # secret on disk. Unlink the partial file before re-raising so the
        # secret never lingers; the caller still sees the original failure.
        FileUtils.rm_f(path)
        raise
      end
    end
  end
end
