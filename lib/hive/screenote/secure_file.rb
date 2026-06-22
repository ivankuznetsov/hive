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
      end
    end
  end
end
