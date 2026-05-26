module Hive
  module Babysitter
    class PrFixer
      def self.run(_pr, _project, _cfg, dry_run:, logger:, inflight:)
        :noop
      end
    end
  end
end
