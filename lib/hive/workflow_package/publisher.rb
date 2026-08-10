require "fileutils"
require "digest"
require "psych"
require "hive/config"
require "hive/workflow_package/authoring_metadata"
require "hive/workflow_package/authoring_lint"
require "hive/workflow_package/registry_manifest"
require "hive/workflow_package/registry_manifest_builder"
require "hive/workflow_package/publish_resolver"
require "hive/workflow_package/publish_store"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/registry_submission"
require "hive/workflow_package/safe_file"
require "hive/workflow_package/source_snapshot"
require "hive/workflow_package/validator"
require "hive/workflows/loader"

module Hive
  module WorkflowPackage
    class PublishConfigurationError < Hive::ConfigError; end

    class Publisher
      OFFICIAL_REPOSITORY = "ivankuznetsov/honeycomb".freeze
      METADATA_FILE = "honeycomb.yml".freeze
      README_FILE = "README.md".freeze
      class Package < Data.define(
        :name, :version, :root, :package_digest, :release_digest, :warnings,
        :lint_contract, :findings
      )
        def initialize(name:, version:, root:, package_digest: nil, release_digest: nil,
                       manifest_digest: nil, warnings: [], lint_contract: nil, findings: [])
          release_digest ||= manifest_digest
          package_digest ||= manifest_digest
          super(
            name: name, version: version, root: root,
            package_digest: package_digest, release_digest: release_digest,
            warnings: warnings.freeze, lint_contract: lint_contract,
            findings: findings.freeze
          )
        end

        def manifest_digest = release_digest
        def registry_path = "packages/#{name}/#{version}"
        def mutation_blocked? = findings.any? { |finding| finding["severity"] == "error" }
      end

      def initialize(name, project_root:, version:, submission: nil, resolver: nil, store: nil, config: nil)
        @name = name.to_s
        @project_root = File.expand_path(project_root)
        @version = version.to_s
        @submission = submission
        @resolver = resolver
        @store = store
        @config = config
      end

      def package(destination:)
        build_validated_package(destination: destination, lint_policy: LintPolicy.load)
      end

      def publish(package)
        components = publication_components
        receipt = components.fetch(:store).load(components.fetch(:registry), package.name, package.version)
        if receipt&.last_completed_step == "pr_verified"
          return components.fetch(:resolver).resolve(receipt)
        end
        submitted = components.fetch(:submission).submit(
          package, allow_mutation: !package.mutation_blocked?
        )
        components.fetch(:resolver).resolve(submitted.receipt)
      end

      # Real publication adopts a valid retained receipt before consulting
      # mutable authored files. When those files still exist, rebuilding them
      # remains a mandatory digest assertion. Dry-run intentionally calls
      # #package directly and therefore cannot touch durable state.
      def prepare(destination:)
        validate_identity!
        registry, = publication_destination
        return package(destination: destination) unless retained_receipt_path?(registry)

        components = publication_components
        receipt = components.fetch(:store).load(registry, @name, @version)
        raise PublishRecoveryError, "publication receipt disappeared during recovery" unless receipt

        root = components.fetch(:store).verify_bundle(receipt)
        manifest = RegistryManifest.load(File.join(root, RegistryManifest::FILE_NAME))
        recorded_policy = LintPolicy.load_version(receipt.lint_contract.fetch("version"))
        unless recorded_policy.identity == receipt.lint_contract
          raise PublishRecoveryError, "recorded Honeycomb lint policy evidence is unavailable or changed"
        end
        recorded_lint = AuthoringLint.verify(root, manifest: manifest, policy: recorded_policy)
        unless recorded_lint.valid?
          raise PublishRecoveryError, "retained publication bundle no longer matches its recorded lint evidence"
        end
        current_lint = AuthoringLint.verify(root, manifest: manifest, policy: LintPolicy.load)
        if authored_inputs_available?
          rebuilt = build_validated_package(destination: destination, lint_policy: recorded_policy)
          unless rebuilt.package_digest == receipt.package_digest && rebuilt.release_digest == receipt.release_digest
            raise PublishConflict, "authored workflow bytes conflict with the retained immutable submission"
          end
        end
        Package.new(
          name: receipt.name, version: receipt.version, root: root,
          package_digest: receipt.package_digest, release_digest: receipt.release_digest,
          warnings: current_lint.findings.map(&:to_h), findings: current_lint.findings.map(&:to_h),
          lint_contract: receipt.lint_contract
        ).freeze
      end

      def receipt_for(package)
        components = publication_components
        components.fetch(:store).load(components.fetch(:registry), package.name, package.version)
      end

      private

      def build_validated_package(destination:, lint_policy:)
        validate_identity!
        destination = File.expand_path(destination)
        ensure_empty_destination!(destination)
        metadata = load_metadata
        snapshot = SourceSnapshot.capture(
          name: @name, workflows_dir: workflows_dir, descriptor_path: descriptor_path,
          authored_dir: authored_dir, metadata: metadata
        )
        AuthoringMetadata.validate_readme!(snapshot.files.fetch(README_FILE).bytes, path: README_FILE)
        build = RegistryManifestBuilder.build!(
          destination: destination, name: @name, version: @version,
          metadata: metadata, snapshot: snapshot
        )
        result = Validator.validate!(
          destination, expected_name: @name,
          expected_manifest_digest: build.release_digest
        )
        lint = AuthoringLint.verify!(destination, manifest: build.manifest, policy: lint_policy)
        warnings = result.warnings.map { |warning| publication_finding(warning) } + lint.warnings.map(&:to_h)
        Package.new(
          name: @name, version: @version, root: destination,
          package_digest: build.package_digest,
          release_digest: build.release_digest,
          warnings: warnings.freeze,
          lint_contract: lint.contract,
          findings: (result.diagnostics.map { |finding| publication_finding(finding) } + lint.findings.map(&:to_h)).freeze
        ).freeze
      end

      def publication_finding(diagnostic)
        {
          "rule_id" => diagnostic.rule_id, "severity" => diagnostic.severity.to_s,
          "path" => diagnostic.path, "line" => diagnostic.line,
          "column" => diagnostic.column, "message" => diagnostic.message
        }.compact.freeze
      end

      def publication_components
        return @publication_components if @publication_components
        registry, base_branch = publication_destination
        store = @store || PublishStore.new
        gateway = RegistryGateway.new
        submission = @submission || RegistrySubmission.new(
          registry: registry, base_branch: base_branch, gateway: gateway, store: store
        )
        catalogue = RegistryClient.new(
          repository: "https://github.com/#{registry}.git", branch: base_branch
        )
        resolver = @resolver || PublishResolver.new(
          registry: registry, gateway: gateway, catalogue: catalogue, store: store
        )
        @publication_components = {
          registry: registry, store: store, submission: submission, resolver: resolver
        }.freeze
      end

      def publication_destination
        config = @config || Hive::Config.load(@project_root)
        honeycomb = config.fetch("honeycomb", {})
        repository = honeycomb.fetch("repository", OFFICIAL_REPOSITORY).to_s
        branch = honeycomb.fetch("base_branch", "main").to_s
        unless PublishReceipt::REPOSITORY.match?(repository)
          raise PublishConfigurationError, "Honeycomb registry repository must be owner/name"
        end
        unless PublishReceipt::BRANCH.match?(branch)
          raise PublishConfigurationError, "Honeycomb registry base branch is invalid"
        end
        [ repository, branch ]
      rescue PublishConfigurationError
        raise
      rescue Hive::ConfigError, KeyError, TypeError
        raise PublishConfigurationError, "Honeycomb registry configuration is invalid"
      end

      def retained_receipt_path?(registry)
        key = ::Digest::SHA256.hexdigest([ registry, @name, @version ].join("\0"))
        path = File.join(Hive::Paths.workflow_publish_receipts_root, "#{key}.json")
        File.exist?(path) || File.symlink?(path)
      end

      def authored_inputs_available?
        authored = [ descriptor_path, metadata_path, readme_path ]
        return false unless authored.all? { |path| File.file?(path) && !File.symlink?(path) }

        metadata = load_metadata
        descriptor = AuthoringMetadata.parse_yaml_map(
          SafeFile.read(
            descriptor_path, max_bytes: AuthoringMetadata::MAX_BYTES,
            error_class: Hive::ConfigError,
            message: "workflow descriptor must be a bounded regular file"
          ).first,
          label: "workflow descriptor"
        )
        referenced = descriptor_references(descriptor).map do |value|
          File.expand_path(value, workflows_dir)
        end
        assets = metadata.assets.map { |value| File.expand_path(value, authored_dir) }
        (referenced + assets).all? { |path| File.file?(path) && !File.symlink?(path) }
      rescue Psych::Exception, Errno::ENOENT, Errno::EACCES, IOError
        false
      rescue Hive::ConfigError
        true
      end

      def validate_identity!
        unless RegistryManifest::NAME.match?(@name)
          raise Hive::ConfigError, "workflow publish id is not a valid Honeycomb registry name"
        end
        unless RegistryManifest::SEMVER.match?(@version)
          raise Hive::ConfigError, "workflow publish requires --version with a semantic version such as 1.2.3"
        end
        if @version.include?("+")
          raise Hive::ConfigError,
                "workflow publish versions cannot contain build metadata because equal-precedence releases collide"
        end
      end

      def ensure_empty_destination!(destination)
        return unless File.exist?(destination) && !Dir.empty?(destination)

        raise Hive::ConfigError, "workflow package destination must be empty"
      end

      def workflows_dir
        @workflows_dir ||= Hive::Workflows::Loader.workflow_dir(@project_root)
      end

      def descriptor_path = File.join(workflows_dir, "#{@name}.yml")
      def authored_dir = File.join(workflows_dir, @name)
      def readme_path = File.join(authored_dir, README_FILE)
      def metadata_path = File.join(authored_dir, METADATA_FILE)

      def load_metadata
        AuthoringMetadata.load(metadata_path)
      end

      def descriptor_references(value)
        case value
        when Hash
          value.flat_map do |key, child|
            key == "instruction" ? [ child ] : descriptor_references(child)
          end
        when Array
          value.flat_map { |child| descriptor_references(child) }
        else
          []
        end
      end
    end
  end
end
