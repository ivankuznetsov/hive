require "hive/commands/workflow/base"
require "hive/workflow_package/git_source"

module Hive
  module Commands
    class Workflow
      class GitInstall < Base
        def initialize(id, repository:, ref: "HEAD", project_root:, json: false, dry_run: false, stdout: $stdout)
          super(project_root: project_root, json: json, stdout: stdout)
          @id = id
          @repository = repository
          @ref = ref
          @dry_run = dry_run
        end

        def call!
          id = Workflow.normalize_and_validate_id!(@id, project_root: @project_root)
          workflows = File.join(hive_state_path, "workflows")
          check_destination!(id, workflows)
          Dir.mktmpdir("hive-workflow-source-") do |root|
            snapshot = Hive::WorkflowPackage::GitSource.new(repository: @repository, ref: @ref).fetch(id, destination: root)
            report = {
              "schema" => envelope_schema, "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
              "ok" => true, "status" => @dry_run ? "dry_run" : "installed", "origin" => "authored",
              "name" => id, "repository" => snapshot.repository, "ref" => snapshot.ref,
              "source_commit" => snapshot.commit, "files" => snapshot.files,
              "descriptor_path" => File.join(workflows, "#{id}.yml")
            }
            install!(id, workflows, snapshot) unless @dry_run
            emit(report, human_lines: [
              "hive: #{@dry_run ? 'would install' : 'installed'} authored workflow #{id} from #{snapshot.repository}",
              "source commit: #{snapshot.commit}",
              "Workflow instructions run with authored-project permissions. Review them before starting a task.",
              "Companion services, dependencies, credentials, and schedules are configured separately."
            ])
          end
        end

        private

        def check_destination!(id, workflows)
          if File.symlink?(workflows) || (File.exist?(workflows) && !File.directory?(workflows))
            raise Hive::ConfigError, "workflow root must be a real directory"
          end
          targets = [ File.join(workflows, "#{id}.yml"), File.join(workflows, "#{id}.yaml"), File.join(workflows, id) ]
          if targets.any? { |path| File.exist?(path) || File.symlink?(path) } || store.selected_read_only(id, cfg: project_config)
            raise OwnershipError, "workflow #{id} already exists; Git source installation never overwrites local or managed workflows"
          end
        end

        def install!(id, workflows, snapshot)
          paths = { descriptor: File.join(workflows, "#{id}.yml"), instruction_dir: File.join(workflows, id), owned_paths: [] }
          pathspecs = [ "workflows/#{id}.yml", "workflows/#{id}" ]
          Hive::WorkflowPackage::MutationLock.with_lock(workflows) do
            Hive::Lock.with_commit_lock(hive_state_path) do
              check_destination!(id, workflows)
              ops = Hive::GitOps.new(@project_root)
              begin
                Dir.mkdir(paths.fetch(:instruction_dir))
                paths[:owned_paths] << paths.fetch(:instruction_dir)
                source_dir = File.join(snapshot.root, id)
                FileUtils.cp_r(Dir.glob(File.join(source_dir, "*"), File::FNM_DOTMATCH).reject { |p| %w[. ..].include?(File.basename(p)) },
                               paths.fetch(:instruction_dir)) if File.directory?(source_dir)
                receipt = { "repository" => snapshot.repository, "ref" => snapshot.ref,
                            "commit" => snapshot.commit, "files" => snapshot.files }
                File.write(File.join(paths.fetch(:instruction_dir), Hive::WorkflowPackage::GitSource::RECEIPT), JSON.pretty_generate(receipt) + "\n")
                # Descriptor is written last, after all referenced assets exist.
                File.open(paths.fetch(:descriptor), File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
                  paths[:owned_paths] << paths.fetch(:descriptor)
                  file.write(File.binread(File.join(snapshot.root, "#{id}.yml")))
                end
                Workflow.commit_workflow_scaffold(ops, slug: id, pathspecs: pathspecs)
              rescue StandardError, Interrupt
                ops.run_git!("-C", hive_state_path, "reset", "-q", "HEAD", "--", *pathspecs)
                Workflow.rollback_scaffold(paths)
                raise
              end
            end
          end
          Hive::Workflows::Project.reset!
        end

        def error_kind(error)
          error.is_a?(UsageError) ? "usage" : super
        end

        def envelope_schema = "hive-workflow-install"
      end
    end
  end
end
