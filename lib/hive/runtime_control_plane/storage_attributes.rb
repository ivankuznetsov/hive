require "fileutils"
require "open3"
require "timeout"
require "hive/paths"
require "hive/invoked_binary"
require "hive/runtime_control_plane/file_fence"

module Hive
  module RuntimeControlPlane
    class StorageAttributes
      MIGRATION = "Quiesce Hive, prepare empty btrfs storage, copy, validate, swap and resume. " \
                  "See wiki/commands/runtime.md#btrfs-nocow-migration.".freeze
      RETRY = "Check probe tool availability and access to the path, then rerun hive doctor.".freeze
      class ProbeError < StandardError; end

      # Limit both output and elapsed time. Kill inside the block so Open3 can
      # always reap the child, even when it times out with its pipe still open.
      def self.run_command(name, *args)
        executable = Hive::InvokedBinary.which(name)
        raise ProbeError, "#{name} executable not found" unless executable

        Open3.popen2e({ "LC_ALL" => "C" }, [ File.expand_path(executable), name ], *args) do |input, output, child|
          input.close
          begin
            Timeout.timeout(2) do
              bytes = output.read(8193).to_s
              raise ProbeError, "#{name} output too long" if bytes.bytesize > 8192

              status = child.value
              diagnostic = bytes.scrub.strip[0, 200]
              raise ProbeError, "#{name} failed (#{status}): #{diagnostic}" unless status.success?

              bytes
            end
          ensure
            begin
              Process.kill("KILL", child.pid) if child.alive?
            rescue Errno::ESRCH
              # The child exited between the liveness check and kill.
            end
          end
        end
      end

      class << self
        attr_writer :default_runner
        def default_runner = @default_runner || method(:run_command)
      end

      def self.prepare(path: Hive::Paths.runtime_control_plane_path, on_warning: Kernel.method(:warn))
        evidence = new(path: path).prepare
        if evidence[:remediation]
          on_warning&.call("#{evidence[:message]} #{evidence[:remediation]}")
        end
        evidence
      end

      def initialize(path: Hive::Paths.runtime_control_plane_path, platform: RUBY_PLATFORM,
                     runner: self.class.default_runner)
        @path = File.expand_path(path)
        @root = File.dirname(@path)
        @linux = platform.include?("linux")
        @runner = runner
      end

      def inspect_storage
        root = inspect_path("directory", @root)
        paths = [ root ]
        if root[:file_type] == "directory"
          { "database" => "", "wal" => "-wal", "shm" => "-shm", "journal" => "-journal" }.each do |role, suffix|
            paths << inspect_path(role, @path + suffix)
          end
        end
        aggregate(paths)
      end

      # Only lifecycle owners invoke this before creating their first artifact.
      def prepare
        FileUtils.mkdir_p(@root, mode: 0o700)
        initial = File.lstat(@root)
        evidence = inspect_storage
        root = evidence[:paths].first
        return evidence unless root[:outcome] == "warning"
        return evidence unless FileFence.safe_directory?(initial)
        return evidence unless Dir.empty?(@root)

        current = File.lstat(@root)
        return evidence unless FileFence.safe_directory?(current) && same_inode?(initial, current)
        return evidence if lstat(@path) || !Dir.empty?(@root)

        probe("chattr", "+C", @root)
        verified = inspect_storage
        flag = verified[:paths].first
        if same_inode?(initial, File.lstat(@root)) && flag[:nocow] == true
          return verified
        end
        raise ProbeError, "chattr +C could not be verified: #{flag[:reason] || flag[:outcome]}"
      rescue ProbeError, SystemCallError, IOError => error
        root ||= path_evidence("directory", @root)
        root[:outcome] = root[:filesystem] == "btrfs" ? "warning" : "indeterminate"
        root[:reason] = error.message
        aggregate(evidence ? evidence[:paths] : [ root ])
      end

      private

      def path_evidence(role, path)
        { role: role, path: path, exists: nil, file_type: nil, filesystem: nil, nocow: nil,
          outcome: "indeterminate", reason: nil }
      end

      def inspect_path(role, path)
        row = path_evidence(role, path)
        status = lstat(path)
        row[:exists] = !status.nil?
        return row.merge(outcome: "absent") unless status
        row[:file_type] = status.ftype
        expected_type = role == "directory" ? "directory" : "file"
        return row.merge(reason: "lstat: unexpected file type") unless row[:file_type] == expected_type
        return row.merge(outcome: "not_applicable", reason: "non-Linux platform") unless @linux

        fs = probe("stat", "-f", "--format=%t %T", "--", path).chomp
        match = /\A([0-9a-f]{1,16}) ([a-zA-Z0-9_.\/-]+)\z/.match(fs)
        unless match && (match[1] == "9123683e") == (match[2] == "btrfs")
          raise ProbeError, "stat returned an unrecognized filesystem result"
        end
        row[:filesystem] = match[2]
        if match[2] == "btrfs"
          output = probe("lsattr", "-d", path).chomp
          flags = /\A([-aAcCdDeEfFiIjmNPsStTuVx]{16,32})[ \t]+#{Regexp.escape(path)}\z/.match(output)
          unless flags && !flags[1].delete("-").chars.tally.any? { |_flag, count| count > 1 }
            raise ProbeError, "lsattr returned an unrecognized attribute record"
          end

          row[:nocow] = flags[1].include?("C")
          row[:outcome] = row[:nocow] ? "healthy" : "warning"
        else
          row[:outcome] = "not_applicable"
        end
        raise ProbeError, "lstat: path changed during inspection" unless same_inode?(status, File.lstat(path))

        row
      rescue ProbeError, SystemCallError, IOError => error
        row.merge(outcome: "indeterminate", nocow: nil, reason: error.message)
      end

      def same_inode?(a, b) = a.dev == b.dev && a.ino == b.ino

      def lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def probe(name, *args)
        result = @runner.call(name, *args)
        raise ProbeError, "#{name} returned invalid output" unless result.is_a?(String) && result.valid_encoding?
        result
      rescue Timeout::Error
        raise ProbeError, "#{name} timed out"
      rescue SystemCallError, IOError => error
        raise ProbeError, "#{name}: #{error.message}"
      end

      def aggregate(paths)
        outcomes = paths.map { |row| row[:outcome] }
        outcome = if outcomes.first == "absent"
          "uninitialized"
        else
          %w[warning indeterminate healthy not_applicable].find { |value| outcomes.include?(value) }
        end
        messages = []
        advice = []
        paths.each do |row|
          case row[:outcome]
          when "warning"
            messages << "#{row[:path]}: btrfs NOCOW flag C is missing#{": #{row[:reason]}" if row[:reason]}."
            advice << MIGRATION
          when "indeterminate"
            messages << "#{row[:path]}: could not determine NOCOW status (#{row[:reason]})."
            advice << RETRY
          end
        end
        message = case outcome
        when "uninitialized" then "Runtime storage is uninitialized: #{@root} is absent."
        when "healthy" then "NOCOW is set on every applicable runtime storage path."
        when "not_applicable" then "Runtime storage at #{@root} does not require Linux btrfs NOCOW."
        else messages.join(" ")
        end
        { outcome: outcome, paths: paths, message: message, remediation: advice.empty? ? nil : advice.uniq.join(" ") }
      end
    end
  end
end
