require "hive/config"
require "hive/dependencies"

module Hive
  module DependencyAdmission
    REASON_CODES = %w[
      dependency_metadata_unreadable
      dependency_metadata_invalid
      dependency_reference_invalid
      dependency_task_missing
      dependency_self_reference
      dependency_cycle
      dependency_gate_unknown
      dependency_gate_unreachable
      dependency_project_unknown
      dependency_repository_identity_missing
      dependency_repository_mismatch
      plan_dependency_invalid
      plan_dependency_missing
      plan_dependency_mismatch
      dependency_validation_failed
    ].freeze

    AdmissionError = Data.define(:reason_code, :offending_ref, :safe_correction) do
      def to_h
        {
          "reason_code" => reason_code,
          "offending_ref" => offending_ref,
          "safe_correction" => safe_correction
        }
      end
    end

    UnmetDependency = Data.define(:reference, :blocked_by, :dependency_stage, :required_gate) do
      def to_h
        {
          "reference" => reference,
          "blocked_by" => blocked_by,
          "dependency_stage" => dependency_stage,
          "required_gate" => required_gate
        }
      end
    end

    Verdict = Data.define(
      :state, :blocked_by, :dependency_stage, :unmet_dependencies, :admission_error
    ) do
      def initialize(state:, blocked_by: nil, dependency_stage: nil,
                     unmet_dependencies: EMPTY_UNMET_DEPENDENCIES, admission_error: nil)
        super(
          state: state,
          blocked_by: blocked_by,
          dependency_stage: dependency_stage,
          unmet_dependencies: unmet_dependencies,
          admission_error: admission_error
        )
      end

      def clear? = state == :clear
      def wait? = state == :wait
      def error? = state == :error
      def blocked? = !clear?
    end

    EMPTY_UNMET_DEPENDENCIES = [].freeze
    private_constant :EMPTY_UNMET_DEPENDENCIES

    Blocker = Data.define(:identity, :unmet)
    Evaluation = Data.define(:verdict, :blockers, :cycle_derived)
    private_constant :Blocker, :Evaluation

    TaskSnapshot = Data.define(
      :project, :slug, :id, :stage, :workflow_stages, :depends_on,
      :metadata_status, :metadata_error, :plan_status, :plan_dependency,
      :plan_error, :folder, :validation_error, :cancelled
    )

    ProjectSnapshot = Data.define(
      :name, :path, :repository_identity, :live_repository_identity,
      :dependency_gate_stage, :tasks, :validation_error
    )

    class Context
      attr_reader :projects

      def initialize(projects:, fallback: nil)
        @projects = projects.map do |project|
          tasks = project.tasks.map do |task|
            task.with(
              workflow_stages: Array(task.workflow_stages).dup.freeze,
              depends_on: immutable_declaration(task.depends_on),
              plan_dependency: immutable_declaration(task.plan_dependency)
            ).freeze
          end.freeze
          project.with(tasks: tasks).freeze
        end.freeze
        @fallback = fallback
        @projects_by_name = @projects.group_by(&:name).transform_values(&:freeze).freeze
        @projects_by_path = @projects.group_by { |project| File.expand_path(project.path) }
          .transform_values(&:freeze).freeze
        @tasks_by_project_slug = {}
        @tasks_by_project_id = {}
        @projects.each do |project|
          @tasks_by_project_slug[project.name] = frozen_group_by(project.tasks, &:slug)
          @tasks_by_project_id[project.name] = frozen_group_by(project.tasks, &:id)
        end
        @tasks_by_project_slug.freeze
        @tasks_by_project_id.freeze
        @verdict_cache = {}
        @verdict_cache_mutex = Mutex.new
      end

      def project_for_path(path)
        matches = @projects_by_path[File.expand_path(path)] || []
        matches.one? ? matches.first : nil
      end

      def project_path_match_count(path)
        (@projects_by_path[File.expand_path(path)] || []).length
      end

      # Resolve one task through the same active-before-fallback indexes used
      # by admission. Presentation consumers use this to derive related policy
      # without re-reading task metadata from disk.
      def task_snapshot(project:, slug: nil, id: nil)
        source_project = unique_project(project)
        return unless source_project

        matches = task_matches(source_project, slug: slug, id: id)
        matches.first if matches.one?
      end

      # Read-only presentation inventory. Active snapshots precede fallback
      # snapshots so consumers can preserve the same active-shadows-archive
      # semantics without reaching into Context's private indexes or
      # re-reading the filesystem.
      def project_snapshots
        project_snapshot_layers.flatten.freeze
      end

      def project_snapshot_layers
        ([ projects ] + Array(@fallback&.project_snapshot_layers)).freeze
      end

      def with_task(project:, task:)
        matches = @projects_by_name[project] || []
        return self unless matches.one?

        overlaid = @projects.map do |snapshot|
          next snapshot unless snapshot.equal?(matches.first)

          snapshot.with(tasks: (snapshot.tasks + [ task ]).freeze)
        end
        self.class.new(projects: overlaid, fallback: @fallback)
      end

      def verdict(project:, slug:)
        source_project = unique_project(project)
        return admission_error("dependency_project_unknown", project, project_correction(project)) unless source_project
        return validation_failure(source_project.validation_error, project) if source_project.validation_error

        source_matches = task_matches(source_project, slug: slug)
        if source_matches.length > 1
          return validation_failure("duplicate task slug #{slug.inspect}", "#{project}:#{slug}")
        end
        source = source_matches.first
        return admission_error("dependency_task_missing", "#{project}:#{slug}", task_correction(project)) unless source
        return clear if source.cancelled

        @verdict_cache_mutex.synchronize do
          cached = @verdict_cache[qualify(source)]
          cached ? cached.verdict : walk(source)
        end
      rescue StandardError => e
        admission_error(
          "dependency_validation_failed",
          "#{project}:#{slug}",
          "Inspect dependency metadata and project enrollment; validation failed with #{e.class}."
        )
      end

      private

      def walk(source)
        frames = []
        active_path = []
        active_index = {}
        push_frame(frames, active_path, active_index, source, incoming: nil)

        until frames.empty?
          frame = frames.last
          enter_frame(frame) unless frame[:entered]

          if frame[:admission_error] || frame[:cursor] >= frame[:references].length
            evaluation = complete_frame(frame)
            frames.pop
            active_index.delete(frame[:identity])
            active_path.pop
            @verdict_cache[frame[:identity]] = evaluation unless evaluation.cycle_derived
            return evaluation.verdict if frames.empty?

            absorb_child(frames.last, frame[:incoming], evaluation)
            next
          end

          reference = frame[:references][frame[:cursor]]
          frame[:cursor] += 1
          edge = resolve_edge(frame[:task], reference)
          if edge.is_a?(Verdict)
            frame[:admission_error] = edge.admission_error
            next
          end

          target, target_project = edge
          target_identity = qualify(target)
          if target_identity == frame[:identity]
            frame[:admission_error] = admission_error(
              "dependency_self_reference",
              reference.to_s,
              "Remove or correct depends_on in #{frame[:task].folder}/meta.yml."
            ).admission_error
            next
          end
          if (cycle_start = active_index[target_identity])
            cycle = (active_path[cycle_start..] + [ target_identity ]).join(" -> ")
            frame[:admission_error] = admission_error(
              "dependency_cycle",
              cycle,
              "Break the cycle by correcting one depends_on declaration in the reported path."
            ).admission_error
            frame[:cycle_derived] = true
            next
          end

          gate_result = validate_gate(
            frame[:task], target, target_project, reference,
            list_declaration: frame[:list_declaration]
          )
          if gate_result.is_a?(Verdict)
            frame[:admission_error] = gate_result.admission_error
            next
          end

          incoming = { blocker: gate_result }.freeze
          if (cached = @verdict_cache[target_identity])
            absorb_child(frame, incoming, cached)
          else
            push_frame(frames, active_path, active_index, target, incoming: incoming)
          end
        end
      end

      def push_frame(frames, active_path, active_index, task, incoming:)
        identity = qualify(task)
        active_index[identity] = active_path.length
        active_path << identity
        frames << {
          task: task, identity: identity, incoming: incoming, entered: false,
          references: EMPTY_UNMET_DEPENDENCIES, cursor: 0, list_declaration: false,
          direct_blockers: [], transitive_blockers: [], admission_error: nil,
          cycle_derived: false
        }
      end

      def enter_frame(frame)
        frame[:entered] = true
        if (node_error = validate_node(frame[:task]))
          frame[:admission_error] = node_error.admission_error
          return
        end
        return unless frame[:task].depends_on

        declaration = parse_declaration(frame[:task].depends_on)
        if declaration.is_a?(Verdict)
          frame[:admission_error] = declaration.admission_error
          return
        end

        references, list_declaration = declaration
        frame[:references] = references
        frame[:list_declaration] = list_declaration
      end

      def resolve_edge(task, reference)
        target_project = resolve_project(task.project, reference)
        return target_project if target_project.is_a?(Verdict)

        if reference.explicit_project
          identity_error = validate_repository_identity(target_project, reference.to_s)
          return identity_error if identity_error
        end

        target = resolve_task(target_project, reference)
        return target if target.is_a?(Verdict)

        [ target, target_project ]
      end

      def absorb_child(frame, incoming, evaluation)
        if incoming[:blocker]
          frame[:direct_blockers] << incoming[:blocker]
        else
          frame[:transitive_blockers].concat(evaluation.blockers)
        end
        return unless evaluation.verdict.error?

        frame[:admission_error] ||= evaluation.verdict.admission_error
        frame[:cycle_derived] ||= evaluation.cycle_derived
      end

      def complete_frame(frame)
        blockers = deduplicate_blockers(frame[:direct_blockers] + frame[:transitive_blockers])
        unmet = blockers.map(&:unmet).freeze
        singular = frame[:list_declaration] ? nil : frame[:direct_blockers].first&.unmet
        verdict = if frame[:admission_error]
          error_verdict(frame[:admission_error], unmet)
        elsif blockers.empty?
          clear
        else
          wait(
            blocked_by: singular&.blocked_by,
            dependency_stage: singular&.dependency_stage,
            unmet_dependencies: unmet
          )
        end
        Evaluation.new(
          verdict: verdict.freeze,
          blockers: blockers.freeze,
          cycle_derived: frame[:cycle_derived]
        ).freeze
      end

      def deduplicate_blockers(blockers)
        positions = {}
        blockers.each_with_object([]) do |blocker, result|
          if (position = positions[blocker.identity])
            existing = result[position]
            next unless stronger_gate?(blocker.unmet.required_gate, existing.unmet.required_gate)

            result[position] = Blocker.new(
              identity: existing.identity,
              unmet: existing.unmet.with(required_gate: blocker.unmet.required_gate).freeze
            ).freeze
          else
            positions[blocker.identity] = result.length
            result << blocker
          end
        end
      end

      def stronger_gate?(candidate, existing)
        gate_strength(candidate) > gate_strength(existing)
      end

      def gate_strength(gate)
        Hive::Config::DEPENDENCY_GATE_STAGES.index(gate) || -1
      end

      def validate_node(task)
        if task.validation_error
          return cached_admission_error(task.validation_error) if task.validation_error.is_a?(AdmissionError)

          return validation_failure(task.validation_error, qualify(task))
        end

        case task.metadata_status
        when :unreadable
          return admission_error(
            "dependency_metadata_unreadable",
            qualify(task),
            "Repair #{task.folder}/meta.yml without removing dependency evidence."
          )
        when :invalid_reference
          correction = invalid_reference_correction(task)
          return admission_error(
            "dependency_reference_invalid",
            task.depends_on || qualify(task),
            correction
          )
        when :invalid
          return admission_error(
            "dependency_metadata_invalid",
            qualify(task),
            "Repair #{task.folder}/meta.yml as a YAML mapping and preserve the intended depends_on value."
          )
        end

        if task.plan_status == :invalid
          return admission_error(
            "plan_dependency_invalid",
            File.join(task.folder, "plan.md"),
            "Repair plan.md YAML frontmatter; do not infer dependencies from prose."
          )
        end

        if task.plan_dependency && task.depends_on.nil?
          return admission_error(
            "plan_dependency_missing",
            task.plan_dependency.to_s,
            "Add the same depends_on value to #{task.folder}/meta.yml or remove the stale plan assertion."
          )
        end

        if task.plan_dependency && normalized_declaration(task.plan_dependency) != normalized_declaration(task.depends_on)
          return admission_error(
            "plan_dependency_mismatch",
            task.plan_dependency.to_s,
            "Make plan.md depends_on exactly match #{task.folder}/meta.yml."
          )
        end

        nil
      end

      def parse_declaration(value)
        parsed = Hive::Dependencies.parse_declaration(value)
        [ parsed.is_a?(Array) ? parsed : [ parsed ], parsed.is_a?(Array) ]
      rescue Hive::Dependencies::InvalidReference => e
        admission_error(
          "dependency_reference_invalid",
          value.to_s,
          "Use one task reference or a nonempty flat list of task references; #{e.message}."
        )
      end

      def normalized_declaration(value)
        return nil if value.nil?

        Hive::Dependencies.normalize_declaration(value)
      rescue Hive::Dependencies::InvalidReference
        value
      end

      def invalid_reference_correction(task)
        if task.depends_on.is_a?(Array)
          begin
            Hive::Dependencies.parse_declaration(task.depends_on)
            return "Upgrade Hive and restart every daemon or reader before consuming this dependency list; preserve every listed prerequisite."
          rescue Hive::Dependencies::InvalidReference => e
            return "Repair depends_on in #{task.folder}/meta.yml as a nonempty flat list; #{e.message}."
          end
        end

        "Set depends_on in #{task.folder}/meta.yml to one slug, numeric id, or project:slug."
      end

      def resolve_project(current_project, reference)
        name = reference.explicit_project ? reference.project : current_project
        project = unique_project(name)
        return validation_failure(project.validation_error, name) if project&.validation_error
        return project if project

        admission_error("dependency_project_unknown", name, project_correction(name))
      end

      def resolve_task(project, reference)
        matches = if reference.explicit_project || !Hive::Dependencies.numeric?(reference.task)
          task_matches(project, slug: reference.task)
        else
          task_matches(project, id: Integer(reference.task))
        end
        if matches.length > 1
          return validation_failure(
            "dependency reference resolves to multiple tasks",
            reference.to_s
          )
        end
        return matches.first if matches.one?

        admission_error(
          "dependency_task_missing",
          reference.to_s,
          "Correct depends_on or restore the prerequisite task in project #{project.name}."
        )
      end

      def validate_repository_identity(project, reference)
        if project.repository_identity.to_s.empty? || project.live_repository_identity.to_s.empty?
          return admission_error(
            "dependency_repository_identity_missing",
            reference,
            "Configure the project's origin remote and re-enroll it so Hive can store and verify its identity."
          )
        end
        return if project.repository_identity == project.live_repository_identity

        admission_error(
          "dependency_repository_mismatch",
          reference,
          "Verify the registered project path and origin remote, then re-enroll the intended repository."
        )
      end

      def validate_gate(depending_task, prerequisite, prerequisite_project, reference, list_declaration:)
        if prerequisite.cancelled
          return validation_failure(
            "task was cancelled, not delivered; remove or replace this prerequisite", reference.to_s
          )
        end
        depending_project = unique_project(depending_task.project)
        return validation_failure("depending project snapshot is ambiguous", depending_task.project) unless depending_project

        gate = list_declaration ? "9-done" : depending_project.dependency_gate_stage
        unless Hive::Config::DEPENDENCY_GATE_STAGES.include?(gate)
          return admission_error(
            "dependency_gate_unknown",
            gate.to_s,
            "Set dependency_gate_stage to 8-finalize or 9-done in #{depending_project.path}/.hive-state/config.yml."
          )
        end

        gate_index = prerequisite.workflow_stages.index(gate)
        unless gate_index
          correction = if list_declaration
            "Dependency lists require 9-done regardless of project configuration; use a prerequisite workflow that reaches 9-done or correct erroneous workflow metadata."
          else
            "Use a prerequisite workflow that contains #{gate}, or correct the depending project's gate."
          end
          return admission_error(
            "dependency_gate_unreachable",
            "#{prerequisite_project.name}:#{prerequisite.slug}@#{gate}",
            correction
          )
        end

        stage_index = prerequisite.workflow_stages.index(prerequisite.stage)
        unless stage_index
          return admission_error(
            "dependency_gate_unreachable",
            "#{prerequisite_project.name}:#{prerequisite.slug}@#{prerequisite.stage}",
            "Correct the prerequisite's workflow or current-stage metadata so #{prerequisite.stage.inspect} is a valid stage."
          )
        end

        return if stage_index >= gate_index

        unmet = UnmetDependency.new(
          reference: reference.to_s,
          blocked_by: reference.explicit_project ? "#{prerequisite_project.name}:#{prerequisite.slug}" : prerequisite.slug,
          dependency_stage: prerequisite.stage,
          required_gate: gate
        ).freeze
        Blocker.new(identity: qualify(prerequisite), unmet: unmet).freeze
      end

      def unique_project(name)
        matches = @projects_by_name[name] || []
        matches.one? ? matches.first : nil
      end

      def task_matches(project, slug: nil, id: nil)
        index = slug ? @tasks_by_project_slug : @tasks_by_project_id
        matches = index.dig(project.name, slug || id) || []
        return matches unless matches.empty?

        @fallback&.send(:task_matches_by_project_name, project.name, slug: slug, id: id) || []
      end

      def task_matches_by_project_name(project_name, slug: nil, id: nil)
        index = slug ? @tasks_by_project_slug : @tasks_by_project_id
        matches = index.dig(project_name, slug || id) || []
        return matches unless matches.empty?

        @fallback&.send(:task_matches_by_project_name, project_name, slug: slug, id: id) || []
      end

      def qualify(task)
        "#{task.project}:#{task.slug}"
      end

      def project_correction(name)
        "Correct the project name #{name.inspect} or enroll the intended project."
      end

      def task_correction(project)
        "Correct depends_on or restore the prerequisite task in project #{project}."
      end

      def validation_failure(detail, offending_ref)
        admission_error(
          "dependency_validation_failed",
          offending_ref.to_s,
          "Inspect project configuration and dependency metadata; #{detail}."
        )
      end

      def clear
        Verdict.new(state: :clear).freeze
      end

      def wait(blocked_by:, dependency_stage:, unmet_dependencies:)
        Verdict.new(
          state: :wait,
          blocked_by: blocked_by,
          dependency_stage: dependency_stage,
          unmet_dependencies: unmet_dependencies,
          admission_error: nil
        ).freeze
      end

      def admission_error(reason_code, offending_ref, safe_correction)
        raise ArgumentError, "unknown dependency admission reason #{reason_code.inspect}" unless REASON_CODES.include?(reason_code)

        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          unmet_dependencies: EMPTY_UNMET_DEPENDENCIES,
          admission_error: AdmissionError.new(
            reason_code: reason_code,
            offending_ref: offending_ref.to_s,
            safe_correction: safe_correction
          ).freeze
        ).freeze
      end

      def error_verdict(error, unmet_dependencies)
        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          unmet_dependencies: unmet_dependencies,
          admission_error: error
        ).freeze
      end

      def cached_admission_error(error)
        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          unmet_dependencies: EMPTY_UNMET_DEPENDENCIES,
          admission_error: error.freeze
        ).freeze
      end

      def immutable_declaration(value)
        value.is_a?(Array) ? value.dup.freeze : value
      end

      def frozen_group_by(collection, &block)
        collection.group_by(&block).transform_values { |matches| matches.freeze }.freeze
      end
    end
  end
end
