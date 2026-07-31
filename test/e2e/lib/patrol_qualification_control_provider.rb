require "digest"
require "open3"
require "hive/errors"
require "hive/modules/migration/trusted_qualification_control"

module Hive
  module E2E
    # Builds a non-qualifying control identity from the current local checkout.
    # A trusted_remote control is intentionally not available here: only a
    # protected host launcher may translate authenticated workflow provenance
    # into that stronger trust scope.
    class PatrolQualificationControlProvider
      CATALOG_REF =
        "test/e2e/fixtures/patrol_qualification/catalog.json".freeze
      HARNESS_MANIFEST_REF =
        "test/e2e/fixtures/patrol_qualification/" \
        "harness-manifest.json".freeze
      def initialize(
        repo_root:,
        catalog_ref: CATALOG_REF,
        harness_manifest_ref: HARNESS_MANIFEST_REF
      )
        @repo_root = File.expand_path(repo_root)
        @catalog_ref = catalog_ref.to_s
        @harness_manifest_ref = harness_manifest_ref.to_s
      end

      def call(candidate_sha:)
        commit_sha = git!("rev-parse", "--verify", "HEAD").strip
        unavailable! unless commit_sha == candidate_sha.to_s
        tree_sha =
          git!("rev-parse", "--verify", "#{commit_sha}^{tree}").strip
        repository = repository_identity(
          git!("remote", "get-url", "origin").strip
        )
        catalog = committed_file(commit_sha, @catalog_ref)
        harness_manifest =
          committed_file(commit_sha, @harness_manifest_ref)
        Hive::Modules::Migration::TrustedQualificationControl.build(
          repository: repository,
          ref: nil,
          commit_sha: commit_sha,
          tree_sha: tree_sha,
          trust_scope: "local",
          catalog_ref: @catalog_ref,
          catalog_sha256: Digest::SHA256.hexdigest(catalog),
          harness_manifest_sha256:
            Digest::SHA256.hexdigest(harness_manifest),
          provenance: {
            "workflow_path" => nil,
            "workflow_sha" => nil,
            "run_id" => nil,
            "run_attempt" => nil,
            "action_lock_sha256" => nil
          },
          checkout_root: @repo_root
        )
      rescue Hive::ConfigError
        raise
      rescue StandardError
        unavailable!
      end

      private

      def committed_file(commit_sha, ref)
        row =
          git!("ls-tree", commit_sha, "--", ref)
            .strip
            .split(/\s+/, 4)
        unavailable! unless
          row.length == 4 &&
            row.fetch(0) == "100644" &&
            row.fetch(1) == "blob" &&
            row.fetch(3) == ref
        git!("show", "#{commit_sha}:#{ref}").b.freeze
      end

      def repository_identity(remote)
        match = case remote
        when %r{\Ahttps://github\.com/([^/]+)/([^/]+?)(?:\.git)?\z}
          Regexp.last_match
        when %r{\Assh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?\z}
          Regexp.last_match
        when %r{\Agit@github\.com:([^/]+)/([^/]+?)(?:\.git)?\z}
          Regexp.last_match
        end
        unavailable! unless match
        "github.com/#{match[1]}/#{match[2]}".freeze
      end

      def git!(*arguments)
        output, _error, status =
          Open3.capture3("git", *arguments, chdir: @repo_root)
        unavailable! unless status.success?
        output
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        unavailable!
      end

      def unavailable!
        raise Hive::ConfigError,
              "patrol qualification local control is unavailable"
      end
    end
  end
end
