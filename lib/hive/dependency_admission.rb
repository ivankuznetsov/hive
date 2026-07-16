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

    Verdict = Data.define(:state, :blocked_by, :dependency_stage, :admission_error) do
      def clear? = state == :clear
      def wait? = state == :wait
      def error? = state == :error
      def blocked? = !clear?
    end

    TaskSnapshot = Data.define(
      :project, :slug, :id, :stage, :workflow_stages, :depends_on,
      :metadata_status, :metadata_error, :plan_status, :plan_dependency,
      :plan_error, :folder, :validation_error
    )

    ProjectSnapshot = Data.define(
      :name, :path, :repository_identity, :live_repository_identity,
      :dependency_gate_stage, :tasks, :validation_error
    )

    class Context
      attr_reader :projects

      def initialize(projects:)
        @projects = projects.map do |project|
          project.with(tasks: project.tasks.dup.freeze).freeze
        end.freeze
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

        walk(source)
      rescue StandardError => e
        admission_error(
          "dependency_validation_failed",
          "#{project}:#{slug}",
          "Inspect dependency metadata and project enrollment; validation failed with #{e.class}."
        )
      end

      private

      def walk(source)
        visited = []
        current = source
        first_wait = nil

        loop do
          qualified = qualify(current)
          visited << qualified

          node_error = validate_node(current)
          return node_error if node_error
          break unless current.depends_on

          reference = parse_reference(current.depends_on)
          return reference if reference.is_a?(Verdict)

          target_project = resolve_project(current.project, reference)
          return target_project if target_project.is_a?(Verdict)

          if reference.explicit_project
            identity_error = validate_repository_identity(target_project, reference.to_s)
            return identity_error if identity_error
          end

          target = resolve_task(target_project, reference)
          return target if target.is_a?(Verdict)

          target_qualified = qualify(target)
          if target_qualified == qualified
            return admission_error(
              "dependency_self_reference",
              reference.to_s,
              "Remove or correct depends_on in #{current.folder}/meta.yml."
            )
          end
          if (cycle_start = visited.index(target_qualified))
            cycle = (visited[cycle_start..] + [ target_qualified ]).join(" -> ")
            return admission_error(
              "dependency_cycle",
              cycle,
              "Break the cycle by correcting one depends_on declaration in the reported path."
            )
          end

          gate_result = validate_gate(current, target, target_project, reference)
          return gate_result if gate_result&.error?
          first_wait ||= gate_result if gate_result&.wait?
          current = target
        end

        first_wait || clear
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
          return admission_error(
            "dependency_reference_invalid",
            task.depends_on || qualify(task),
            "Set depends_on in #{task.folder}/meta.yml to one slug, numeric id, or project:slug."
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

        if task.plan_dependency && normalized_reference(task.plan_dependency) != normalized_reference(task.depends_on)
          return admission_error(
            "plan_dependency_mismatch",
            task.plan_dependency.to_s,
            "Make plan.md depends_on exactly match #{task.folder}/meta.yml."
          )
        end

        nil
      end

      def parse_reference(value)
        Hive::Dependencies.parse_reference(value)
      rescue Hive::Dependencies::InvalidReference
        admission_error(
          "dependency_reference_invalid",
          value.to_s,
          "Use exactly one task slug or numeric id, or project:slug for an explicit cross-project dependency."
        )
      end

      def normalized_reference(value)
        return nil if value.nil?

        Hive::Dependencies.parse_reference(value).to_s
      rescue Hive::Dependencies::InvalidReference
        value.to_s
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

      def validate_gate(depending_task, prerequisite, prerequisite_project, reference)
        depending_project = unique_project(depending_task.project)
        return validation_failure("depending project snapshot is ambiguous", depending_task.project) unless depending_project

        gate = depending_project.dependency_gate_stage
        unless Hive::Config::DEPENDENCY_GATE_STAGES.include?(gate)
          return admission_error(
            "dependency_gate_unknown",
            gate.to_s,
            "Set dependency_gate_stage to 8-finalize or 9-done in #{depending_project.path}/.hive-state/config.yml."
          )
        end

        gate_index = prerequisite.workflow_stages.index(gate)
        stage_index = prerequisite.workflow_stages.index(prerequisite.stage)
        unless gate_index && stage_index
          return admission_error(
            "dependency_gate_unreachable",
            "#{prerequisite_project.name}:#{prerequisite.slug}@#{gate}",
            "Use a prerequisite workflow that contains #{gate}, or correct the depending project's gate."
          )
        end

        return if stage_index >= gate_index

        wait(
          blocked_by: reference.explicit_project ? "#{prerequisite_project.name}:#{prerequisite.slug}" : prerequisite.slug,
          dependency_stage: prerequisite.stage
        )
      end

      def unique_project(name)
        matches = projects.select { |project| project.name == name }
        matches.one? ? matches.first : nil
      end

      def task_matches(project, slug: nil, id: nil)
        project.tasks.select do |task|
          slug ? task.slug == slug : task.id == id
        end
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
        Verdict.new(state: :clear, blocked_by: nil, dependency_stage: nil, admission_error: nil)
      end

      def wait(blocked_by:, dependency_stage:)
        Verdict.new(
          state: :wait,
          blocked_by: blocked_by,
          dependency_stage: dependency_stage,
          admission_error: nil
        )
      end

      def admission_error(reason_code, offending_ref, safe_correction)
        raise ArgumentError, "unknown dependency admission reason #{reason_code.inspect}" unless REASON_CODES.include?(reason_code)

        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          admission_error: AdmissionError.new(
            reason_code: reason_code,
            offending_ref: offending_ref.to_s,
            safe_correction: safe_correction
          )
        )
      end

      def cached_admission_error(error)
        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          admission_error: error
        )
      end
    end
  end
end
