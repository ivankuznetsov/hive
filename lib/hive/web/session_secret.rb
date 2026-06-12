require "fileutils"
require "securerandom"

module Hive
  module Web
    module SessionSecret
      module_function

      # HIVEBOX_SESSION_SECRET shorter than the minimum is IGNORED (a random
      # secret is generated instead): a weak operator-chosen value must not
      # silently weaken cookie crypto. The visible symptom is sessions not
      # surviving recreation — this comment is the breadcrumb for that.
      def load_or_create(path)
        env = ENV["HIVEBOX_SESSION_SECRET"].to_s
        return env if env.bytesize >= 32

        FileUtils.mkdir_p(File.dirname(path))
        if File.file?(path)
          existing = File.read(path).strip
          return existing if existing.bytesize >= 32
        end

        secret = SecureRandom.hex(64)
        File.write(path, secret, mode: "w", perm: 0o600)
        secret
      end
    end
  end
end
