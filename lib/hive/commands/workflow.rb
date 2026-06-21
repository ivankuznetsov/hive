require "erb"
require "fileutils"
require "json"
require "pathname"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/workflows/descriptor_parser"
require "hive/workflows/project"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      TEMPLATE_ROOT = File.expand_path("../../../templates/workflows/blank", __dir__)
      WORKFLOW_ID_RE = Hive::Workflows::DescriptorParser::SAFE_SLUG

      class UsageError < Hive::Error
        attr_reader :value

        def initialize(message, value: nil)
          super(message)
          @value = value
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.new!(id, project_root: Dir.pwd, json: false, stdout: $stdout)
        new("new", id, project_root: project_root, json: json, stdout: stdout).call!
      end

      def initialize(subcommand, id = nil, project_root: Dir.pwd, json: false, stdout: $stdout)
        @subcommand = subcommand
        @id = id
        @project_root = File.expand_path(project_root)
        @json = json
        @stdout = stdout
      end

      def call
        call!
      rescue UsageError, Hive::ConfigError, Hive::GitError => e
        if @json
          @stdout.puts JSON.generate(error_payload(e))
        else
          warn "hive workflow: #{e.message}"
        end
        exit(e.exit_code)
      end

      def call!
        unless @subcommand == "new"
          raise UsageError.new("unknown workflow subcommand #{@subcommand.inspect} (expected: new)", value: @subcommand)
        end

        id = normalize_id(@id)
        validate_id!(id)
        paths = scaffold_paths(id)
        refuse_overwrite!(paths)
        begin
          write_scaffold!(id, paths)
          validate_descriptor!(paths.fetch(:descriptor))
        rescue StandardError
          rollback_scaffold(paths)
          raise
        end
        Hive::Workflows::Project.reset!
        commit_scaffold!(id, paths)

        payload = success_payload(id, paths)
        if @json
          @stdout.puts JSON.generate(payload)
        else
          @stdout.puts "hive: created workflow #{id} at #{paths.fetch(:descriptor)}"
          @stdout.puts "next: #{payload.fetch("next")}"
        end
        payload
      end

      private

      def normalize_id(value)
        id = value.to_s.strip
        return id unless id.empty?

        raise UsageError.new("missing workflow id", value: value)
      end

      def validate_id!(id)
        unless WORKFLOW_ID_RE.match?(id)
          raise UsageError.new("invalid workflow id #{id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: id)
        end
        return unless Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        raise UsageError.new("workflow id #{id.inspect} is reserved by a built-in workflow", value: id)
      end

      def scaffold_paths(id)
        workflows_dir = workflow_dir
        {
          workflows_dir: workflows_dir,
          descriptor: File.join(workflows_dir, "#{id}.yml"),
          instruction_dir: File.join(workflows_dir, id),
          instruction: File.join(workflows_dir, id, "work.md")
        }
      end

      def workflow_dir
        cfg = Hive::Config.load(@project_root)
        File.join(File.expand_path(cfg.fetch("hive_state_path"), @project_root), "workflows")
      end

      def refuse_overwrite!(paths)
        collisions = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir), paths.fetch(:instruction) ].select do |path|
          File.exist?(path)
        end
        return if collisions.empty?

        raise UsageError.new("workflow scaffold already exists at #{collisions.join(', ')}", value: collisions.first)
      end

      def write_scaffold!(id, paths)
        FileUtils.mkdir_p(paths.fetch(:instruction_dir))
        File.write(paths.fetch(:descriptor), render_descriptor(id))
        File.write(paths.fetch(:instruction), File.read(File.join(TEMPLATE_ROOT, "work.md")))
      end

      def render_descriptor(id)
        template = File.read(File.join(TEMPLATE_ROOT, "descriptor.yml.erb"))
        ERB.new(template, trim_mode: "-").result_with_hash(id: id)
      end

      def validate_descriptor!(path)
        Hive::Workflows::DescriptorParser.parse_file(path)
      end

      def commit_scaffold!(id, paths)
        ops = Hive::GitOps.new(@project_root)
        Hive::Lock.with_commit_lock(hive_state_path) do
          ops.hive_commit(
            stage_name: "workflows",
            slug: id,
            action: "created",
            pathspecs: [
              relative_to_workflows_root(paths.fetch(:descriptor)),
              relative_to_workflows_root(paths.fetch(:instruction_dir))
            ]
          )
        end
      end

      def relative_to_workflows_root(path)
        Pathname.new(path).relative_path_from(Pathname.new(hive_state_path)).to_s
      end

      def hive_state_path
        @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
      end

      def rollback_scaffold(paths)
        FileUtils.rm_f(paths.fetch(:descriptor))
        FileUtils.rm_rf(paths.fetch(:instruction_dir))
      end

      def success_payload(id, paths)
        {
          "ok" => true,
          "id" => id,
          "descriptor_path" => paths.fetch(:descriptor),
          "instruction_path" => paths.fetch(:instruction),
          "next" => "hive new --workflow #{id} \"<your idea>\""
        }
      end

      def error_payload(error)
        {
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "exit_code" => error.exit_code,
          "message" => error.message
        }
      end
    end
  end
end
