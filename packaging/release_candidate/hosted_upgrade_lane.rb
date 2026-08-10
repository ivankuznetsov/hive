# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "baseline_catalog"
require_relative "installed_target"
require_relative "upgrade_survivor"

module HiveReleaseCandidate
  # Entrypoint used only after a hosted job has staged authenticated packages
  # and entered the disposable /repo:ro, /cache:ro, /run:rw sandbox contract.
  # All roots are runner-owned constants; callers select only reviewed row and
  # platform identifiers plus the exact candidate SHA.
  class HostedUpgradeLane
    ROOTS = {
      "repo" => "/repo",
      "cache" => "/cache",
      "run" => "/run"
    }.freeze

    def initialize(roots: {
      "repo" => ENV.fetch("HIVE_RC_REPO_ROOT", ROOTS.fetch("repo")),
      "cache" => ENV.fetch("HIVE_RC_CACHE_ROOT", ROOTS.fetch("cache")),
      "run" => ENV.fetch("HIVE_RC_RUN_ROOT", ROOTS.fetch("run"))
    })
      @roots = roots.transform_keys(&:to_s).freeze
    end

    def call(row_id:, platform:, candidate_sha:)
      raise UsageError, "candidate SHA must be exact" unless SAFE_SHA.match?(candidate_sha.to_s)
      catalog = BaselineCatalog.load(
        File.join(@roots.fetch("repo"), "packaging/release_candidate/baselines.yml")
      )
      row = catalog.fetch(row_id)
      unless row.required_platforms.include?(platform)
        raise UsageError, "#{row.id} does not declare platform #{platform.inspect}"
      end
      candidate_manifest = read_json(
        File.join(@roots.fetch("run"), "candidate", "manifest.json")
      )
      unless candidate_manifest["candidate_sha"] == candidate_sha
        raise Error, "hosted lane candidate manifest SHA mismatch"
      end
      sandbox = read_json(File.join(@roots.fetch("run"), "sandbox-attestation.json"))
      cache = read_json(File.join(@roots.fetch("run"), "baseline-cache-attestation.json"))
      targets = target_roles(row).to_h do |role|
        [
          role,
          InstalledTarget.new(
            role: role,
            root: File.join(@roots.fetch("run"), "targets", row.id, role),
            state_root: File.join(@roots.fetch("run"), "state", row.id)
          )
        ]
      end
      upgrade_parent = File.join(@roots.fetch("run"), "upgrade", row.id)
      FileUtils.mkdir_p(upgrade_parent, mode: 0o700)
      UpgradeSurvivor.new(
        catalog: catalog, targets: targets,
        run_root: File.join(@roots.fetch("run"), "upgrade", row.id, platform),
        sandbox_contract: sandbox, cache_contract: cache,
        candidate_manifest: candidate_manifest
      ).run(row_id: row.id, platform: platform)
    end

    def self.exit_code_for(result)
      case result["status"]
      when "passed" then 0
      when "unavailable" then 69
      else 1
      end
    end

    private

    def target_roles(row)
      roles = %w[baseline candidate]
      roles.insert(1, "observer") if row.packages.key?("observer")
      roles
    end

    def read_json(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
        raise Error, "hosted lane input must be an owned regular file: #{path}"
      end
      value = JSON.parse(File.binread(path))
      raise Error, "hosted lane input must be a JSON object: #{path}" unless value.is_a?(Hash)
      value
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "cannot read hosted lane input #{path}: #{e.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  row_id, platform, candidate_sha = ARGV
  unless ARGV.length == 3
    warn "usage: ruby packaging/release_candidate/hosted_upgrade_lane.rb ROW PLATFORM CANDIDATE_SHA"
    exit 64
  end
  begin
    result = HiveReleaseCandidate::HostedUpgradeLane.new.call(
      row_id: row_id, platform: platform, candidate_sha: candidate_sha
    )
    puts JSON.generate(result)
    exit HiveReleaseCandidate::HostedUpgradeLane.exit_code_for(result)
  rescue HiveReleaseCandidate::Error => e
    warn "hosted-upgrade-lane: #{e.message}"
    exit e.exit_code
  end
end
