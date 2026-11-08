require "digest"
require "fileutils"
require "timeout"
require "tmpdir"
require "uri"
require "hive/workflow_package/manifest"
require "hive/workflow_package/runtime_policy"
require "hive/workflows/descriptor_parser"

module Hive
  module WorkflowPackage
    # Imports an owner-selected authored tree. No checkout, hooks, filters, or
    # source-provided setup commands are executed while reading Git objects.
    class GitSource
      Snapshot = Data.define(:repository, :ref, :commit, :files, :root)
      RECEIPT = "hive-source.json".freeze

      def initialize(repository:, ref: "HEAD", timeout_sec: 60)
        @repository = repository.to_s
        @ref = ref.to_s
        @timeout_sec = timeout_sec
      end

      def fetch(id, destination:)
        validate_source!
        unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(id.to_s)
          raise Hive::ConfigError, "invalid Git workflow id"
        end
        Dir.mktmpdir("hive-workflow-git-") do |checkout|
          git!("clone", "--quiet", "--bare", "--no-local", "--", @repository, checkout)
          commit = git!("-C", checkout, "rev-parse", "--verify", "--end-of-options", "#{@ref}^{commit}").strip
          raise Hive::ConfigError, "Git source did not resolve to a full commit" unless /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/.match?(commit)

          files = materialize(checkout, commit, id, destination)
          workflow = Hive::Workflows::DescriptorParser.parse_package_file(
            File.join(destination, "#{id}.yml"), package_name: id
          )
          raise Hive::ConfigError, "Git workflow id does not match requested id" unless workflow.id.to_s == id

          Snapshot.new(repository: @repository, ref: @ref, commit: commit, files: files.freeze, root: destination)
        end
      end

      private

      def validate_source!
        valid = if @repository.start_with?("https://", "ssh://")
          uri = URI.parse(@repository)
          uri.host && !uri.host.empty? && !uri.password && !uri.query && !uri.fragment &&
            (uri.scheme != "https" || !uri.userinfo)
        else
          /\A[\w.-]+@[\w.-]+:[\w.\/-]+\z/.match?(@repository) || @repository.start_with?("/")
        end
        if !valid || @repository.match?(/[\x00-\x20\x7f]/)
          raise Hive::ConfigError, "Git source must be an HTTPS/SSH repository or absolute local path, without embedded credentials"
        end
        unless /\A[\w][\w.\/-]*\z/.match?(@ref) && !@ref.include?("..")
          raise Hive::ConfigError, "Git ref must be a branch, tag, or full commit"
        end
      rescue URI::InvalidURIError
        raise Hive::ConfigError, "invalid Git repository URL"
      end

      def materialize(checkout, commit, id, destination)
        rows = git!("-C", checkout, "ls-tree", "-r", "-l", "-z", commit, "--",
                    "workflows/#{id}.yml", "workflows/#{id}/").split("\0")
        raise Hive::ConfigError, "Git workflow exceeds the file-count limit" if rows.size > Manifest::MAX_FILES

        total = 0
        files = rows.to_h do |row|
          metadata, path = row.split("\t", 2)
          mode, type, oid, size = metadata.split
          relative = path&.delete_prefix("workflows/")
          unless %w[100644 100755].include?(mode) && type == "blob" && relative &&
                 (relative == "#{id}.yml" || relative.start_with?("#{id}/")) &&
                 relative.split("/").none? { |part| %w[. .. .git].include?(part) } &&
                 !relative.match?(/[\x00-\x1f\x7f\\]/) && relative.split("/").size <= Manifest::MAX_DEPTH
            raise Hive::ConfigError, "Git workflow contains an unsupported file, symlink, submodule, or path"
          end
          raise Hive::ConfigError, "Git workflow reserves #{RECEIPT} for source provenance" if relative == "#{id}/#{RECEIPT}"
          bytes = Integer(size)
          total += bytes
          if bytes > Manifest::MAX_FILE_BYTES || total > Manifest::MAX_PACKAGE_BYTES
            raise Hive::ConfigError, "Git workflow exceeds the package size limit"
          end
          [ relative, { "oid" => oid, "mode" => mode, "size" => bytes } ]
        end
        raise Hive::ConfigError, "repository must contain workflows/#{id}.yml" unless files.key?("#{id}.yml")

        files.each do |relative, entry|
          bytes = git!("-C", checkout, "cat-file", "blob", entry.delete("oid")).b
          raise Hive::ConfigError, "Git workflow blob size changed" unless bytes.bytesize == entry.fetch("size")
          path = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, bytes)
          File.chmod(entry.fetch("mode") == "100755" ? 0o755 : 0o644, path)
          entry["sha256"] = ::Digest::SHA256.hexdigest(bytes)
        end
        files
      end

      def git!(*args)
        out, _err, status = RuntimePolicy.capture3_bounded(
          "git", *args, timeout_sec: @timeout_sec,
          environment: { "GIT_TERMINAL_PROMPT" => "0", "LC_ALL" => "C" }
        )
        unless status.success?
          # Git/helper stderr can contain credentials. Authentication remains
          # Git's responsibility; do not copy its raw diagnostics into receipts.
          raise Hive::GitError, "Git workflow source could not be read; check repository access and ref using Git"
        end
        out
      rescue Timeout::Error
        raise Hive::GitError, "Git workflow source timed out"
      rescue Errno::ENOENT
        raise Hive::GitError, "Git is required to install a workflow source"
      end
    end
  end
end
