require "digest"
require "hive/dependencies"
require "hive/dependency_admission"
require "hive/dependency_snapshot"
require "hive/plan_frontmatter"
require "hive/task_meta"

module Hive
  # Shared read-only plan dependency validator and guarded metadata adoption.
  #
  # Validation order:
  # 1. Read authoritative metadata (metadata corruption stays in admission).
  # 2. Parse bounded plan frontmatter (retaining duplicate-key and 64 KiB guards
  #    and preserving raw offending values/shapes and every per-element issue).
  # 3. Check every asserted reference before missing/mismatch checks, reporting
  #    covered unresolved same-project assertions as `plan_dependency_invalid`
  #    and keeping environmental/cross-project/ambiguity errors non-covered.
  # 4. Calculate prospective metadata using the strict-superset / absence rule
  #    (compared by `Dependencies.reference_identity`), leaving subsets,
  #    reorders, replacements, and re-spellings as covered
  #    `plan_dependency_mismatch`.
  # 5. Validate the prospective declaration without writing (rejecting cycles,
  #    self-references, cancelled/superseded targets, and unreachable gates
  #    without spending a planner correction).
  # 6. Only then permit adoption under custody, rechecking digests, task
  #    observations, and local lookup observations (no live git probes under
  #    lock), and verify authoritative metadata agreement after writing.
  module PlanDependencyAdoption
    MAX_CUSTODY_RETRIES = 3

    ValidationResult = Data.define(
      :status, :reason_code, :offending_ref, :safe_correction, :issues,
      :adoptable, :prospective_depends_on, :plan_declaration, :current_depends_on,
      :plan_digest, :meta_digest, :lookup_signature, :admission_error
    ) do
      def initialize(status:, reason_code: nil, offending_ref: nil, safe_correction: nil,
                     issues: [], adoptable: false, prospective_depends_on: nil,
                     plan_declaration: nil, current_depends_on: nil,
                     plan_digest: nil, meta_digest: nil, lookup_signature: nil,
                     admission_error: nil)
        super(
          status: status.to_sym,
          reason_code: reason_code,
          offending_ref: offending_ref,
          safe_correction: safe_correction,
          issues: Array(issues).freeze,
          adoptable: adoptable == true,
          prospective_depends_on: prospective_depends_on,
          plan_declaration: plan_declaration,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: lookup_signature,
          admission_error: admission_error
        )
      end

      def ok? = status == :ok
      def covered_defect? = status == :covered_defect
      def noncovered_error? = status == :noncovered_error
      def stale? = status == :stale
      def adoptable? = ok? && adoptable

      def to_h
        {
          "status" => status.to_s,
          "reason_code" => reason_code,
          "offending_ref" => offending_ref,
          "safe_correction" => safe_correction,
          "issues" => issues.map(&:to_h),
          "adoptable" => adoptable,
          "prospective_depends_on" => Hive::Dependencies.json_safe_value(prospective_depends_on),
          "plan_declaration" => Hive::Dependencies.json_safe_value(plan_declaration),
          "current_depends_on" => Hive::Dependencies.json_safe_value(current_depends_on),
          "plan_digest" => plan_digest,
          "meta_digest" => meta_digest,
          "admission_error" => admission_error&.to_h
        }
      end
    end

    AdoptionResult = Data.define(:status, :adopted, :validation, :depends_on, :error) do
      def initialize(status:, adopted: false, validation: nil, depends_on: nil, error: nil)
        super(
          status: status.to_sym,
          adopted: adopted == true,
          validation: validation,
          depends_on: depends_on,
          error: error
        )
      end

      def ok? = %i[adopted unchanged].include?(status)
      def adopted? = status == :adopted
      def stale? = status == :stale
      def covered_defect? = status == :covered_defect
      def noncovered_error? = status == :noncovered_error
    end

    module_function

    # Pure read-only validation of canonical plan.md or candidate plan_bytes.
    # Never modifies plan.md or meta.yml. Build or pass `admission_context`
    # outside any mutation critical section.
    def validate(task, plan_bytes: nil, plan_path: nil, admission_context: nil,
                 registry_entries: nil, hint_lookup: nil, lookup_signature: nil)
      resolved_plan_path = plan_path || File.join(task.folder, "plan.md")
      meta_digest = Hive::TaskMeta.file_digest(task.folder)
      metadata = Hive::TaskMeta.read_for_admission(task.folder)
      current_depends_on = metadata.data[:depends_on]

      if meta_digest == :invalid || !metadata.ok?
        error = metadata_admission_error(task, metadata)
        return noncovered_result(
          error,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest_for(plan_bytes, resolved_plan_path),
          meta_digest: meta_digest,
          lookup_signature: lookup_signature
        )
      end

      plan_digest = plan_digest_for(plan_bytes, resolved_plan_path)
      plan_read = if !plan_bytes.nil?
        Hive::PlanFrontmatter.parse(plan_bytes, label: resolved_plan_path)
      else
        Hive::PlanFrontmatter.read(resolved_plan_path)
      end

      if plan_read.status == :absent || (plan_read.status == :ok && !plan_read.has_depends_on?)
        return ValidationResult.new(
          status: :ok,
          adoptable: false,
          prospective_depends_on: current_depends_on,
          plan_declaration: nil,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: lookup_signature
        ).freeze
      end

      if plan_read.status == :invalid && plan_read.invalid_kind == :unreadable
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_validation_failed",
          offending_ref: resolved_plan_path,
          safe_correction: "Ensure #{resolved_plan_path} is a readable regular file and retry."
        ).freeze
        return noncovered_result(
          error,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: lookup_signature
        )
      end

      entries_list = registry_entries || Hive::Config.registered_projects
      project_name = task_project_name(task, registry_entries: entries_list)
      context = admission_context
      effective_signature = lookup_signature

      if context.nil?
        needs_context = !plan_read.entries.empty? || plan_read.status == :ok
        if needs_context
          if task.respond_to?(:project_root) && task.project_root
            built = Hive::DependencySnapshot.plan_validation_context(
              task, plan_read: plan_read, registry_entries: entries_list
            )
            if built.enrollment_error
              return noncovered_result(
                built.enrollment_error,
                plan_declaration: plan_read.raw_depends_on,
                current_depends_on: current_depends_on,
                plan_digest: plan_digest,
                meta_digest: meta_digest
              )
            end
            context = built.context
            project_name = built.project_name
            effective_signature = built.lookup_signature
          else
            return noncovered_result(
              Hive::DependencyAdmission::AdmissionError.new(
                reason_code: "dependency_validation_failed",
                offending_ref: "#{project_name}:#{task.slug}",
                safe_correction: "Inspect project enrollment and supply an admission context."
              ).freeze,
              plan_declaration: plan_read.raw_depends_on,
              current_depends_on: current_depends_on,
              plan_digest: plan_digest,
              meta_digest: meta_digest
            )
          end
        end
      end

      resolved_entries = if context && !plan_read.entries.empty?
        context.resolve_plan_entries(project_name: project_name, entries: plan_read.entries)
      else
        { covered_issues: [], noncovered_errors: [] }
      end

      covered_issues = sort_issues(Array(plan_read.issues) + resolved_entries[:covered_issues])
      unless covered_issues.empty?
        enriched = enrich_issues(
          project_name: project_name,
          issues: covered_issues,
          exclude_slug: task.slug,
          context: context,
          hint_lookup: hint_lookup,
          registry_entries: entries_list
        )
        error = build_plan_invalid_error(
          task_folder: task.folder, issues: enriched, context: context
        )
        return ValidationResult.new(
          status: :covered_defect,
          reason_code: error.reason_code,
          offending_ref: error.offending_ref,
          safe_correction: error.safe_correction,
          issues: enriched,
          adoptable: false,
          prospective_depends_on: current_depends_on,
          plan_declaration: plan_read.raw_depends_on,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: effective_signature,
          admission_error: error
        ).freeze
      end

      unless resolved_entries[:noncovered_errors].empty?
        return noncovered_result(
          resolved_entries[:noncovered_errors].first,
          plan_declaration: plan_read.raw_depends_on,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: effective_signature
        )
      end

      declared = plan_read.depends_on
      serialized = Hive::Dependencies.serialize_declaration(declared)

      if self_reference?(task, declared, project_name: project_name)
        cycle = "#{project_name}:#{task.slug} -> #{project_name}:#{task.slug}"
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_self_reference",
          offending_ref: cycle,
          safe_correction: "Remove or correct depends_on in #{task.folder}/plan.md and #{task.folder}/meta.yml."
        ).freeze
        return noncovered_result(
          error,
          plan_declaration: serialized,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: effective_signature
        )
      end

      normalized_current = current_depends_on.nil? ? nil : Hive::Dependencies.normalize_declaration(current_depends_on)
      already_matches = !current_depends_on.nil? && serialized == normalized_current
      can_adopt = !already_matches && adoptable?(declared, current_depends_on, task, project_name: project_name)

      unless already_matches || can_adopt
        offending = Hive::Dependencies.display_declaration(serialized)
        current_display = Hive::Dependencies.display_declaration(normalized_current)
        correction = "Make plan.md depends_on exactly match #{task.folder}/meta.yml " \
                     "(current meta.yml depends_on: #{current_display}) or declare a valid strict superset."
        issue = Hive::Dependencies::DeclarationIssue.new(
          index: nil,
          raw_value: serialized,
          display_value: offending,
          code: :plan_dependency_mismatch,
          message: "plan.md depends_on (#{offending}) disagrees with meta.yml depends_on (#{current_display})"
        )
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "plan_dependency_mismatch",
          offending_ref: offending,
          safe_correction: correction
        ).freeze
        return ValidationResult.new(
          status: :covered_defect,
          reason_code: error.reason_code,
          offending_ref: error.offending_ref,
          safe_correction: error.safe_correction,
          issues: [ issue ],
          adoptable: false,
          prospective_depends_on: current_depends_on,
          plan_declaration: serialized,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: effective_signature,
          admission_error: error
        ).freeze
      end

      prospective = can_adopt ? serialized : normalized_current
      prospective_verdict = context.validate_prospective_declaration(
        project: project_name,
        slug: task.slug,
        depends_on: prospective,
        plan_dependency: serialized
      )
      if prospective_verdict.error?
        return noncovered_result(
          prospective_verdict.admission_error,
          plan_declaration: serialized,
          current_depends_on: current_depends_on,
          plan_digest: plan_digest,
          meta_digest: meta_digest,
          lookup_signature: effective_signature
        )
      end

      ValidationResult.new(
        status: :ok,
        adoptable: can_adopt,
        prospective_depends_on: prospective,
        plan_declaration: serialized,
        current_depends_on: current_depends_on,
        plan_digest: plan_digest,
        meta_digest: meta_digest,
        lookup_signature: effective_signature
      ).freeze
    end

    # Recheck local digests, task observation, and local lookup observations
    # under custody without running any live repository identity probes.
    def fresh_under_custody?(task, observation:, validation:, plan_bytes: nil, plan_path: nil)
      Hive::TaskMeta.validate_observation!(task.folder, observation)
      resolved_plan_path = plan_path || File.join(task.folder, "plan.md")
      return false unless Hive::TaskMeta.file_digest(task.folder) == validation.meta_digest
      return false unless plan_digest_for(plan_bytes, resolved_plan_path) == validation.plan_digest
      return false unless Hive::DependencySnapshot.lookup_signature_current?(validation.lookup_signature)

      true
    rescue Hive::TaskMeta::StaleTask, Errno::ENOENT, Errno::ENOTDIR
      false
    end

    # Validate (or reuse pre-built validation) and adopt permitted metadata
    # changes under custody. If `validation:` is not supplied, retries when
    # lookup observations change between context build and custody.
    def adopt_validated!(task, observation:, admission_context: nil, registry_entries: nil,
                         validation: nil, max_retries: MAX_CUSTODY_RETRIES)
      Hive::TaskMeta.validate_observation!(task.folder, observation)

      if validation
        return apply_validated_adoption!(task, observation: observation, validation: validation)
      end

      attempts = 0
      loop do
        attempts += 1
        current_validation = validate(
          task,
          admission_context: admission_context,
          registry_entries: registry_entries
        )
        result = apply_validated_adoption!(
          task, observation: observation, validation: current_validation
        )
        return result unless result.stale? && admission_context.nil? && attempts < max_retries
      end
    rescue Hive::TaskMeta::StaleTask, Errno::ENOENT, Errno::ENOTDIR => error
      AdoptionResult.new(status: :stale, error: error)
    rescue Hive::TaskMeta::InvalidMetadata, SystemCallError, IOError, ArgumentError => error
      AdoptionResult.new(status: :failed, error: error)
    end

    def apply_validated_adoption!(task, observation:, validation:)
      unless fresh_under_custody?(task, observation: observation, validation: validation)
        return AdoptionResult.new(status: :stale, validation: validation)
      end

      return AdoptionResult.new(status: :covered_defect, validation: validation) if validation.covered_defect?
      return AdoptionResult.new(status: :noncovered_error, validation: validation) if validation.noncovered_error?

      unless validation.adoptable?
        return AdoptionResult.new(
          status: :unchanged, adopted: false, validation: validation,
          depends_on: validation.current_depends_on
        )
      end

      result = Hive::TaskMeta.rewrite(
        task.folder,
        { depends_on: validation.prospective_depends_on },
        observation: observation
      )
      return AdoptionResult.new(status: :stale, validation: validation) if result.stale?

      unless authoritative_agreement?(task, expected_declaration: validation.plan_declaration)
        return AdoptionResult.new(status: :stale, validation: validation)
      end

      AdoptionResult.new(
        status: :adopted,
        adopted: true,
        validation: validation,
        depends_on: validation.prospective_depends_on
      )
    end

    def authoritative_agreement?(task, expected_declaration:)
      meta = Hive::TaskMeta.read_for_admission(task.folder)
      return false unless meta.ok?

      plan = Hive::PlanFrontmatter.read(File.join(task.folder, "plan.md"))
      return false unless plan.valid?
      return true unless plan.has_depends_on?

      plan_normalized = Hive::Dependencies.serialize_declaration(plan.depends_on)
      meta_normalized = meta.data[:depends_on].nil? ? nil : Hive::Dependencies.normalize_declaration(meta.data[:depends_on])
      plan_normalized == meta_normalized &&
        (expected_declaration.nil? || plan_normalized == expected_declaration)
    rescue Hive::Dependencies::InvalidReference
      false
    end

    def adopt!(task, observation:, admission_context: nil, registry_entries: nil)
      outcome = adopt_validated!(
        task,
        observation: observation,
        admission_context: admission_context,
        registry_entries: registry_entries
      )
      if outcome.stale?
        warn "[hive] plan: stale task; dependency adoption skipped for #{task.slug}"
      elsif outcome.status == :failed && outcome.error
        warn "[hive] plan: dependency adoption failed for #{task.slug} " \
             "(#{outcome.error.class}: #{outcome.error.message.to_s.byteslice(0, 240)})"
      end
      nil
    end

    # PlanFrontmatter already parsed and validated `declared` into a Reference
    # or an array of References; malformed declarations never reach here.
    def self_reference?(task, declared, project_name: nil)
      owner_project = project_name || task_project_name(task)
      Array(declared).any? do |reference|
        same_slug = reference.task == task.slug
        same_numeric_id = !reference.explicit_project && !task.id.nil? && reference.task == task.id.to_s
        same_qualified_identity = reference.explicit_project &&
          reference.project == owner_project && same_slug
        (!reference.explicit_project && same_slug) || same_numeric_id || same_qualified_identity
      end
    end

    # `current` is meta.yml's raw value; an unparseable one raises
    # InvalidReference (an ArgumentError) and is reported, never replaced.
    def adoptable?(declared, current, task, project_name: nil)
      return true if current.nil?

      owner_project = project_name || task_project_name(task)
      planned = Array(declared).map { |reference| identity(reference, task, project_name: owner_project) }.uniq
      existing = Hive::Dependencies.declaration_references(current)
                                   .map { |reference| identity(reference, task, project_name: owner_project) }.uniq
      (existing - planned).empty? && !(planned - existing).empty?
    end

    def identity(reference, task, project_name: nil)
      Hive::Dependencies.reference_identity(reference, project_name || task_project_name(task))
    end

    def task_project_name(task, registry_entries: nil)
      if task.respond_to?(:project_root) && !task.project_root.to_s.empty? && registry_entries
        expanded = File.expand_path(task.project_root.to_s)
        match = Array(registry_entries).find do |entry|
          entry.is_a?(Hash) && entry["path"] && File.expand_path(entry["path"].to_s) == expanded
        end
        return match["name"].to_s if match && !match["name"].to_s.empty?
      end
      return task.project_name if task.respond_to?(:project_name) && task.project_name
      return File.basename(task.project_root) if task.respond_to?(:project_root) && task.project_root

      ""
    end

    def plan_digest_for(plan_bytes, plan_path)
      return Digest::SHA256.hexdigest(plan_bytes.b) unless plan_bytes.nil?

      Hive::PlanFrontmatter.file_digest(plan_path)
    end

    def metadata_admission_error(task, metadata)
      qualified = "#{task_project_name(task)}:#{task.slug}"
      case metadata.status
      when :unreadable
        Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_metadata_unreadable",
          offending_ref: qualified,
          safe_correction: "Repair #{task.folder}/meta.yml without removing dependency evidence."
        ).freeze
      when :invalid
        if metadata.reason == :reference_invalid
          offending = metadata.data[:depends_on] ?
            Hive::Dependencies.display_declaration(metadata.data[:depends_on]) : qualified
          Hive::DependencyAdmission::AdmissionError.new(
            reason_code: "dependency_reference_invalid",
            offending_ref: offending,
            safe_correction: "Repair depends_on in #{task.folder}/meta.yml."
          ).freeze
        else
          Hive::DependencyAdmission::AdmissionError.new(
            reason_code: "dependency_metadata_invalid",
            offending_ref: qualified,
            safe_correction: "Repair #{task.folder}/meta.yml as a YAML mapping and preserve the intended depends_on value."
          ).freeze
        end
      else
        Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_metadata_unreadable",
          offending_ref: qualified,
          safe_correction: "Repair #{task.folder}/meta.yml without removing dependency evidence."
        ).freeze
      end
    end

    def noncovered_result(error, plan_declaration: nil, current_depends_on: nil,
                          plan_digest: nil, meta_digest: nil, lookup_signature: nil)
      ValidationResult.new(
        status: :noncovered_error,
        reason_code: error.reason_code,
        offending_ref: error.offending_ref,
        safe_correction: error.safe_correction,
        issues: [],
        adoptable: false,
        prospective_depends_on: current_depends_on,
        plan_declaration: plan_declaration,
        current_depends_on: current_depends_on,
        plan_digest: plan_digest,
        meta_digest: meta_digest,
        lookup_signature: lookup_signature,
        admission_error: error
      ).freeze
    end

    def enrich_issues(project_name:, issues:, exclude_slug:, context:, hint_lookup:, registry_entries:)
      if context
        return context.enrich_issues_with_hints(
          project_name: project_name,
          issues: issues,
          exclude_slug: exclude_slug,
          hint_lookup: hint_lookup
        )
      end

      eligible = Array(issues).any? do |issue|
        %i[task_code_shorthand invalid_reference unresolved_reference].include?(issue.code) &&
          Hive::Dependencies.hint_code_for(issue.raw_value, current_project: project_name)
      end
      return Array(issues).freeze unless eligible

      lookup = hint_lookup || Hive::DependencySnapshot.project_hint_lookup(
        project_name, registry_entries: registry_entries
      )
      return Array(issues).freeze unless lookup&.complete?

      Array(issues).map do |issue|
        next issue unless %i[task_code_shorthand invalid_reference unresolved_reference].include?(issue.code)

        suggestion = lookup.suggest(issue.raw_value, exclude_slug: exclude_slug)
        suggestion ? issue.with(suggestion: suggestion) : issue
      end.freeze
    end

    def build_plan_invalid_error(task_folder:, issues:, context:)
      if context
        return context.plan_invalid_error(task_folder: task_folder, issues: issues).admission_error
      end

      Hive::DependencyAdmission::Context.new(projects: []).plan_invalid_error(
        task_folder: task_folder, issues: issues
      ).admission_error
    end

    def sort_issues(issues)
      Array(issues).each_with_index.sort_by do |issue, order|
        [ issue.index.nil? ? 0 : 1, issue.index || 0, order ]
      end.map(&:first).freeze
    end
  end
end
