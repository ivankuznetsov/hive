# frozen_string_literal: true

require "digest"
require "open3"
require "time"
require "hive/errors"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/command_schema"
require "hive/runtime_control_plane/database"

module Hive
  module RuntimeControlPlane
    # Rollback coordinates for the command-receipt installation on the dogfood
    # channel. Dogfood builds are never published as release packages; the
    # deploy script instead retains every previous deployment as a detached
    # worktree beside the active one. The rollback target is therefore the
    # newest retained deployment that is a different build, already runs on a
    # database carrying the receipt extension, and is pinned by a digest over
    # its executable code (bin/hive plus the whole lib tree).
    module DogfoodRollbackDeployment
      KIND = "dogfood_deployment"
      DIGEST_SCOPE = "bin/hive+lib"
      MANIFEST_HEADER = "hive-dogfood-rollback-manifest/v1\n"
      DEPLOYMENT_ID_PATTERN = /\Ahive-dogfood-[0-9a-f]{9}\z/
      SHA_PATTERN = /\A[0-9a-f]{40}\z/
      RUNNING_ROOT = File.expand_path("../../..", __dir__).freeze
      # A deployment is receipt-aware when its source pins exactly the receipt
      # extension and base runtime schema this build installs and opens. These
      # are the literals introduced by #1494 (command receipt foundations); a
      # build without them, or with different ones, could refuse the database
      # this installation produces.
      SCHEMA_MARKERS = [
        [ "lib/hive/runtime_control_plane/command_schema.rb",
          /^\s*EXPECTED_SCHEMA_SHA256 = "([0-9a-f]{64})"/, CommandSchema::EXPECTED_SCHEMA_SHA256 ],
        [ "lib/hive/runtime_control_plane/command_schema.rb",
          /^\s*VERSION = (\d+)$/, CommandSchema::VERSION.to_s ],
        [ "lib/hive/runtime_control_plane/command_migrations/002_add_command_receipts.rb",
          /^\s*VERSION = (\d+)$/, CommandSchema::VERSION.to_s ],
        [ "lib/hive/runtime_control_plane/database.rb",
          /^\s*EXPECTED_SCHEMA_SHA256 = "([0-9a-f]{64})"/, RuntimeControlPlane::EXPECTED_SCHEMA_SHA256 ],
        [ "lib/hive/runtime_control_plane.rb",
          /^\s*SCHEMA_VERSION = (\d+)$/, RuntimeControlPlane::SCHEMA_VERSION.to_s ]
      ].freeze
      REASON_LABELS = {
        unreadable_build: "build commit unreadable or not matching its directory name",
        same_build: "same build as the running deployment",
        modified: "tracked files modified",
        no_executable: "no executable bin/hive",
        pre_receipt: "pre-receipt build (no command receipt schema)",
        schema_mismatch: "different receipt or base runtime schema",
        newer: "newer than the running build"
      }.freeze
      MAX_NAMES_PER_REASON = 3

      Candidate = Data.define(:deployment_id, :path, :build_sha, :committed_at)

      module_function

      # Resolve the rollback coordinates for the running dogfood deployment, or
      # raise Hive::ConfigError naming what is missing.
      def resolve!(identity:, running_root: RUNNING_ROOT)
        running = running_deployment!(identity, running_root)
        root = File.dirname(running.path)
        rejected = Hash.new { |hash, key| hash[key] = [] }
        eligible = Dir.children(root).sort.filter_map do |name|
          next unless DEPLOYMENT_ID_PATTERN.match?(name)

          path = File.join(root, name)
          next unless File.directory?(path) && !File.symlink?(path)

          candidate, reason = evaluate(path, running)
          rejected[reason] << name if reason
          candidate
        end
        # The clean-worktree proof costs an index refresh per deployment, so
        # it runs newest-first and stops at the first clean candidate.
        chosen = eligible.sort_by { |candidate| [ candidate.committed_at, candidate.deployment_id ] }
          .reverse.find do |candidate|
            clean?(candidate.path).tap { |clean| rejected[:modified] << candidate.deployment_id unless clean }
          end
        raise Hive::ConfigError, refusal_message(root, running, rejected) unless chosen

        coordinates(chosen)
      end

      def dogfood?(coordinates)
        value = coordinates && (coordinates[:kind] || coordinates["kind"])
        value == KIND
      end

      # Re-prove recorded coordinates immediately before the schema changes:
      # the deployment must still exist, carry the recorded identity, and hash
      # to the recorded digest.
      def verify!(coordinates)
        values = coordinates.transform_keys(&:to_sym)
        deployment_id = values[:deployment_id].to_s
        path = values[:path].to_s
        sha256 = values[:sha256].to_s
        unless DEPLOYMENT_ID_PATTERN.match?(deployment_id) && File.absolute_path?(path) &&
            File.basename(path) == deployment_id && SHA_PATTERN.match?(values[:build_sha].to_s) &&
            values[:build_sha].to_s.start_with?(deployment_id.delete_prefix("hive-dogfood-")) &&
            sha256.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::ConfigError, "dogfood rollback coordinates are malformed: #{values.inspect}"
        end
        unless File.directory?(path)
          raise Hive::ConfigError, "dogfood rollback deployment #{deployment_id} is no longer retained at #{path}"
        end
        actual = digest(path)
        return coordinates if actual == sha256

        raise Hive::ConfigError,
              "dogfood rollback deployment #{deployment_id} no longer matches its recorded " \
              "#{DIGEST_SCOPE} digest (recorded #{sha256}, now #{actual})"
      end

      # sha256 over a manifest of "<file sha256> <relative path>" lines for
      # bin/hive and every file under lib/, sorted by path. Symlinks hash their
      # target text so a retargeted link changes the digest.
      def digest(path)
        files = [ "bin/hive" ] + Dir.glob("lib/**/*", File::FNM_DOTMATCH, base: path).select do |relative|
          absolute = File.join(path, relative)
          File.symlink?(absolute) || File.file?(absolute)
        end
        manifest = files.sort.map do |relative|
          absolute = File.join(path, relative)
          entry = if File.symlink?(absolute)
            Digest::SHA256.hexdigest("symlink:#{File.readlink(absolute)}")
          elsif File.file?(absolute)
            Digest::SHA256.file(absolute).hexdigest
          else
            "missing"
          end
          "#{entry} #{relative}\n"
        end
        Digest::SHA256.hexdigest(MANIFEST_HEADER + manifest.join)
      end

      def running_deployment!(identity, running_root)
        deployment_id = identity && identity["deployment_id"]
        build_sha = identity && identity["build_sha"]
        unless identity && identity["channel"] == "dogfood" &&
            DEPLOYMENT_ID_PATTERN.match?(deployment_id.to_s) && SHA_PATTERN.match?(build_sha.to_s)
          raise Hive::ConfigError, "dogfood rollback resolution requires a validated dogfood runtime identity"
        end
        path = File.realpath(running_root)
        sha, committed_at = commit(path)
        unless File.basename(path) == deployment_id && sha == build_sha
          raise Hive::ConfigError,
                "running Hive code at #{path} is not dogfood deployment #{deployment_id} " \
                "(build #{build_sha}); run hive through the dogfood entrypoint"
        end
        Candidate.new(deployment_id: deployment_id, path: path, build_sha: sha, committed_at: committed_at)
      end

      def evaluate(path, running)
        sha, committed_at = commit(path)
        name = File.basename(path)
        return [ nil, :unreadable_build ] unless sha && name == "hive-dogfood-#{sha[0, 9]}"
        return [ nil, :same_build ] if sha == running.build_sha
        return [ nil, :no_executable ] unless File.file?(File.join(path, "bin/hive")) &&
          File.executable?(File.join(path, "bin/hive"))

        schema = schema_compatibility(path)
        return [ nil, schema ] unless schema == :compatible
        return [ nil, :newer ] if committed_at > running.committed_at

        [ Candidate.new(deployment_id: name, path: path, build_sha: sha, committed_at: committed_at), nil ]
      end

      def schema_compatibility(path)
        SCHEMA_MARKERS.each do |relative, pattern, expected|
          file = File.join(path, relative)
          return :pre_receipt unless File.file?(file)

          match = File.read(file).match(pattern)
          return :schema_mismatch unless match && match[1] == expected
        end
        :compatible
      end

      def commit(path)
        output, status = Open3.capture2e("git", "-C", path, "log", "-1", "--format=%H %ct", "HEAD")
        sha, timestamp = output.split
        return [ nil, nil ] unless status.success? && SHA_PATTERN.match?(sha.to_s)

        [ sha, Integer(timestamp) ]
      end

      def clean?(path)
        _output, status = Open3.capture2e("git", "-C", path, "diff", "--quiet", "--no-ext-diff", "HEAD", "--")
        status.success?
      end

      def coordinates(candidate)
        {
          kind: KIND,
          deployment_id: candidate.deployment_id,
          path: candidate.path,
          build_sha: candidate.build_sha,
          committed_at: Time.at(candidate.committed_at).utc.iso8601,
          digest_scope: DIGEST_SCOPE,
          sha256: digest(candidate.path)
        }
      end

      def refusal_message(root, running, rejected)
        prefix = "dogfood channel: no eligible previous dogfood deployment under #{root} to serve as the " \
          "command receipt rollback target for #{running.deployment_id}"
        if rejected.keys == [ :same_build ]
          return "#{prefix}; only the running deployment is retained. Deploy the next " \
            "receipt-aware build with hive-dogfood-deploy and install from it, so this one " \
            "stays available as the rollback target"
        end

        details = rejected.map do |reason, names|
          shown = names.first(MAX_NAMES_PER_REASON).join(", ")
          shown += " (+#{names.length - MAX_NAMES_PER_REASON} more)" if names.length > MAX_NAMES_PER_REASON
          "#{REASON_LABELS.fetch(reason)}: #{shown}"
        end
        "#{prefix}; a target must be a different build, clean, and pin receipt schema v" \
          "#{CommandSchema::VERSION} #{CommandSchema::EXPECTED_SCHEMA_SHA256[0, 12]} on base schema " \
          "#{RuntimeControlPlane::EXPECTED_SCHEMA_SHA256[0, 12]}. Rejected: #{details.join('; ')}"
      end
    end
  end
end
