# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "rbconfig"
require "rubygems"
require_relative "asset_verifier"

module HiveReleaseCandidate
  class BaselineCache
    def initialize(repo_root:, repository:)
      @repo_root = File.expand_path(repo_root)
      @repository = repository
    end

    def plan(sha, paths, inputs)
      baseline = inputs.fetch("baselines")
      unless baseline["status"] == "available"
        return {
          "status" => "unavailable",
          "reason" => baseline.fetch("blocker", "baseline_catalog_unavailable"),
          "assets" => [],
          "fetch_argv" => []
        }
      end
      catalog = @repository.baseline_catalog(sha)
      cache_root = File.join(paths.runs_root, "baseline-cache")
      inventory = catalog.package_requirements.flat_map do |requirement|
        tag_root = File.join(cache_root, requirement.fetch("tag"))
        AssetVerifier.new(cache_root: tag_root).inventory(requirement.fetch("descriptors")).map do |item|
          item.merge(
            "row_id" => requirement.fetch("row_id"),
            "role" => requirement.fetch("role"),
            "tag" => requirement.fetch("tag")
          )
        end
      end
      closures = catalog.entries.map { |entry| baseline_closure_plan(catalog, entry, cache_root) }
      missing = inventory.select { |item| item["status"] == "missing" }
      invalid = inventory.select { |item| item["status"] == "invalid" }
      closure_invalid = closures.select { |item| item["status"] == "invalid" }
      closure_missing = closures.select { |item| item["status"] == "missing" }
      attestation = baseline_cache_attestation(catalog, cache_root, inventory, closures)
      status = if invalid.any? || closure_invalid.any? || attestation["status"] == "invalid"
                 "invalid"
      elsif missing.any? || closure_missing.any? || attestation["status"] == "missing"
                 "missing"
      else
                 "available"
      end
      reason = if invalid.any? || closure_invalid.any? || attestation["status"] == "invalid"
                 "baseline_assets_invalid"
      elsif missing.any? || closure_missing.any?
                 "baseline_assets_missing"
      elsif attestation["status"] == "missing"
                 "baseline_cache_authentication_missing"
      end
      {
        "status" => status,
        "reason" => reason,
        "cache_root" => relative_repo_path(cache_root),
        "assets" => inventory,
        "closures" => closures,
        "authentication" => attestation,
        "verified_dependency_closure_sha256" =>
          attestation["status"] == "verified" ?
            attestation.fetch("verified_dependency_closure_sha256") : nil,
        "release_assets_sha256" =>
          attestation["status"] == "verified" ?
            attestation.fetch("release_assets_sha256") : nil,
        "fetch_argv" => [
          *(missing.empty? ? [] : catalog.fetch_argv(cache_root: cache_root, missing: missing)),
          *((closure_missing.empty? && attestation["status"] != "missing") ? [] : [ [
            RbConfig.ruby,
            "packaging/release_candidate/materialize_baseline_cache.rb",
            sha,
            cache_root
          ] ])
        ],
        "next_action_argv" => status == "available" ? nil : [
          "bin/hive-release-candidate", "dispatch", "--sha", sha
        ]
      }
    rescue Error => e
      {
        "status" => "unavailable",
        "reason" => "baseline_cache_invalid",
        "diagnostic" => e.message,
        "assets" => [],
        "fetch_argv" => []
      }
    end

    def blockers(candidate_version:, baseline_version:, baseline_cache:)
      blockers = [ "remote_validation_required" ]
      if baseline_version
        candidate = Gem::Version.new(candidate_version)
        baseline = Gem::Version.new(baseline_version)
        blockers << "candidate_not_newer" unless candidate > baseline
      end
      blockers << baseline_cache.fetch("reason") unless baseline_cache["status"] == "available"
      blockers
    rescue ArgumentError
      blockers << "candidate_version_invalid"
      blockers
    end

    private

    def baseline_cache_attestation(catalog, cache_root, inventory, closures)
      path = File.join(cache_root, "attestations", "#{catalog.digest}.json")
      return { "status" => "missing", "path" => relative_repo_path(path) } unless File.exist?(path) || File.symlink?(path)

      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
        raise Error, "baseline cache attestation must be an owned regular file"
      end
      document = JSON.parse(File.binread(path))
      expected_keys = %w[
        baseline_catalog_sha256 release_assets_sha256 rows schema schema_version
        verified_dependency_closure_sha256
      ]
      release_assets_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        inventory.map do |item|
          unless item["status"] == "verified"
            raise Error, "baseline cache attestation cannot cover unverified release assets"
          end
          [
            item.fetch("tag"), item.fetch("filename"),
            item.fetch("sha256"), item.fetch("size")
          ]
        end.sort
      ))
      closure_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        closures.sort_by { |row| row.fetch("row_id") }.map do |row|
          unless row["status"] == "verified"
            raise Error, "baseline cache attestation cannot cover unverified dependency closures"
          end
          row.fetch("sha256")
        end
      ))
      unless document.is_a?(Hash) && document.keys.sort == expected_keys.sort &&
             document["schema"] == "hive-release-candidate-baseline-cache-attestation" &&
             document["schema_version"] == 1 &&
             document["baseline_catalog_sha256"] == catalog.digest &&
             document["rows"] == catalog.entries.map(&:id).sort &&
             document["release_assets_sha256"] == release_assets_sha256 &&
             document["verified_dependency_closure_sha256"] == closure_sha256
        raise Error, "baseline cache attestation identity mismatch"
      end
      {
        "status" => "verified",
        "path" => relative_repo_path(path),
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "release_assets_sha256" => release_assets_sha256,
        "verified_dependency_closure_sha256" => closure_sha256
      }
    rescue Error, JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
      {
        "status" => "invalid",
        "path" => relative_repo_path(path),
        "reason" => "baseline_cache_attestation_invalid",
        "diagnostic" => e.message
      }
    end

    def baseline_closure_plan(catalog, entry, cache_root)
      closure_root = File.join(cache_root, "closures", entry.id)
      lock_paths = {
        "producer" => File.join(closure_root, "producer.Gemfile.lock")
      }
      if entry.dependency_closure["observer_lock"]
        lock_paths["observer"] = File.join(closure_root, "observer.Gemfile.lock")
      end
      manifest_path = File.join(
        closure_root,
        entry.dependency_closure.fetch("offline_cache").fetch("manifest_filename")
      )
      gems_root = File.join(closure_root, "gems")
      required_paths = [ *lock_paths.values, manifest_path, gems_root ]
      missing = required_paths.reject do |path|
        File.exist?(path) || File.symlink?(path)
      end
      unless missing.empty?
        return {
          "row_id" => entry.id,
          "status" => "missing",
          "reason" => "offline_dependency_closure_missing",
          "required_paths" => required_paths.map do |path|
            relative_repo_path(path)
          end
        }
      end
      lock_contents = lock_paths.to_h { |role, path| [ role, File.binread(path) ] }
      manifest_content = File.binread(manifest_path)
      expected_manifest = entry.dependency_closure.fetch("offline_cache").fetch("manifest_sha256")
      unless Digest::SHA256.hexdigest(manifest_content) == expected_manifest
        raise Error, "#{entry.id} reviewed offline cache manifest digest mismatch"
      end
      catalog.verify_dependency_closure!(
        entry,
        lock_contents: lock_contents,
        cache_manifest_content: manifest_content,
        artifact_root: gems_root
      )
      {
        "row_id" => entry.id,
        "status" => "verified",
        "sha256" => Digest::SHA256.hexdigest(
          lock_contents.keys.sort.map do |role|
            Digest::SHA256.hexdigest(lock_contents.fetch(role))
          end.join +
          Digest::SHA256.hexdigest(manifest_content)
        )
      }
    rescue Error, Errno::ENOENT, Errno::EACCES => e
      {
        "row_id" => entry.id,
        "status" => "invalid",
        "reason" => "offline_dependency_closure_invalid",
        "diagnostic" => e.message
      }
    end

    def relative_repo_path(path)
      Pathname.new(path).relative_path_from(Pathname.new(@repo_root)).to_s
    end
  end
end
