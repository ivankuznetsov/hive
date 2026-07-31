# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
require "tmpdir"
require_relative "../release_candidate/artifacts"
require_relative "../release_candidate/baseline_catalog"
require_relative "../../lib/hive/modules/migration/migration_repository"
require_relative "../../lib/hive/workflow_package/canonical_json"

module HivePatrolEvidence
  class Error < HiveReleaseCandidate::Error; end

  class CleanupFailure < Error
    attr_reader :primary, :cleanup

    def initialize(primary:, cleanup:)
      @primary = primary
      @cleanup = cleanup
      super(
        "candidate preparation failed " \
        "(#{primary.class}: #{primary.message}); " \
        "staging cleanup failed " \
        "(#{cleanup.class}: #{cleanup.message})"
      )
    end
  end

  # Builds the qualification inputs from one clean, committed checkout. The
  # release-candidate builder owns the four candidate artifacts. This class
  # adds the exact offline runtime closure and converts the installed tree into
  # the repository snapshot contract consumed by QualificationInstalledTarget.
  class CandidatePreparer
    Result = Data.define(
      :candidate_sha, :version, :manifest_bytes, :inputs, :digests
    )

    INPUT_ROOT = "inputs/candidate".freeze
    INSTALLED_ROOT = "inputs/installed-target".freeze
    EXECUTABLE = "bin/hive".freeze
    TARGET_MANIFEST = "target.json".freeze
    ARTIFACT_KINDS = %w[gem skills source web].freeze
    DIGEST_KEYS = %w[
      artifact_manifest_sha256 candidate_gem_sha256
      installed_tree_sha256 skills_archive_sha256 source_archive_sha256
    ].freeze
    SHA256 = /\A[0-9a-f]{64}\z/.freeze

    attr_reader :repo_root, :workspace

    def initialize(
      repo_root:, workspace:,
      gem_cache_roots: Gem.path.map { |path| File.join(path, "cache") },
      artifacts_class: HiveReleaseCandidate::Artifacts,
      catalog_class: HiveReleaseCandidate::BaselineCatalog,
      stage_remover: nil
    )
      @repo_root = File.expand_path(repo_root)
      @workspace = File.expand_path(workspace)
      @gem_cache_roots = Array(gem_cache_roots).map do |path|
        File.expand_path(path)
      end.uniq.freeze
      @artifacts_class = artifacts_class
      @catalog_class = catalog_class
      @stage_remover =
        stage_remover ||
        FileUtils.method(:remove_entry_secure)
    end

    def call
      validate_roots!
      candidate_sha = clean_head!
      artifact_dir = File.join(workspace, "candidate-artifacts")
      target_dir = File.join(workspace, "installed-target")
      reject_collision!(artifact_dir, "candidate artifact")
      reject_collision!(target_dir, "installed target")

      artifacts = @artifacts_class.new(
        repo_root: repo_root,
        candidate_sha: candidate_sha,
        candidate_dir: artifact_dir
      )
      manifest = artifacts.call
      verified = artifacts.verify!
      unless manifest == verified
        raise Error, "candidate artifact verification changed the manifest"
      end
      manifest = validate_artifact_manifest(verified, candidate_sha)
      manifest_bytes =
        Hive::WorkflowPackage::CanonicalJSON.generate(manifest).b.freeze
      artifact_inputs, artifact_rows =
        snapshot_candidate_artifacts(
          artifact_dir, manifest, manifest_bytes
        )

      dependency_rows = runtime_dependency_rows(candidate_sha)
      dependency_gems = resolve_cached_dependencies(dependency_rows)
      validate_candidate_gem!(
        artifact_rows.fetch("gem"),
        version: manifest.fetch("hive_version")
      )
      install_candidate!(
        destination: target_dir,
        candidate_gem: artifact_rows.fetch("gem").fetch(:path),
        dependency_gems: dependency_gems,
        version: manifest.fetch("hive_version"),
        gem_sha256: artifact_rows.fetch("gem").fetch(:sha256),
        skills_sha256: artifact_rows.fetch("skills").fetch(:sha256)
      )
      installed_inputs, installed_tree_sha256 =
        snapshot_installed_target(target_dir)
      inputs = normalize_inputs(artifact_inputs.merge(installed_inputs))
      ensure_head_unchanged!(candidate_sha)

      digests = {
        "artifact_manifest_sha256" =>
          Digest::SHA256.hexdigest(manifest_bytes),
        "source_archive_sha256" =>
          artifact_rows.fetch("source").fetch(:sha256),
        "candidate_gem_sha256" =>
          artifact_rows.fetch("gem").fetch(:sha256),
        "skills_archive_sha256" =>
          artifact_rows.fetch("skills").fetch(:sha256),
        "installed_tree_sha256" => installed_tree_sha256
      }
      unless digests.keys.sort == DIGEST_KEYS
        raise Error, "candidate digest contract is incomplete"
      end

      Result.new(
        candidate_sha: candidate_sha.freeze,
        version: manifest.fetch("hive_version").dup.freeze,
        manifest_bytes: manifest_bytes,
        inputs: inputs,
        digests: immutable(digests)
      )
    rescue Error
      raise
    rescue HiveReleaseCandidate::Error => error
      normalized = Error.new(
        error.message,
        exit_code: error.exit_code,
        kind: error.kind
      )
      raise normalized, cause: error
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError,
           ArgumentError, SystemCallError, Gem::Package::Error => e
      raise Error, "cannot prepare patrol evidence candidate: #{e.message}"
    end

    private

    def validate_roots!
      secure_directory!(repo_root, "repository root", private: false)
      top = git!("rev-parse", "--show-toplevel").strip
      unless File.expand_path(top) == repo_root
        raise Error, "repository root is not the current Git worktree"
      end
      secure_directory!(workspace, "candidate workspace", private: true)
      raise Error, "candidate workspace cannot be the repository root" if workspace == repo_root
    end

    def clean_head!
      candidate_sha =
        git!("rev-parse", "--verify", "HEAD^{commit}").strip.downcase
      unless HiveReleaseCandidate::SAFE_SHA.match?(candidate_sha)
        raise Error, "candidate HEAD is not an exact commit"
      end
      status =
        git!("status", "--porcelain=v1", "--untracked-files=all")
      unless status.empty?
        raise Error, "candidate checkout must be clean before qualification"
      end
      candidate_sha
    end

    def ensure_head_unchanged!(candidate_sha)
      current =
        git!("rev-parse", "--verify", "HEAD^{commit}").strip.downcase
      tracked =
        git!("status", "--porcelain=v1", "--untracked-files=all")
      return if current == candidate_sha && tracked.empty?

      raise Error, "candidate checkout changed during qualification preparation"
    end

    def git!(*argv)
      stdout, stderr, status =
        Open3.capture3("git", *argv, chdir: repo_root)
      return stdout if status.success?

      detail = stderr.to_s.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise Error, "git #{argv.first} failed: #{detail}"
    end

    def git_show(candidate_sha, relative)
      git!("show", "#{candidate_sha}:#{relative}")
    end

    def validate_artifact_manifest(value, candidate_sha)
      required = %w[
        builder_revision candidate_sha canonical_digest files hive_version
        schema schema_version skill_version
      ]
      unless value.is_a?(Hash) &&
             value.keys.sort == required &&
             value["schema"] ==
               HiveReleaseCandidate::Artifacts::MANIFEST_SCHEMA &&
             value["schema_version"] ==
               HiveReleaseCandidate::SCHEMA_VERSION &&
             value["candidate_sha"] == candidate_sha &&
             value["hive_version"].is_a?(String) &&
             !value["hive_version"].empty?
        raise Error, "candidate artifact manifest identity is invalid"
      end
      files = value["files"]
      unless files.is_a?(Hash) &&
             files.values.map { |row| row["kind"] }.sort == ARTIFACT_KINDS
        raise Error, "candidate artifact manifest kinds are incomplete"
      end
      immutable(value)
    end

    def snapshot_candidate_artifacts(directory, manifest, manifest_bytes)
      inputs = {
        "#{INPUT_ROOT}/manifest.json" => {
          bytes: manifest_bytes,
          mode: 0o600
        }.freeze
      }
      rows = {}
      manifest.fetch("files").each do |name, record|
        safe_basename!(name, "candidate artifact")
        unless record.is_a?(Hash) &&
               record.keys.sort == %w[kind sha256 size] &&
               ARTIFACT_KINDS.include?(record["kind"]) &&
               SHA256.match?(record["sha256"].to_s) &&
               record["size"].is_a?(Integer) &&
               record["size"] >= 0
          raise Error, "candidate artifact record is malformed: #{name}"
        end
        path = File.join(directory, name)
        bytes = read_regular_file!(
          path, "candidate artifact #{name}",
          max_bytes: qualification_max_file_bytes
        )
        sha256 = Digest::SHA256.hexdigest(bytes)
        unless bytes.bytesize == record["size"] &&
               sha256 == record["sha256"]
          raise Error, "candidate artifact changed after verification: #{name}"
        end
        kind = record.fetch("kind")
        raise Error, "duplicate candidate artifact kind #{kind}" if rows.key?(kind)

        inputs["#{INPUT_ROOT}/#{name}"] = {
          bytes: bytes.freeze,
          mode: 0o600
        }.freeze
        rows[kind] = {
          name: name.freeze,
          path: path.freeze,
          sha256: sha256.freeze
        }.freeze
      end
      [ inputs.freeze, rows.freeze ]
    end

    def runtime_dependency_rows(candidate_sha)
      catalog = @catalog_class.parse(
        git_show(
          candidate_sha,
          "packaging/release_candidate/baselines.yml"
        ),
        source: "#{candidate_sha}:packaging/release_candidate/baselines.yml"
      )
      rows = catalog.runtime_closure_artifacts(
        "candidate" => git_show(candidate_sha, "Gemfile.lock")
      )
      select_installable_dependencies(rows)
    end

    def select_installable_dependencies(rows)
      unless rows.is_a?(Array) && !rows.empty?
        raise Error, "candidate runtime dependency closure is empty"
      end
      normalized = rows.map do |row|
        unless row.is_a?(Hash) &&
               row.keys.sort == %w[filename name platform version] &&
               row.values.all? { |value| value.is_a?(String) && !value.empty? }
          raise Error, "candidate runtime dependency closure is malformed"
        end
        safe_basename!(row.fetch("filename"), "runtime dependency")
        immutable(row)
      end
      normalized.group_by { |row| row.fetch("name") }.
        sort_by(&:first).map do |name, variants|
          if variants.map { |row| row.fetch("version") }.uniq.length != 1
            raise Error, "runtime dependency has conflicting versions: #{name}"
          end
          installable = variants.select do |row|
            platform = Gem::Platform.new(row.fetch("platform"))
            Gem::Platform.match_gem?(platform, name)
          rescue ArgumentError
            false
          end
          selected = installable.min_by do |row|
            platform = Gem::Platform.new(row.fetch("platform"))
            [
              platform == Gem::Platform::RUBY ? 1 : 0,
              row.fetch("platform"),
              row.fetch("filename")
            ]
          end
          unless selected
            raise Error, "no installable dependency variant for #{name}"
          end
          selected
        end.freeze
    end

    def resolve_cached_dependencies(rows)
      roots = existing_cache_roots
      rows.map do |row|
        matches = roots.filter_map do |root|
          path = File.join(root, row.fetch("filename"))
          next unless File.exist?(path) || File.symlink?(path)

          validate_cached_gem!(path, row)
          {
            path: path,
            sha256: Digest::SHA256.file(path).hexdigest
          }
        end
        if matches.empty?
          raise Error,
                "local gem cache is missing #{row.fetch('filename')}"
        end
        digests = matches.map { |match| match.fetch(:sha256) }.uniq
        if digests.length != 1
          raise Error,
                "local gem caches disagree for #{row.fetch('filename')}"
        end
        matches.first.fetch(:path).freeze
      end.freeze
    end

    def existing_cache_roots
      roots = @gem_cache_roots.filter_map do |root|
        next unless File.exist?(root) || File.symlink?(root)

        secure_directory!(root, "local gem cache", private: false)
        root
      end
      raise Error, "no safe local gem cache is available" if roots.empty?

      roots.freeze
    end

    def validate_cached_gem!(path, expected)
      stat = File.lstat(path)
      allowed_owner = [ Process.uid, 0 ].include?(stat.uid)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
             allowed_owner &&
             File.realpath(path) == File.expand_path(path) &&
             stat.size.positive? &&
             stat.size <= qualification_max_file_bytes
        raise Error, "cached gem is unsafe: #{expected.fetch('filename')}"
      end
      spec = Gem::Package.new(path).spec
      unless spec.name == expected.fetch("name") &&
             spec.version.to_s == expected.fetch("version") &&
             spec.platform.to_s == expected.fetch("platform") &&
             spec.full_name == expected.fetch("filename").delete_suffix(".gem")
        raise Error,
              "cached gem identity mismatch: #{expected.fetch('filename')}"
      end
      true
    rescue Errno::ENOENT, Errno::EACCES, Gem::Package::Error => e
      raise Error,
            "cached gem is invalid: #{expected.fetch('filename')}: #{e.message}"
    end

    def validate_candidate_gem!(row, version:)
      path = row.fetch(:path)
      spec = Gem::Package.new(path).spec
      unless spec.name == "hive-cli" &&
             spec.version.to_s == version &&
             Gem::Platform.match_spec?(spec) &&
             spec.full_name == row.fetch(:name).delete_suffix(".gem")
        raise Error, "candidate gem identity does not match its manifest"
      end
      true
    rescue Gem::Package::Error => e
      raise Error, "candidate gem is invalid: #{e.message}"
    end

    def install_candidate!(
      destination:, candidate_gem:, dependency_gems:, version:,
      gem_sha256:, skills_sha256:
    )
      stage = nil
      primary = nil
      begin
        stage = Dir.mktmpdir(".installed-target-", workspace)
        root = File.join(stage, "target")
        Dir.mkdir(root, 0o700)
        home = File.join(stage, "home")
        tmp = File.join(stage, "tmp")
        Dir.mkdir(home, 0o700)
        Dir.mkdir(tmp, 0o700)
        environment = install_environment(
          home: home, tmp: tmp, target: root
        )
        dependency_gems.each do |path|
          gem_install!(path, root, environment)
        end
        gem_install!(candidate_gem, root, environment)
        install_wrapper!(root)
        write_target_manifest!(
          root,
          version: version,
          gem_sha256: gem_sha256,
          skills_sha256: skills_sha256
        )
        validate_installed_tree!(root)
        File.rename(root, destination)
        destination
      rescue StandardError => error
        primary = error
        raise
      ensure
        begin
          cleanup_candidate_stage!(stage)
        rescue StandardError => cleanup
          if primary
            failure = CleanupFailure.new(
              primary: primary,
              cleanup: cleanup
            )
            raise failure, cause: primary
          end
          raise
        end
      end
    end

    def cleanup_candidate_stage!(stage)
      return unless stage &&
                    (
                      File.exist?(stage) ||
                        File.symlink?(stage)
                    )

      @stage_remover.call(stage)
      begin
        File.lstat(stage)
      rescue Errno::ENOENT
        return nil
      end
      raise Error,
            "candidate staging cleanup did not remove its exact root"
    rescue Error
      raise
    rescue StandardError => error
      raise Error,
            "candidate staging cleanup failed: " \
            "#{error.class}: #{error.message}"
    end

    def install_environment(home:, tmp:, target:)
      {
        "HOME" => home,
        "TMPDIR" => tmp,
        "GEM_HOME" => target,
        "GEM_PATH" => target,
        "PATH" => [
          Gem.bindir, "/usr/local/bin", "/usr/bin", "/bin"
        ].uniq.join(":"),
        "BUNDLE_DISABLE_SHARED_GEMS" => "true",
        "BUNDLE_FROZEN" => "true",
        "RUBYGEMS_GEMDEPS" => "-",
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8",
        "TZ" => "UTC"
      }.freeze
    end

    def gem_install!(path, target, environment)
      gem_executable = File.join(Gem.bindir, "gem")
      read_regular_file!(
        gem_executable, "RubyGems executable",
        max_bytes: qualification_max_file_bytes,
        owner: false,
        links: false
      )
      argv = [
        Gem.ruby, gem_executable, "install", path,
        "--install-dir", target,
        "--bindir", File.join(target, "rubygems-bin"),
        "--local", "--ignore-dependencies", "--no-document"
      ]
      _stdout, stderr, status =
        Open3.capture3(
          environment, *argv, chdir: workspace,
          unsetenv_others: true
        )
      return if status.success?

      detail = stderr.to_s.byteslice(-4_096, 4_096).to_s.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise Error, "offline gem install failed for #{File.basename(path)}: #{detail}"
    end

    def install_wrapper!(root)
      source = File.join(root, "rubygems-bin", "hive")
      read_regular_file!(
        source, "installed Hive wrapper",
        max_bytes: qualification_max_file_bytes
      )
      bin = File.join(root, "bin")
      if File.exist?(bin) || File.symlink?(bin)
        stat = File.lstat(bin)
        unless stat.directory? && !stat.symlink? &&
               stat.uid == Process.uid
          raise Error, "installed target bin directory is unsafe"
        end
      else
        Dir.mkdir(bin, 0o700)
      end
      destination = File.join(bin, "hive")
      raise Error, "installed Hive executable already exists" if
        File.exist?(destination) || File.symlink?(destination)

      FileUtils.copy_file(source, destination)
      File.chmod(0o700, destination)
    end

    def write_target_manifest!(root, version:, gem_sha256:, skills_sha256:)
      unless version.is_a?(String) && !version.empty? &&
             SHA256.match?(gem_sha256.to_s) &&
             SHA256.match?(skills_sha256.to_s)
        raise Error, "installed target identity is malformed"
      end
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(
        "schema" => "hive-release-candidate-installed-target",
        "schema_version" => HiveReleaseCandidate::SCHEMA_VERSION,
        "role" => "candidate",
        "version" => version,
        "gem_sha256" => gem_sha256,
        "executable" => EXECUTABLE,
        "skills" => {
          "archive_sha256" => skills_sha256,
          "import_root" => "skills"
        }
      )
      path = File.join(root, TARGET_MANIFEST)
      File.open(
        path, File::WRONLY | File::CREAT | File::EXCL, 0o600
      ) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      bytes
    rescue Errno::EEXIST
      raise Error, "installed target manifest already exists"
    end

    def validate_installed_tree!(root)
      secure_directory!(root, "installed target", private: true)
      executable = File.join(root, EXECUTABLE)
      stat = File.lstat(executable)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
             stat.uid == Process.uid && (stat.mode & 0o111).positive?
        raise Error, "installed Hive executable is unsafe"
      end
      true
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "installed Hive executable is missing"
    end

    def snapshot_installed_target(root)
      snapshots = {}
      total = 0
      Find.find(root) do |path|
        next if path == root

        stat = File.lstat(path)
        relative =
          Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        safe_relative!(relative, "installed target path")
        if stat.symlink?
          raise Error, "installed target contains a symlink: #{relative}"
        end
        if stat.directory?
          unless stat.uid == Process.uid
            raise Error,
                  "installed target directory has the wrong owner: #{relative}"
          end
          next
        end
        unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid
          raise Error, "installed target entry is unsafe: #{relative}"
        end
        if snapshots.size >= qualification_max_files
          raise Error, "installed target exceeds the bounded file count"
        end
        if stat.size > qualification_max_file_bytes
          raise Error, "installed target file exceeds the bounded size: #{relative}"
        end
        bytes = File.binread(path)
        total += bytes.bytesize
        if total > qualification_max_total_bytes
          raise Error, "installed target exceeds the bounded byte size"
        end
        snapshots["#{INSTALLED_ROOT}/#{relative}"] = {
          bytes: bytes.freeze,
          mode: relative == EXECUTABLE ? 0o700 : 0o600
        }.freeze
      end
      unless snapshots.key?("#{INSTALLED_ROOT}/#{EXECUTABLE}") &&
             snapshots.key?("#{INSTALLED_ROOT}/#{TARGET_MANIFEST}")
        raise Error, "installed target is incomplete"
      end
      [ snapshots.freeze, installed_tree_digest(snapshots) ]
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot snapshot installed target: #{e.message}"
    end

    def installed_tree_digest(files)
      digest = Digest::SHA256.new
      digest << "hive-installed-tree-v1\0"
      files.keys.sort.each do |ref|
        snapshot = files.fetch(ref)
        relative = ref.delete_prefix("#{INSTALLED_ROOT}/")
        bytes = snapshot.fetch(:bytes)
        digest << relative << "\0"
        digest << snapshot.fetch(:mode).to_s(8) << "\0"
        digest << bytes.bytesize.to_s << "\0"
        digest << Digest::SHA256.hexdigest(bytes) << "\0"
      end
      digest.hexdigest.freeze
    end

    def normalize_inputs(inputs)
      unless inputs.is_a?(Hash) && !inputs.empty? &&
             inputs.size <= qualification_max_files
        raise Error, "candidate inputs exceed the bounded file count"
      end
      total = 0
      value = inputs.keys.sort.to_h do |ref|
        safe_relative!(ref, "candidate input path")
        snapshot = inputs.fetch(ref)
        unless snapshot.is_a?(Hash) &&
               snapshot.keys.sort == %i[bytes mode] &&
               snapshot.fetch(:bytes).is_a?(String) &&
               [ 0o600, 0o700 ].include?(snapshot.fetch(:mode))
          raise Error, "candidate input snapshot is malformed"
        end
        bytes = snapshot.fetch(:bytes)
        if bytes.bytesize > qualification_max_file_bytes
          raise Error, "candidate input exceeds the bounded file size: #{ref}"
        end
        total += bytes.bytesize
        if total > qualification_max_total_bytes
          raise Error, "candidate inputs exceed the bounded byte size"
        end
        [
          ref.freeze,
          {
            bytes: bytes.b.freeze,
            mode: snapshot.fetch(:mode)
          }.freeze
        ]
      end
      value.freeze
    end

    def secure_directory!(path, label, private:)
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      allowed_owner = [ Process.uid, 0 ].include?(stat.uid)
      unless stat.directory? && !stat.symlink? && allowed_owner &&
             File.realpath(expanded) == expanded &&
             (stat.mode & 0o022).zero?
        raise Error, "#{label} is unsafe"
      end
      if private && (stat.uid != Process.uid || (stat.mode & 0o077).positive?)
        raise Error, "#{label} must be current-user private"
      end
      expanded
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{label} is missing or inaccessible"
    end

    def read_regular_file!(
      path, label, max_bytes:, owner: true, links: true
    )
      stat = File.lstat(path)
      valid_owner = !owner || [ Process.uid, 0 ].include?(stat.uid)
      valid_links = !links || stat.nlink == 1
      unless stat.file? && !stat.symlink? && valid_owner && valid_links &&
             File.realpath(path) == File.expand_path(path) &&
             stat.size <= max_bytes
        raise Error, "#{label} is unsafe"
      end
      File.binread(path)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{label} is missing or inaccessible"
    end

    def reject_collision!(path, label)
      return unless File.exist?(path) || File.symlink?(path)

      raise Error, "#{label} path already exists"
    end

    def safe_basename!(value, label)
      unless value.is_a?(String) && !value.empty? &&
             File.basename(value) == value &&
             !%w[. ..].include?(value) &&
             !value.include?("\0") && !value.include?("\\")
        raise Error, "#{label} path is unsafe"
      end
      value
    end

    def safe_relative!(value, label)
      text = value.to_s
      parts = text.split("/", -1)
      unless !text.empty? && text.bytesize <= 4_096 &&
             !text.start_with?("/") &&
             !text.include?("\\") &&
             !text.include?("\0") &&
             parts.length <= qualification_max_depth &&
             parts.none? { |part| part.empty? || %w[. ..].include?(part) }
        raise Error, "#{label} is unsafe"
      end
      text
    end

    def immutable(value)
      case value
      when Hash
        value.to_h do |key, child|
          [ key.to_s.freeze, immutable(child) ]
        end.freeze
      when Array
        value.map { |child| immutable(child) }.freeze
      when String
        value.dup.freeze
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        raise Error, "candidate identity contains unsupported values"
      end
    end

    def qualification_max_file_bytes
      Hive::Modules::Migration::MigrationRepository::
        MAX_QUALIFICATION_INPUT_BYTES
    end

    def qualification_max_total_bytes
      Hive::Modules::Migration::MigrationRepository::
        MAX_QUALIFICATION_TOTAL_BYTES
    end

    def qualification_max_files
      Hive::Modules::Migration::MigrationRepository::
        MAX_QUALIFICATION_FILES
    end

    def qualification_max_depth
      Hive::Modules::Migration::MigrationRepository::
        MAX_QUALIFICATION_DEPTH
    end
  end
end
