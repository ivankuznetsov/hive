# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../paths"
require_relative "channel_prefix_oracle"

module HiveReleaseCandidate
  class UpgradeSurvivor
    class ReviewedChannelUpdater
      SIDECARS = {
        "linux-bash" => %w[hive/install-channel hive/install-prefix],
        "homebrew-local-formula" => %w[share/hive/install-channel]
      }.freeze
      CONTROL_ROOT = File.expand_path("..", __dir__).freeze
      private_constant :CONTROL_ROOT

      def apply!(prefix:, candidate_target:, run_root:, channel:)
        unless ChannelPrefixOracle::CHANNELS.value?(channel)
          raise UsageError, "unreviewed candidate channel update seam #{channel.inspect}"
        end
        retired = File.join(run_root, "channel-baseline-applied")
        receipt = File.join(run_root, "channel-update-receipt")
        [ retired, receipt ].each do |path|
          raise Error, "channel update path already exists: #{path}" if File.exist?(path) || File.symlink?(path)
        end
        prepare_channel_marker(prefix, channel)
        shim = File.join(
          CONTROL_ROOT,
          channel == "linux-bash" ? "channel_shims/linux" : "channel_shims/macos"
        )
        environment = candidate_target.environment.merge(
          "PATH" => [ shim, candidate_target.environment.fetch("PATH") ].join(File::PATH_SEPARATOR),
          "HIVE_PREFIX" => prefix,
          "HOMEBREW_PREFIX" => prefix,
          "HIVE_RC_CHANNEL" => channel,
          "HIVE_RC_CHANNEL_PREFIX" => prefix,
          "HIVE_RC_CHANNEL_CANDIDATE_ROOT" => candidate_target.root,
          "HIVE_RC_CHANNEL_RUN_ROOT" => run_root,
          "HIVE_RC_CHANNEL_RECEIPT" => receipt,
          "HIVE_RC_CONTROL_ROOT" => CONTROL_ROOT
        )
        stdout, stderr, status = Open3.capture3(
          environment, candidate_target.executable, "update", chdir: run_root
        )
        unless status.success?
          raise Error, "channel update seam failed: #{stderr.strip}"
        end
        applied = File.binread(receipt).strip
        raise Error, "channel update receipt mismatch" unless applied == channel

        {
          "seam" => channel == "linux-bash" ?
            "linux-bash-hive-update" :
            "macos-homebrew-local-formula-hive-update",
          "retired_baseline_prefix" => retired,
          "stdout" => stdout,
          "stderr" => stderr
        }
      end

      private

      def prepare_channel_marker(prefix, channel)
        paths = SIDECARS.fetch(channel)
        paths.each { |path| FileUtils.mkdir_p(File.dirname(File.join(prefix, path))) }
        if channel == "linux-bash"
          File.write(File.join(prefix, paths.fetch(0)), "bash\n")
          File.write(File.join(prefix, paths.fetch(1)), "#{prefix}\n")
        else
          File.write(File.join(prefix, paths.fetch(0)), "brew\n")
          brew = File.join(prefix, "bin", "brew")
          FileUtils.mkdir_p(File.dirname(brew))
          FileUtils.cp(File.join(CONTROL_ROOT, "channel_shims/macos/brew"), brew)
          FileUtils.chmod(0o755, brew)
        end
      end
    end
  end
end
