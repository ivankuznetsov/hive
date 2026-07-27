# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "open-uri"
require "tmpdir"
require "bundler"
require "rubygems/package"
require_relative "asset_verifier"
require_relative "baseline_catalog"
require_relative "installed_target"

module HiveReleaseCandidate
  class HostedStage
    def initialize(
      repo_root: ENV.fetch("HIVE_RC_REPO_ROOT", Dir.pwd),
      cache_root: ENV.fetch("HIVE_RC_CACHE_ROOT", "/cache"),
      run_root: ENV.fetch("HIVE_RC_RUN_ROOT", "/run")
    )
      @repo_root = File.expand_path(repo_root)
      @cache_root = File.expand_path(cache_root)
      @run_root = File.expand_path(run_root)
      @catalog = BaselineCatalog.load(
        File.join(@repo_root, "packaging/release_candidate/baselines.yml")
      )
    end

    def fetch(row_id:, platform:, candidate_sha:)
      row, candidate_manifest = inputs(row_id, platform, candidate_sha)
      FileUtils.mkdir_p(@cache_root, mode: 0o700)
      release_assets = stage_packages(row)
      closures = stage_dependency_closures(row)
      closures["candidate"] = stage_candidate_closure
      write_json(
        File.join(@run_root, "staged-inputs.json"),
        {
          "row_id" => row.id,
          "platform" => platform,
          "candidate_sha" => candidate_sha,
          "candidate_manifest_sha256" => Digest::SHA256.hexdigest(JSON.generate(candidate_manifest)),
          "release_assets" => release_assets,
          "closures" => closures
        }
      )
      { "status" => "inputs_staged", "row_id" => row.id, "platform" => platform }
    end

    def install(row_id:, platform:, candidate_sha:)
      row, candidate_manifest = inputs(row_id, platform, candidate_sha)
      staged = read_json(File.join(@run_root, "staged-inputs.json"))
      unless staged["row_id"] == row.id &&
             staged["platform"] == platform &&
             staged["candidate_sha"] == candidate_sha &&
             staged["candidate_manifest_sha256"] ==
               Digest::SHA256.hexdigest(JSON.generate(candidate_manifest))
        raise Error, "hosted staged-input identity mismatch"
      end
      closures = staged.fetch("closures")
      stage_targets(row, candidate_manifest, closures)

      release_assets = staged.fetch("release_assets")
      closure_rows = closures.values
      write_attestations(row, platform, candidate_sha, release_assets, closure_rows)
    end

    private

    def inputs(row_id, platform, candidate_sha)
      raise UsageError, "candidate SHA must be exact" unless SAFE_SHA.match?(candidate_sha.to_s)

      row = @catalog.fetch(row_id)
      unless row.required_platforms.include?(platform)
        raise UsageError, "#{row.id} does not declare platform #{platform.inspect}"
      end
      candidate_manifest = read_json(File.join(@run_root, "candidate", "manifest.json"))
      raise Error, "candidate manifest SHA mismatch" unless candidate_manifest["candidate_sha"] == candidate_sha

      FileUtils.mkdir_p(File.join(@run_root, "targets", row.id), mode: 0o700)
      [ row, candidate_manifest ]
    end

    def write_attestations(row, platform, candidate_sha, release_assets, closures)
      write_json(
        File.join(@run_root, "sandbox-attestation.json"),
        {
          "status" => "available",
          "kind" => platform.start_with?("linux-") ?
            "rootless-read-only-container" : "macos-sandbox-exec",
          "network_after_staging" => "none",
          "repository_mount" => "read_only",
          "cache_mount" => "read_only",
          "run_mount" => "read_write",
          "credentials" => "absent"
        }
      )
      write_json(
        File.join(@run_root, "baseline-cache-attestation.json"),
        {
          "status" => "available",
          "release_assets_sha256" => digest_rows(release_assets),
          "verified_dependency_closure_sha256" => digest_rows(closures),
          "network_after_staging" => "none"
        }
      )
      {
        "status" => "staged",
        "row_id" => row.id,
        "platform" => platform,
        "candidate_sha" => candidate_sha
      }
    end

    def stage_packages(row)
      row.packages.flat_map do |role, package|
        target_role = target_role(role)
        tag_root = File.join(@cache_root, package.fetch("tag"))
        FileUtils.mkdir_p(tag_root, mode: 0o700)
        descriptors = [
          package.fetch("artifact"),
          *%w[checksum signature certificate].map do |kind|
            package.fetch("authentication").fetch(kind)
          end
        ]
        descriptors.each { |descriptor| fetch_exact(descriptor, tag_root) }
        verified = AssetVerifier.new(cache_root: tag_root).verify_authenticated_package!(
          package,
          signature_verifier: method(:verify_signature)
        )
        [ verified.merge("role" => target_role, "tag" => package.fetch("tag")) ]
      end
    end

    def stage_dependency_closures(row)
      locks = row.packages.to_h do |role, package|
        source_root = export_tag(package.fetch("tag"), row.id, role)
        [ role == "observer" ? "observer" : "producer", File.binread(File.join(source_root, "Gemfile.lock")) ]
      end
      offline = row.dependency_closure.fetch("offline_cache")
      manifest_path = File.join(@repo_root, offline.fetch("manifest_path"))
      manifest_content = File.binread(manifest_path)
      unless Digest::SHA256.hexdigest(manifest_content) == offline.fetch("manifest_sha256")
        raise Error, "reviewed offline cache manifest digest mismatch for #{row.id}"
      end
      manifest = JSON.parse(manifest_content)
      gems_root = File.join(@cache_root, "closures", row.id, "gems")
      FileUtils.mkdir_p(gems_root, mode: 0o700)
      manifest.fetch("artifacts").each do |artifact|
        fetch_exact(
          artifact.merge("url" => "https://rubygems.org/downloads/#{artifact.fetch('filename')}"),
          gems_root
        )
      end
      @catalog.verify_dependency_closure!(
        row,
        lock_contents: locks,
        cache_manifest_content: manifest_content,
        artifact_root: gems_root
      )

      row.packages.to_h do |role, package|
        target = target_role(role)
        lock_role = role == "observer" ? "observer" : "producer"
        [
          target,
          {
            "role" => target,
            "tag" => package.fetch("tag"),
            "lock_sha256" => Digest::SHA256.hexdigest(locks.fetch(lock_role)),
            "manifest_sha256" => offline.fetch("manifest_sha256"),
            "gems" => manifest.fetch("artifacts"),
            "root" => gems_root
          }
        ]
      end
    end

    def stage_targets(row, candidate_manifest, closures)
      skills_name, skills_row = candidate_manifest.fetch("files").find do |_name, value|
        value.fetch("kind") == "skills"
      end
      skills = File.join(@run_root, "candidate", skills_name)
      unless Digest::SHA256.file(skills).hexdigest == skills_row.fetch("sha256")
        raise Error, "candidate skills archive digest mismatch"
      end

      row.packages.each do |role, package|
        target_role = target_role(role)
        stage_target(
          row: row, role: target_role, version: package.fetch("version"),
          gem_path: File.join(
            @cache_root, package.fetch("tag"), package.dig("artifact", "filename")
          ),
          skills: skills, closure: closures.fetch(target_role)
        )
      end
      gem_name, gem_row = candidate_manifest.fetch("files").find do |_name, value|
        value.fetch("kind") == "gem"
      end
      stage_target(
        row: row, role: "candidate",
        version: candidate_manifest.fetch("hive_version"),
        gem_path: File.join(@run_root, "candidate", gem_name),
        skills: skills, closure: closures.fetch("candidate"),
        expected_digest: gem_row.fetch("sha256")
      )
    end

    def stage_candidate_closure
      closure_root = File.join(@cache_root, "closures", "candidate")
      gems_root = File.join(closure_root, "gems")
      FileUtils.mkdir_p(gems_root, mode: 0o700)
      lock = File.join(@repo_root, "Gemfile.lock")
      gems = fetch_locked_gems(lock, gems_root)
      raise Error, "candidate dependency closure is empty" if gems.empty?

      {
        "role" => "candidate",
        "tag" => "candidate",
        "lock_sha256" => Digest::SHA256.file(lock).hexdigest,
        "gems" => gems.map do |path|
          {
            "filename" => File.basename(path), "size" => File.size(path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end,
        "root" => gems_root
      }
    end

    def fetch_locked_gems(lock_path, gems_root)
      artifacts = @catalog.runtime_closure_artifacts(
        "candidate" => File.binread(lock_path)
      )
      artifacts.each do |artifact|
        argv = [
          "gem", "fetch", artifact.fetch("name"),
          "--version", artifact.fetch("version")
        ]
        platform = artifact.fetch("platform")
        argv.concat([ "--platform", platform ]) unless platform.empty?
        run!(*argv, chdir: gems_root)
      end
      artifacts.map do |artifact|
        path = File.join(gems_root, artifact.fetch("filename"))
        raise Error, "gem fetch omitted #{artifact.fetch('filename')}" unless File.file?(path)

        path
      end.sort
    end

    def stage_target(row:, role:, version:, gem_path:, skills:, closure:, expected_digest: nil)
      root = File.join(@run_root, "targets", row.id, role)
      FileUtils.mkdir_p(root, mode: 0o700)
      actual_digest = Digest::SHA256.file(gem_path).hexdigest
      raise Error, "#{role} package digest mismatch" if expected_digest && actual_digest != expected_digest

      dependencies = installable_dependencies(closure)
      contract = InstalledTarget.install_contract(
        role: role, install_root: root, gem_path: gem_path, skills_archive: skills,
        offline_cache: closure.fetch("root"), dependency_gems: dependencies
      )
      contract.fetch("dependency_install_argv").each { |argv| run!(*argv) }
      run!(*contract.fetch("gem_install_argv"))
      FileUtils.mkdir_p(File.join(root, "bin"), mode: 0o700)
      wrapper = File.join(root, "rubygems-bin", "hive")
      raise Error, "#{role} install did not produce a hive wrapper" unless File.file?(wrapper)
      FileUtils.cp(wrapper, File.join(root, "bin", "hive"))
      FileUtils.chmod(0o755, File.join(root, "bin", "hive"))
      write_json(
        File.join(root, "target.json"),
        {
          "schema" => "hive-release-candidate-installed-target",
          "schema_version" => SCHEMA_VERSION,
          "role" => role,
          "version" => version,
          "gem_sha256" => actual_digest,
          "executable" => "bin/hive",
          "skills" => {
            "archive_sha256" => Digest::SHA256.file(skills).hexdigest,
            "import_root" => "skills"
          }
        }
      )
    end

    def installable_dependencies(closure)
      records = closure.fetch("gems").map do |record|
        path = File.join(closure.fetch("root"), record.fetch("filename"))
        unless File.size(path) == record.fetch("size") &&
               Digest::SHA256.file(path).hexdigest == record.fetch("sha256")
          raise Error, "#{closure.fetch('role')} dependency closure drift"
        end
        [ record, path, Gem::Package.new(path).spec ]
      end
      records.group_by { |_record, _path, spec| spec.name }.values.map do |variants|
        installable = variants.select do |_record, _path, spec|
          spec.platform == Gem::Platform::RUBY || Gem::Platform.match_spec?(spec)
        end
        selected = installable.find { |_record, _path, spec| spec.platform != Gem::Platform::RUBY } ||
          installable.find { |_record, _path, spec| spec.platform == Gem::Platform::RUBY }
        raise Error, "no installable dependency variant for #{variants.first.last.name}" unless selected

        selected[1]
      end
    end

    def fetch_exact(descriptor, directory)
      path = File.join(directory, descriptor.fetch("filename"))
      unless File.file?(path)
        URI.open(descriptor.fetch("url"), "rb") do |input|
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
            IO.copy_stream(input, output)
          end
        end
      end
      path
    rescue OpenURI::HTTPError, SystemCallError => e
      raise UnavailableError, "cannot stage #{descriptor.fetch('filename')}: #{e.message}"
    end

    def verify_signature(checksum:, signature:, certificate:, issuer:, identity:)
      _stdout, _stderr, status = Open3.capture3(
        "cosign", "verify-blob", "--certificate", certificate,
        "--signature", signature, "--certificate-oidc-issuer", issuer,
        "--certificate-identity", identity, checksum
      )
      status.success?
    rescue Errno::ENOENT
      raise UnavailableError, "cosign is required to authenticate baseline assets"
    end

    def export_tag(tag, row_id, role)
      root = File.join(@cache_root, "sources", row_id, role)
      return root if File.directory?(root)

      FileUtils.mkdir_p(root, mode: 0o700)
      run!("git", "fetch", "--depth=1", "origin", "refs/tags/#{tag}:refs/tags/#{tag}",
           chdir: @repo_root)
      archive = File.join(@cache_root, "sources", "#{row_id}-#{role}.tar")
      run!("git", "archive", "--format=tar", "--output", archive, tag, chdir: @repo_root)
      run!("tar", "-xf", archive, "-C", root)
      root
    end

    def run!(*argv, chdir: @repo_root, env: {})
      _stdout, stderr, status = Open3.capture3(env, *argv, chdir: chdir)
      raise Error, "#{argv.first} failed: #{stderr.strip}" unless status.success?

      true
    end

    def target_role(package_role)
      package_role == "producer" ? "baseline" : package_role
    end

    def digest_rows(rows)
      Digest::SHA256.hexdigest(JSON.generate(rows.sort_by { |row| row.fetch("role") }))
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, Errno::ENOENT => e
      raise Error, "invalid hosted-stage JSON input #{path}: #{e.message}"
    end

    def write_json(path, payload)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(payload))
        file.write("\n")
      end
    rescue Errno::EEXIST
      raise Error, "refusing to replace hosted-stage evidence #{path}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode, row_id, platform, candidate_sha = ARGV
  unless ARGV.length == 4 && %w[fetch install].include?(mode)
    warn "usage: ruby packaging/release_candidate/hosted_stage.rb fetch|install ROW PLATFORM CANDIDATE_SHA"
    exit 64
  end
  begin
    puts JSON.generate(
      HiveReleaseCandidate::HostedStage.new.public_send(
        mode,
        row_id: row_id, platform: platform, candidate_sha: candidate_sha
      )
    )
  rescue HiveReleaseCandidate::Error => e
    warn "hosted-stage: #{e.message}"
    exit e.exit_code
  end
end
