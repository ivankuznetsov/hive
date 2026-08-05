# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require_relative "../paths"
require_relative "channel_prefix_oracle"
require_relative "reviewed_channel_updater"

module HiveReleaseCandidate
  class UpgradeSurvivor
    class FixedChannelExecutor
      def initialize(targets:, updater: nil)
        @baseline = targets.fetch("baseline")
        @candidate = targets.fetch("candidate")
        @updater = updater || ReviewedChannelUpdater.new
      end

      def call(platform:, run_root:, **)
        prefix = File.join(run_root, "channel-prefix")
        raise Error, "channel prefix already exists" if File.exist?(prefix) || File.symlink?(prefix)

        verify_source!(@baseline.root)
        verify_source!(@candidate.root)
        baseline_clone = File.join(run_root, "channel-baseline-prefix")
        raise Error, "baseline clone already exists" if File.exist?(baseline_clone) || File.symlink?(baseline_clone)
        FileUtils.mkdir_p(baseline_clone)
        FileUtils.cp_r(File.join(@baseline.root, "."), baseline_clone, preserve: true)
        FileUtils.mkdir_p(prefix)
        FileUtils.cp_r(File.join(baseline_clone, "."), prefix, preserve: true)
        baseline_files = inventory(prefix)
        baseline_digest = digest_inventory(baseline_files)
        channel = ChannelPrefixOracle::CHANNELS.fetch(platform)
        update = @updater.apply!(
          prefix: prefix, candidate_target: @candidate,
          run_root: run_root, channel: channel
        )
        files = inventory(prefix)
        candidate_files = inventory(@candidate.root)
        sidecars = ReviewedChannelUpdater::SIDECARS.fetch(channel)
        compared_files = files.reject { |path, _row| sidecars.include?(path) }
        stale_files = (compared_files.keys - candidate_files.keys).sort
        dependencies_current = stale_files.empty? &&
          candidate_files.all? { |path, row| compared_files[path] == row }
        wrapper_role = files["bin/hive"] == candidate_files["bin/hive"] ?
          "candidate" : "unknown"
        expected_sidecars = channel == "linux-bash" ?
          { sidecars.fetch(0) => "bash\n", sidecars.fetch(1) => "#{prefix}\n" } :
          { sidecars.fetch(0) => "brew\n" }
        sidecars_current = expected_sidecars.all? do |path, content|
          File.binread(File.join(prefix, path)) == content
        rescue Errno::ENOENT
          false
        end
        manifest = {
          "platform" => platform,
          "channel" => channel,
          "candidate_gem_sha256" => @candidate.manifest.fetch("gem_sha256"),
          "wrapper_role" => wrapper_role,
          "sidecars_current" => sidecars_current,
          "dependencies_current" => dependencies_current,
          "stale_files" => stale_files,
          "files" => files
        }
        File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
        ChannelPrefixOracle.new.verify(
          prefix: prefix, platform: platform, candidate_target: @candidate
        ).merge(
          "baseline_prefix_sha256" => baseline_digest,
          "baseline_prefix_files" => baseline_files,
          "baseline_clone_path" => baseline_clone,
          "candidate_prefix_sha256" => digest_inventory(files),
          "update" => update
        )
      end

      private

      def verify_source!(root)
        inventory(root)
        true
      end

      def inventory(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
          next if [ ".", ".." ].include?(File.basename(path))
          relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
          next if relative == ".hive-install.json"
          stat = File.lstat(path)
          raise Error, "channel source contains a symlink" if stat.symlink?
          next if stat.directory?
          raise Error, "channel source contains a non-regular file" unless stat.file? && stat.uid == Process.uid
          [ relative, { "size" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest } ]
        end.to_h
      end

      def digest_inventory(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end
    end
  end
end
