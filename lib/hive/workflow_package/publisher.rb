require "fileutils"
require "json"
require "pathname"
require "tempfile"
require "tmpdir"
require "yaml"
require "hive/gh"
require "hive/workflow_package/manifest"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/validator"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"

module Hive
  module WorkflowPackage
    class PublishError < Hive::Error; end

    class Publisher
      OFFICIAL_REPOSITORY = "ivankuznetsov/honeycomb".freeze
      METADATA_FILE = "honeycomb.yml".freeze
      README_FILE = "README.md".freeze
      PLACEHOLDERS = [ "your name", "describe what this workflow does" ].freeze

      Package = Data.define(:name, :version, :root, :manifest_digest, :warnings)

      def initialize(name, project_root:, version:, pull_request: nil)
        @name = name.to_s
        @project_root = File.expand_path(project_root)
        @version = version.to_s
        @pull_request = pull_request || RegistryPullRequest.new
      end

      def package(destination:)
        validate_identity!
        destination = File.expand_path(destination)
        ensure_empty_destination!(destination)
        descriptor = load_descriptor
        metadata = load_metadata
        validate_authored_metadata!(metadata)

        FileUtils.mkdir_p(destination)
        rewritten, instructions = rewrite_instructions(descriptor)
        File.binwrite(File.join(destination, "workflow.yml"), YAML.dump(rewritten))
        copy_authored_file(readme_path, File.join(destination, README_FILE), label: README_FILE)
        copy_authored_file(metadata_path, File.join(destination, METADATA_FILE), label: METADATA_FILE)
        copy_instructions(instructions, destination)

        manifest = Manifest.build(
          destination,
          metadata: metadata.merge("name" => @name, "version" => @version, "descriptor" => "workflow.yml")
        )
        File.binwrite(File.join(destination, Manifest::FILE_NAME), manifest.bytes)
        result = Validator.validate!(destination, expected_name: @name, expected_manifest_digest: manifest.digest)
        admit_runtime!(result.workflow, manifest.data.fetch("permissions"))
        Package.new(
          name: @name, version: @version, root: destination,
          manifest_digest: manifest.digest,
          warnings: result.warnings.map(&:to_h).freeze
        ).freeze
      rescue StandardError
        FileUtils.rm_rf(destination) if destination
        FileUtils.mkdir_p(destination) if destination
        raise
      end

      def publish(package)
        @pull_request.open(package)
      end

      private

      def validate_identity!
        unless Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(@name)
          raise Hive::ConfigError, "workflow publish requires a valid authored workflow id"
        end
        unless Manifest::SEMVER.match?(@version)
          raise Hive::ConfigError, "workflow publish requires --version with a semantic version such as 1.2.3"
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

      def load_descriptor
        Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
        value = YAML.safe_load(File.read(descriptor_path), aliases: false)
        raise Hive::ConfigError, "authored workflow descriptor must be a map" unless value.is_a?(Hash)

        value
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "authored workflow #{@name.inspect} is missing or unreadable"
      rescue Psych::Exception
        raise Hive::ConfigError, "authored workflow descriptor is invalid YAML"
      end

      def load_metadata
        value = YAML.safe_load(File.read(metadata_path), aliases: false)
        raise Hive::ConfigError, "#{METADATA_FILE} must contain a metadata map" unless value.is_a?(Hash)

        value.to_h { |key, child| [ key.to_s, child ] }
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow publish requires #{metadata_path}"
      rescue Psych::Exception
        raise Hive::ConfigError, "#{METADATA_FILE} is invalid YAML"
      end

      def validate_authored_metadata!(metadata)
        text = [ metadata["summary"], metadata.dig("author", "name") ].join(" ").downcase
        if PLACEHOLDERS.any? { |placeholder| text.include?(placeholder) }
          raise Hive::ConfigError, "edit #{METADATA_FILE} summary and author before publishing"
        end
        unless File.file?(readme_path) && !File.read(readme_path).strip.empty?
          raise Hive::ConfigError, "workflow publish requires a non-empty #{readme_path}"
        end
      rescue Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow publish requires a readable #{readme_path}"
      end

      def rewrite_instructions(descriptor)
        instructions = {}
        rewritten = deep_transform(descriptor) do |key, value|
          next value unless key == "instruction"

          source, relative = resolve_instruction(value)
          packaged = File.join("instructions", relative)
          if instructions.key?(packaged) && instructions.fetch(packaged) != source
            raise Hive::ConfigError, "workflow instruction paths collide in the package"
          end
          instructions[packaged] = source
          packaged
        end
        [ rewritten, instructions.sort.to_h ]
      end

      def deep_transform(value, &block)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), out|
            string_key = key.to_s
            out[string_key] = if child.is_a?(Hash) || child.is_a?(Array)
              deep_transform(child, &block)
            else
              block.call(string_key, child)
            end
          end
        when Array
          value.map { |child| deep_transform(child, &block) }
        else
          value
        end
      end

      def resolve_instruction(value)
        unless value.is_a?(String) && !value.strip.empty?
          raise Hive::ConfigError, "workflow instruction references must be non-empty paths"
        end
        lexical = File.expand_path(value, workflows_dir)
        prefix = File.expand_path(authored_dir) + File::SEPARATOR
        unless lexical.start_with?(prefix)
          raise Hive::ConfigError, "published instructions must live under #{authored_dir}"
        end
        stat = File.lstat(lexical)
        unless stat.file? && !stat.symlink? && stat.nlink == 1
          raise Hive::ConfigError, "published instructions must be independent regular files"
        end
        relative = Pathname.new(lexical).relative_path_from(Pathname.new(authored_dir)).to_s
        Manifest.validate_relative_path!(relative)
        [ lexical, relative ]
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "published workflow references a missing or unreadable instruction"
      end

      def copy_authored_file(source, target, label:)
        stat = File.lstat(source)
        unless stat.file? && !stat.symlink? && stat.nlink == 1
          raise Hive::ConfigError, "#{label} must be an independent regular file"
        end
        FileUtils.copy_file(source, target)
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow publish requires a readable #{label}"
      end

      def copy_instructions(instructions, destination)
        instructions.each do |relative, source|
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.copy_file(source, target)
        end
      end

      def admit_runtime!(workflow, permissions)
        Dir.mktmpdir("hive-workflow-publish-admission-") do |root|
          task_folder = File.join(root, "task")
          FileUtils.mkdir_p(task_folder)
          RuntimePolicy.admit_workflow!(
            workflow, permissions, task_folder: task_folder,
            policy_dir: File.join(root, "policy")
          )
        end
      end

      class RegistryPullRequest
        def initialize(repository: OFFICIAL_REPOSITORY, runner: nil)
          @repository = repository
          @runner = runner || ->(args, chdir: nil) { Hive::Gh.capture3(*args, chdir: chdir) }
        end

        def open(package)
          run!([ "gh", "auth", "status" ], label: "GitHub authentication")
          login = viewer_login
          branch = "honeycomb-#{package.name}-#{package.version}-#{package.manifest_digest[0, 12]}"
          existing = existing_pr(login, branch)
          return existing if existing

          fork = ensure_fork(login)
          Dir.mktmpdir("hive-honeycomb-publish-") do |checkout|
            run!([ "gh", "repo", "clone", fork, checkout, "--", "--quiet" ], label: "registry clone")
            reject_version_collision!(checkout, package)
            run!([ "git", "checkout", "-b", branch ], chdir: checkout, label: "branch creation")
            target = File.join(checkout, "workflows", package.name)
            FileUtils.rm_rf(target)
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp_r(package.root, target)
            run!([ "git", "add", "--", File.join("workflows", package.name) ], chdir: checkout, label: "package staging")
            run!([ "git", "commit", "-m", "workflow: publish #{package.name} #{package.version}" ],
                 chdir: checkout, label: "package commit")
            run!([ "git", "push", "-u", "origin", branch ], chdir: checkout, label: "fork push")
            create_pr(checkout, package, login, branch)
          end
        end

        private

        def viewer_login
          out = run!([ "gh", "api", "user" ], label: "GitHub user lookup")
          login = JSON.parse(out).fetch("login").to_s
          raise PublishError, "GitHub user lookup returned no login" if login.empty?

          login
        rescue JSON::ParserError, KeyError
          raise PublishError, "GitHub user lookup returned invalid data"
        end

        def ensure_fork(login)
          fork = "#{login}/honeycomb"
          _out, _err, status = run([ "gh", "repo", "view", fork, "--json", "nameWithOwner" ])
          return fork if status.success?

          run!([ "gh", "repo", "fork", @repository, "--clone=false", "--remote=false" ], label: "registry fork creation")
          fork
        end

        def existing_pr(login, branch)
          out = run!([ "gh", "pr", "list", "--repo", @repository, "--state", "open",
                       "--head", "#{login}:#{branch}", "--json", "url" ], label: "duplicate PR lookup")
          entries = JSON.parse(out)
          entries.first&.fetch("url", nil) if entries.is_a?(Array)
        rescue JSON::ParserError
          raise PublishError, "duplicate PR lookup returned invalid data"
        end

        def reject_version_collision!(checkout, package)
          manifest_path = File.join(checkout, "workflows", package.name, Manifest::FILE_NAME)
          if File.file?(manifest_path)
            existing = JSON.parse(File.read(manifest_path))
            if existing["name"] != package.name
              raise PublishError, "registry package path is owned by another workflow"
            end
            if existing["version"] == package.version
              raise PublishError, "workflow version #{package.version} already exists in the registry"
            end
          end
          catalog_path = File.join(checkout, "catalog.json")
          return unless File.file?(catalog_path)

          catalog = JSON.parse(File.read(catalog_path))
          versions = catalog.dig("workflows", package.name, "versions") || {}
          if versions.key?(package.version)
            raise PublishError, "workflow version #{package.version} is already immutable in the catalog"
          end
        rescue JSON::ParserError
          raise PublishError, "registry checkout contains invalid package or catalog metadata"
        end

        def create_pr(checkout, package, login, branch)
          Tempfile.create([ "hive-honeycomb-pr-", ".md" ]) do |body|
            body.write(pr_body(package))
            body.flush
            out = run!([ "gh", "pr", "create", "--repo", @repository,
                         "--head", "#{login}:#{branch}",
                         "--title", "workflow: publish #{package.name} #{package.version}",
                         "--body-file", body.path ], chdir: checkout, label: "pull request creation")
            url = out.lines.last.to_s.strip
            raise PublishError, "pull request creation returned no URL" if url.empty?

            url
          end
        end

        def pr_body(package)
          warning_lines = package.warnings.map do |warning|
            "- `#{warning.fetch('rule_id')}` at `#{warning.fetch('path')}`"
          end
          warning_lines = [ "- None" ] if warning_lines.empty?
          <<~MARKDOWN
            ## Honeycomb submission

            Workflow: `#{package.name}`
            Version: `#{package.version}`
            Manifest SHA-256: `#{package.manifest_digest}`

            Local preflight passed. This submission is pending registry checks and trusted non-author review.

            ### Warnings

            #{warning_lines.join("\n")}
          MARKDOWN
        end

        def run!(args, chdir: nil, label:)
          out, _err, status = run(args, chdir: chdir)
          raise PublishError, "#{label} failed" unless status.success?

          out
        end

        def run(args, chdir: nil)
          @runner.call(args, chdir: chdir)
        rescue Hive::GhError, SystemCallError, IOError
          raise PublishError, "registry publishing command failed"
        end
      end
    end
  end
end
