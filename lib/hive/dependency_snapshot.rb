require "hive/stages"
require "hive/archive_filter"
require "hive/task_meta"
require "hive/dependencies"
require "hive/config"
require "hive/dependency_admission"
require "hive/plan_frontmatter"
require "hive/repository_identity"
require "hive/workflows/project"
require "hive/workflows/registry"

module Hive
  # Disk→resolver glue for task dependencies. `tasks` reads every stage
  # folder's meta.yml into the shape `Hive::Dependencies` consumes;
  # `current_task`/`depends_on` project the task-under-evaluation into the
  # same shape. Every production caller passes a `Hive::Task`, which exposes
  # #slug, #id, #depends_on, #folder, and #project_root directly — the
  # snapshot does not duck-type other inputs.
  module DependencySnapshot
    module_function

    def tasks(project_root)
      Hive::Stages::DIRS.each_with_index.flat_map do |stage, index|
        stage_dir = File.join(project_root, ".hive-state", "stages", stage)
        next [] unless File.directory?(stage_dir)

        Dir.children(stage_dir).sort.filter_map do |entry|
          folder = File.join(stage_dir, entry)
          next unless File.directory?(folder)

          meta = Hive::TaskMeta.read(folder)
          {
            slug: meta[:slug] || entry,
            id: meta[:id],
            stage: stage,
            stage_index: index + 1
          }
        end
      end
    end

    def current_task(task)
      { slug: task.slug, id: task.id }
    end

    def depends_on(task)
      task.depends_on
    end

    # Resolve the branch a dependent task's worktree / PR should stack
    # onto. Shared by 4-execute (worktree base) and 5-open-pr (PR base) so
    # the read-depends_on → load-snapshot → resolve → null-out-when-default
    # scaffolding lives in one place. Returns nil when the task has no
    # dependency, or when a set dependency does not resolve to a stacked
    # base (typo / prereq transiently absent from the snapshot /
    # self-reference) — and warns in that latter case so a silently
    # collapsed stack is observable at execute/open-pr time rather than
    # only via the fail-closed daemon gate. Lives here (the disk-reading
    # layer) rather than in the pure `Hive::Dependencies` resolver so the
    # resolver stays free of disk I/O.
    def stacked_base(task, default_branch)
      dependency = depends_on(task)
      return nil if dependency.to_s.strip.empty?

      reference = Hive::Dependencies.parse_reference(dependency)
      if reference.explicit_project
        warn "[hive] dependency: #{task.slug} depends_on #{dependency.inspect} is " \
             "cross-project and scheduling-only; branching from #{default_branch}"
        return nil
      end

      base = Hive::Dependencies.base_branch_for(
        depends_on: dependency,
        tasks: tasks(task.project_root),
        default_branch: default_branch,
        task: current_task(task)
      )
      if base == default_branch
        warn "[hive] dependency: #{task.slug} depends_on #{dependency.inspect} " \
             "but it did not resolve to a stacked base (prerequisite missing " \
             "from the snapshot or self-reference); branching from #{default_branch}"
        return nil
      end

      base
    rescue Hive::Dependencies::InvalidReference => e
      warn "[hive] dependency: #{task.slug} has invalid depends_on #{dependency.inspect} " \
           "(#{e.message}); branching from #{default_branch}"
      nil
    end

    def admission_context(registry_entries = Hive::Config.registered_projects,
                          exclude_archived: false, extra_dependency_tasks: nil)
      projects = registry_entries.map do |entry|
        extras = extra_dependency_tasks && extra_dependency_tasks[entry["path"]] if exclude_archived
        admission_project(entry, exclude_archived: exclude_archived, extra_tasks: extras)
      end
      Hive::DependencyAdmission::Context.new(projects: projects)
    end

    # Recompute dependency admission from disk and raise the typed manual
    # boundary error. Callers invoke this while holding the depending task's
    # lock immediately before forward side effects.
    def enforce_admission!(task, registry_entries: Hive::Config.registered_projects)
      project = registry_entries.select do |entry|
        File.expand_path(entry.fetch("path")) == File.expand_path(task.project_root)
      end
      unless project.one?
        raise Hive::DependencyAdmissionError.new(
          "dependency admission failed: task project enrollment is missing or ambiguous",
          reason_code: "dependency_validation_failed",
          offending_ref: "#{task.project_name}:#{task.slug}",
          safe_correction: "Inspect project enrollment and re-enroll the intended project before dispatching."
        )
      end

      verdict = admission_context(registry_entries).verdict(
        project: project.first.fetch("name"),
        slug: task.slug
      )
      return verdict if verdict.clear?

      if verdict.wait?
        ref = verdict.blocked_by.to_s
        correction = "Wait for #{ref} to reach the configured dependency gate; it is currently at #{verdict.dependency_stage}."
        raise Hive::DependencyWaitError.new(
          "dependency wait: #{task.slug} is blocked by #{ref} at #{verdict.dependency_stage}",
          offending_ref: ref,
          safe_correction: correction
        )
      end

      error = verdict.admission_error
      raise Hive::DependencyAdmissionError.new(
        "dependency admission error (#{error.reason_code}): #{error.offending_ref}; #{error.safe_correction}",
        reason_code: error.reason_code,
        offending_ref: error.offending_ref,
        safe_correction: error.safe_correction
      )
    rescue Hive::DependencyWaitError, Hive::DependencyAdmissionError
      raise
    rescue StandardError => e
      raise Hive::DependencyAdmissionError.new(
        "dependency admission failed: #{e.class}: #{e.message}",
        reason_code: "dependency_validation_failed",
        offending_ref: "#{task.project_name}:#{task.slug}",
        safe_correction: "Inspect dependency metadata and project enrollment before dispatching."
      )
    end

    def admission_project(entry, exclude_archived: false, extra_tasks: nil)
      root = File.expand_path(entry.fetch("path"))
      config, config_error = admission_project_config(root)
      tasks = if config_error
        []
      else
        admission_tasks(
          root,
          config,
          project_name: entry.fetch("name"),
          exclude_archived: exclude_archived,
          extra_tasks: extra_tasks
        )
      end
      Hive::DependencyAdmission::ProjectSnapshot.new(
        name: entry.fetch("name"),
        path: root,
        repository_identity: entry["repository_identity"],
        live_repository_identity: Hive::RepositoryIdentity.current(root),
        dependency_gate_stage: config.fetch("dependency_gate_stage", Hive::Config::DEFAULTS.fetch("dependency_gate_stage")),
        tasks: tasks,
        validation_error: config_error
      )
    rescue StandardError => e
      Hive::DependencyAdmission::ProjectSnapshot.new(
        name: entry["name"].to_s,
        path: root || entry["path"].to_s,
        repository_identity: entry["repository_identity"],
        live_repository_identity: nil,
        dependency_gate_stage: Hive::Config::DEFAULTS.fetch("dependency_gate_stage"),
        tasks: [],
        validation_error: "#{e.class}: #{e.message}"
      )
    end

    def admission_project_config(root)
      path = File.join(root, ".hive-state", "config.yml")
      return [ {}, nil ] unless File.exist?(path)

      data = YAML.safe_load(File.read(path)) || {}
      return [ {}, "#{path} must contain a mapping" ] unless data.is_a?(Hash)

      [ data, nil ]
    rescue Psych::Exception, SystemCallError, IOError => e
      [ {}, "could not read #{path}: #{e.class}: #{e.message}" ]
    end

    def admission_tasks(root, config, project_name: File.basename(root), exclude_archived: false, extra_tasks: nil)
      folders = Dir.glob(File.join(root, ".hive-state", "stages", "*-*", "*"))
        .select { |folder| File.directory?(folder) }
        .sort
      if exclude_archived
        folders.reject! { |folder| File.basename(File.dirname(folder)) == Hive::ArchiveFilter::ARCHIVE_STAGE_DIR }
      end

      Hive::Workflows::Project.synchronize do
        Hive::Workflows::Project.load!(root)
        live_tasks = folders.map do |folder|
          admission_task(root, folder, config, project_name: project_name)
        end
        live_slugs = live_tasks.to_h { |task| [ task.slug, true ] }
        cached_tasks = Array(extra_tasks).filter_map do |task|
          cached_admission_task(task, project_name: project_name) unless live_slugs[field(task, :slug).to_s]
        end
        live_tasks + cached_tasks
      end
    end

    # TUI active-only emissions reuse immutable archived rows produced by the
    # last full/archive status pass. Those rows have already crossed strict
    # metadata, plan, workflow, and graph admission; carrying their terminal
    # identity (or exact admission error) avoids rescanning an unbounded
    # archive on every one-second refresh.
    def cached_admission_task(task, project_name:)
      slug = field(task, :slug).to_s
      return nil if slug.empty?

      stage = field(task, :stage).to_s
      cached_error = cached_admission_error(field(task, :admission_error))
      Hive::DependencyAdmission::TaskSnapshot.new(
        project: project_name,
        slug: slug,
        id: field(task, :id),
        stage: stage,
        workflow_stages: (Hive::Stages::DIRS + [ stage ]).uniq,
        depends_on: nil,
        metadata_status: :ok,
        metadata_error: nil,
        plan_status: :absent,
        plan_dependency: nil,
        plan_error: nil,
        folder: nil,
        validation_error: cached_error
      )
    end

    def cached_admission_error(value)
      return nil if value.nil?
      return "cached dependency admission error is malformed" unless value.respond_to?(:key?)

      reason_code = field(value, :reason_code).to_s
      offending_ref = field(value, :offending_ref).to_s
      safe_correction = field(value, :safe_correction).to_s
      unless Hive::DependencyAdmission::REASON_CODES.include?(reason_code) &&
             !offending_ref.empty? && !safe_correction.empty?
        return "cached dependency admission error is malformed"
      end

      Hive::DependencyAdmission::AdmissionError.new(
        reason_code: reason_code,
        offending_ref: offending_ref,
        safe_correction: safe_correction
      )
    end

    def field(value, key)
      return value[key] if value.respond_to?(:key?) && value.key?(key)
      return value[key.to_s] if value.respond_to?(:key?) && value.key?(key.to_s)

      nil
    end

    def admission_task(root, folder, config, project_name: File.basename(root))
      metadata = Hive::TaskMeta.read_for_admission(folder)
      plan = Hive::PlanFrontmatter.read(File.join(folder, "plan.md"))
      selector = metadata.data[:workflow] || config["default_workflow"] || Hive::Config::DEFAULTS.fetch("default_workflow")
      workflow_stages = []
      validation_error = nil
      begin
        Hive::Workflows::Project.assert_descriptor_loadable!(selector.to_sym, project_root: root)
        workflow_stages = Hive::Workflows::Registry.fetch(selector.to_sym).stage_dirs
      rescue StandardError => e
        validation_error = "workflow #{selector.inspect} could not be resolved: #{e.class}: #{e.message}"
      end

      stage = File.basename(File.dirname(folder))
      slug = metadata.data[:slug] || File.basename(folder)
      metadata_status = if metadata.status == :invalid && metadata.reason == :reference_invalid
        :invalid_reference
      else
        metadata.status
      end

      Hive::DependencyAdmission::TaskSnapshot.new(
        project: project_name,
        slug: slug,
        id: metadata.data[:id],
        stage: stage,
        workflow_stages: workflow_stages,
        depends_on: metadata.data[:depends_on],
        metadata_status: metadata_status,
        metadata_error: metadata.error,
        plan_status: plan.status,
        plan_dependency: plan.depends_on&.to_s,
        plan_error: plan.error,
        folder: folder,
        validation_error: validation_error
      )
    end
  end
end
