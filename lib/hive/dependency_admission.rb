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
    CYCLE_REASON_CODES = %w[dependency_cycle dependency_self_reference].freeze
    COVERED_PLAN_REASON_CODES = %w[
      plan_dependency_invalid
      plan_dependency_mismatch
      plan_dependency_missing
    ].freeze

    AdmissionError = Data.define(:reason_code, :offending_ref, :safe_correction) do
      def cycle? = CYCLE_REASON_CODES.include?(reason_code)

      def to_h
        {
          "reason_code" => reason_code,
          "offending_ref" => offending_ref,
          "safe_correction" => safe_correction
        }
      end
    end

    RepairRoot = Data.define(
      :project, :slug, :reason_code, :offending_ref, :safe_correction, :issues
    ) do
      def initialize(project:, slug:, reason_code:, offending_ref:, safe_correction:, issues: [])
        super(
          project: project.to_s,
          slug: slug.to_s,
          reason_code: reason_code.to_s,
          offending_ref: offending_ref.to_s,
          safe_correction: safe_correction.to_s,
          issues: Array(issues).freeze
        )
      end

      def qualified_identity = "#{project}:#{slug}"

      def to_h
        {
          "project" => project,
          "slug" => slug,
          "reason_code" => reason_code,
          "offending_ref" => offending_ref,
          "safe_correction" => safe_correction,
          "issues" => issues.map { |issue| issue.respond_to?(:to_h) ? issue.to_h : issue }
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
      :state, :blocked_by, :dependency_stage, :unmet_dependencies,
      :admission_error, :dependency_repair_roots
    ) do
      def initialize(state:, blocked_by: nil, dependency_stage: nil,
                     unmet_dependencies: EMPTY_UNMET_DEPENDENCIES,
                     admission_error: nil,
                     dependency_repair_roots: EMPTY_REPAIR_ROOTS)
        super(
          state: state,
          blocked_by: blocked_by,
          dependency_stage: dependency_stage,
          unmet_dependencies: unmet_dependencies,
          admission_error: admission_error,
          dependency_repair_roots: Array(dependency_repair_roots).freeze
        )
      end

      def clear? = state == :clear
      def wait? = state == :wait
      def error? = state == :error
      def blocked? = !clear?
    end

    EMPTY_UNMET_DEPENDENCIES = [].freeze
    EMPTY_REPAIR_ROOTS = [].freeze
    EMPTY_REFERENCES = [].freeze
    EMPTY_ISSUES = [].freeze
    EMPTY_ENTRIES = [].freeze
    private_constant :EMPTY_UNMET_DEPENDENCIES, :EMPTY_REPAIR_ROOTS, :EMPTY_REFERENCES,
                     :EMPTY_ISSUES, :EMPTY_ENTRIES

    HintTask = Data.define(:project, :slug, :idempotency_key)

    # Complete, readable project-scoped active+archived task index used solely
    # for suggestion hints. Never substitutes values automatically; suppresses
    # hints on incomplete/unreadable coverage, duplicate identities, or
    # ambiguity across slug-prefix and idempotency-key matches.
    ProjectHintLookup = Data.define(:project, :complete, :tasks, :duplicate_identities) do
      def initialize(project:, complete:, tasks: [], duplicate_identities: [])
        super(
          project: project.to_s,
          complete: complete == true,
          tasks: Array(tasks).freeze,
          duplicate_identities: Array(duplicate_identities).uniq.freeze
        )
      end

      def complete? = complete

      def suggest(raw_value, exclude_slug: nil)
        return nil unless complete?
        return nil unless duplicate_identities.empty?

        code = Hive::Dependencies.hint_code_for(raw_value, current_project: project)
        return nil unless code

        matched = {}
        tasks.each do |candidate|
          next unless candidate.project.to_s == project
          next if exclude_slug && candidate.slug.to_s == exclude_slug.to_s

          slug_match = Hive::Dependencies.slug_prefix_matches?(candidate.slug, code: code)
          key_match = Hive::Dependencies.idempotency_key_matches?(
            candidate.idempotency_key, project: project, code: code
          )
          next unless slug_match || key_match

          identity = [ candidate.project.to_s, candidate.slug.to_s ]
          matched[identity] = candidate.slug.to_s
        end

        matched.size == 1 ? matched.values.first : nil
      end
    end

    Blocker = Data.define(:identity, :unmet)
    Evaluation = Data.define(
      :verdict, :blockers, :repair_roots, :noncovered_error, :cycle_derived, :cycle_anchors
    )
    Frame = Struct.new(
      :task, :identity, :incoming, :entered, :references, :cursor,
      :list_declaration, :direct_blockers, :transitive_blockers,
      :admission_error, :local_covered_error, :local_covered_root,
      :covered_unresolved_identities, :inherited_repair_roots,
      :cycle_derived, :cycle_anchors,
      keyword_init: true
    ) do
      def complete? = cursor >= references.length

      def next_reference
        reference = references[cursor]
        self.cursor += 1
        reference
      end

      def fail!(error, cycle_derived: false, cycle_anchor: nil, cycle_anchors: [])
        cycle_error = error&.cycle?
        self.admission_error = error if admission_error.nil? || cycle_error
        self.cycle_derived ||= cycle_derived
        self.cycle_anchors |= Array(cycle_anchors)
        self.cycle_anchors |= [ cycle_anchor ] if cycle_anchor
      end
    end
    private_constant :Blocker, :Evaluation, :Frame

    # `cancelled` and `superseded_by` mark a task archived by a closure that
    # proves no delivery: cancellation, or supersession resting only on its
    # registered successor (`superseded_by` is that successor's project:slug).
    TaskSnapshot = Data.define(
      :project, :slug, :id, :stage, :workflow_stages, :depends_on,
      :metadata_status, :metadata_error, :plan_status, :plan_dependency,
      :plan_error, :folder, :validation_error, :cancelled, :superseded_by,
      :idempotency_key, :plan_raw_depends_on, :plan_issues, :plan_invalid_kind,
      :plan_entries
    ) do
      def initialize(superseded_by: nil, idempotency_key: nil,
                     plan_raw_depends_on: nil, plan_issues: EMPTY_ISSUES,
                     plan_invalid_kind: nil, plan_entries: EMPTY_ENTRIES,
                     **fields)
        super
      end
    end

    ProjectSnapshot = Data.define(
      :name, :path, :repository_identity, :live_repository_identity,
      :dependency_gate_stage, :tasks, :validation_error
    )

    class Context
      attr_reader :projects

      def initialize(projects:, fallback: nil, hint_provider: nil)
        @projects = projects.map do |project|
          tasks = project.tasks.map do |task|
            task.with(
              workflow_stages: Array(task.workflow_stages).dup.freeze,
              depends_on: immutable_declaration(task.depends_on),
              plan_dependency: immutable_declaration(task.plan_dependency),
              plan_raw_depends_on: Hive::Dependencies.json_safe_value(task.plan_raw_depends_on),
              plan_issues: Array(task.plan_issues).dup.freeze,
              plan_entries: Array(task.plan_entries).dup.freeze
            ).freeze
          end.freeze
          project.with(tasks: tasks).freeze
        end.freeze
        @fallback = fallback
        @hint_provider = hint_provider
        @hint_lookups = {}
        @hint_lookup_mutex = Mutex.new
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

      def project_snapshot(name)
        unique_project(name)
      end

      def resolve_plan_entries(project_name:, entries:)
        covered_issues = []
        noncovered_errors = []

        Array(entries).each do |entry|
          reference = entry.reference
          target_project_name = Hive::Dependencies.reference_project(reference, project_name)
          same_project = target_project_name == project_name
          target_project = unique_project(target_project_name)
          if target_project.nil?
            noncovered_errors << admission_error(
              "dependency_project_unknown", target_project_name, project_correction(target_project_name)
            ).admission_error
            next
          end
          if target_project.validation_error
            noncovered_errors << validation_failure(
              target_project.validation_error, target_project_name
            ).admission_error
            next
          end
          if reference.explicit_project
            identity_error = validate_repository_identity(target_project, reference.to_s)
            if identity_error
              noncovered_errors << identity_error.admission_error
              next
            end
          end

          matches = task_matches_for_reference(target_project, reference)
          if matches.length > 1
            noncovered_errors << validation_failure(
              "dependency reference resolves to multiple tasks", reference.to_s
            ).admission_error
          elsif matches.empty?
            if same_project
              covered_issues << Hive::Dependencies::DeclarationIssue.new(
                index: entry.index,
                raw_value: entry.raw_value,
                code: :unresolved_reference,
                message: "unresolved same-project task #{entry.raw_value.inspect}"
              )
            else
              noncovered_errors << admission_error(
                "dependency_task_missing",
                reference.to_s,
                "Correct depends_on or restore the prerequisite task in project #{target_project.name}."
              ).admission_error
            end
          end
        end

        { covered_issues: covered_issues.freeze, noncovered_errors: noncovered_errors.freeze }
      end

      def enrich_issues_with_hints(project_name:, issues:, exclude_slug: nil, hint_lookup: nil)
        list = Array(issues)
        return list.freeze if list.empty?

        eligible = list.any? do |issue|
          hint_eligible_issue?(issue) &&
            Hive::Dependencies.hint_code_for(issue.raw_value, current_project: project_name)
        end
        return list.freeze unless eligible

        lookup = hint_lookup || hint_lookup_for(project_name)
        return list.freeze unless lookup&.complete?

        list.map do |issue|
          next issue unless hint_eligible_issue?(issue)

          suggestion = lookup.suggest(issue.raw_value, exclude_slug: exclude_slug)
          suggestion ? issue.with(suggestion: suggestion) : issue
        end.freeze
      end

      def validate_prospective_declaration(project:, slug:, depends_on:, plan_dependency:)
        source_project = unique_project(project)
        return admission_error("dependency_project_unknown", project, project_correction(project)) unless source_project
        return validation_failure(source_project.validation_error, project) if source_project.validation_error

        source_matches = task_matches(source_project, slug: slug)
        if source_matches.length > 1
          return validation_failure("duplicate task slug #{slug.inspect}", "#{project}:#{slug}")
        end
        source = source_matches.first
        return admission_error("dependency_task_missing", "#{project}:#{slug}", task_correction(project)) unless source

        entries = if plan_dependency.nil?
          EMPTY_ENTRIES
        else
          Hive::Dependencies.inspect_declaration(plan_dependency).entries
        end
        prospective = source.with(
          depends_on: immutable_declaration(depends_on),
          plan_status: plan_dependency.nil? ? :absent : :ok,
          plan_dependency: immutable_declaration(plan_dependency),
          plan_error: nil,
          plan_issues: EMPTY_ISSUES,
          plan_invalid_kind: nil,
          plan_entries: entries
        ).freeze

        walk(prospective, use_shared_cache: false, override_task: prospective)
      rescue StandardError => e
        admission_error(
          "dependency_validation_failed",
          "#{project}:#{slug}",
          "Inspect dependency metadata and project enrollment; validation failed with #{e.class}."
        )
      end

      # Evaluate admission for one task with its own local plan.md assertion
      # separated. Used exclusively by explicit `hive plan --from 3-plan`
      # root repair so the task can repair its own covered local plan defect
      # while still enforcing every unrelated metadata, environment, cycle,
      # and inherited prerequisite wait.
      def verdict_without_local_plan(project:, slug:)
        source_project = unique_project(project)
        return admission_error("dependency_project_unknown", project, project_correction(project)) unless source_project
        return validation_failure(source_project.validation_error, project) if source_project.validation_error

        source_matches = task_matches(source_project, slug: slug)
        if source_matches.length > 1
          return validation_failure("duplicate task slug #{slug.inspect}", "#{project}:#{slug}")
        end
        source = source_matches.first
        return admission_error("dependency_task_missing", "#{project}:#{slug}", task_correction(project)) unless source
        return clear if source.cancelled || source.superseded_by

        separated = source.with(
          plan_status: :absent,
          plan_dependency: nil,
          plan_error: nil,
          plan_raw_depends_on: nil,
          plan_issues: EMPTY_ISSUES,
          plan_invalid_kind: nil,
          plan_entries: EMPTY_ENTRIES
        ).freeze
        walk(separated, use_shared_cache: false, override_task: separated)
      rescue StandardError => e
        admission_error(
          "dependency_validation_failed",
          "#{project}:#{slug}",
          "Inspect dependency metadata and project enrollment; validation failed with #{e.class}."
        )
      end

      def plan_invalid_error(task_folder:, issues:, fallback_ref: nil, fallback_correction: nil)
        list = Array(issues)
        plan_path = File.join(task_folder.to_s, "plan.md")
        if list.empty?
          return admission_error(
            "plan_dependency_invalid",
            fallback_ref || plan_path,
            fallback_correction || "Repair plan.md YAML frontmatter; do not infer dependencies from prose."
          )
        end

        offending = list.map(&:display_value).reject(&:empty?).uniq.join(", ")
        offending = fallback_ref || plan_path if offending.empty?

        correction = if list.any? { |issue| %i[malformed_frontmatter oversized_frontmatter malformed_yaml non_mapping unreadable_frontmatter].include?(issue.code) }
          "Repair plan.md YAML frontmatter in #{plan_path} (#{list.first.message}); do not infer dependencies from prose."
        elsif list.any? { |issue| issue.code == :duplicate_depends_on }
          "Remove duplicate depends_on keys in #{plan_path} YAML frontmatter (#{offending}); declare one scalar or nonempty flat list."
        else
          details = Hive::Dependencies.format_issue_details(list)
          "Repair depends_on in #{plan_path} using full task slugs (#{details}); do not edit meta.yml or infer dependencies from prose."
        end

        admission_error("plan_dependency_invalid", offending, correction)
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
        return clear if source.cancelled || source.superseded_by

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

      def walk(source, use_shared_cache: true, override_task: nil)
        frames = []
        active_index = {}
        walk_cache = {}
        override_identity = override_task ? qualify(override_task) : nil
        push_frame(frames, active_index, source, incoming: nil)

        until frames.empty?
          frame = frames.last
          enter_frame(frame) unless frame.entered

          if frame.complete?
            evaluation = complete_frame(frame)
            frames.pop
            active_index.delete(frame.identity)
            walk_cache[frame.identity] = evaluation
            @verdict_cache[frame.identity] = evaluation if use_shared_cache && !evaluation.cycle_derived
            return evaluation.verdict if frames.empty?

            absorb_child(frames.last, frame.incoming, evaluation)
            next
          end

          reference = frame.next_reference
          edge = resolve_edge(frame.task, reference, override_task: override_task, override_identity: override_identity)
          if edge.is_a?(Verdict)
            if edge.admission_error.reason_code == "dependency_task_missing" &&
               covered_unresolved_edge?(frame, reference)
              next
            end
            frame.fail!(edge.admission_error)
            next
          end

          target, target_project = edge
          target_identity = qualify(target)
          if target_identity == frame.identity
            cycle = "#{frame.identity} -> #{target_identity}"
            frame.fail!(admission_error(
              "dependency_self_reference",
              cycle,
              "Remove or correct depends_on in #{frame.task.folder}/meta.yml."
            ).admission_error, cycle_derived: true, cycle_anchor: target_identity)
            next
          end
          if (cycle_start = active_index[target_identity])
            cycle = (frames[cycle_start..].map(&:identity) + [ target_identity ]).join(" -> ")
            frame.fail!(admission_error(
              "dependency_cycle",
              cycle,
              "Break the cycle by correcting one depends_on declaration in the reported path."
            ).admission_error, cycle_derived: true, cycle_anchor: target_identity)
            next
          end

          gate_result = validate_gate(
            frame.task, target, target_project, reference,
            list_declaration: frame.list_declaration
          )
          incoming = if gate_result.is_a?(Verdict)
            { blocker: nil, admission_error: gate_result.admission_error }.freeze
          else
            { blocker: gate_result, admission_error: nil }.freeze
          end
          cached = use_shared_cache ? @verdict_cache[target_identity] : nil
          walked = walk_cache[target_identity]
          if cached.nil? && walked && reusable_walk_evaluation?(walked, active_index)
            cached = walked
          end
          if cached
            absorb_child(frame, incoming, cached)
          else
            push_frame(frames, active_index, target, incoming: incoming)
          end
        end
      end

      def push_frame(frames, active_index, task, incoming:)
        identity = qualify(task)
        active_index[identity] = frames.length
        frames << Frame.new(
          task: task, identity: identity, incoming: incoming, entered: false,
          references: EMPTY_REFERENCES, cursor: 0, list_declaration: false,
          direct_blockers: [], transitive_blockers: [], admission_error: nil,
          local_covered_error: nil, local_covered_root: nil,
          covered_unresolved_identities: [], inherited_repair_roots: [],
          cycle_derived: false, cycle_anchors: []
        )
      end

      def enter_frame(frame)
        frame.entered = true
        node_result = validate_node(frame.task)
        if node_result
          if node_result.is_a?(Hash) && node_result[:covered_root]
            frame.local_covered_error = node_result[:error]
            frame.local_covered_root = node_result[:covered_root]
            frame.covered_unresolved_identities = node_result[:covered_unresolved_identities]
            # Continue walking parsable metadata prerequisites after a covered
            # local plan error so independently broken descendants still collect
            # inherited roots, cycles, and ordinary blockers.
          else
            error = node_result.is_a?(Hash) ? node_result[:error] : node_result.admission_error
            frame.fail!(error)
            return
          end
        end
        return unless frame.task.depends_on

        declaration = parse_declaration(frame.task.depends_on)
        if declaration.is_a?(Verdict)
          frame.fail!(declaration.admission_error)
          return
        end

        references, list_declaration = declaration
        frame.references = references
        frame.list_declaration = list_declaration
      end

      def covered_unresolved_edge?(frame, reference)
        return false if frame.covered_unresolved_identities.empty?

        edge_identity = Hive::Dependencies.reference_identity(reference, frame.task.project)
        frame.covered_unresolved_identities.include?(edge_identity)
      end

      def resolve_edge(task, reference, override_task: nil, override_identity: nil)
        target_project = resolve_project(task.project, reference)
        return target_project if target_project.is_a?(Verdict)

        if reference.explicit_project
          identity_error = validate_repository_identity(target_project, reference.to_s)
          return identity_error if identity_error
        end

        target = resolve_task(target_project, reference)
        return target if target.is_a?(Verdict)
        target = override_task if override_task && qualify(target) == override_identity

        [ target, target_project ]
      end

      def absorb_child(frame, incoming, evaluation)
        if incoming[:blocker]
          frame.direct_blockers << incoming[:blocker]
        else
          frame.transitive_blockers.concat(
            evaluation.blockers.map { |blocker| blocker_for_requesting_project(frame, blocker) }
          )
        end
        # Always merge repair roots even when an unmet direct edge suppresses
        # ordinary transitive blockers so a waiting sibling cannot hide a
        # deeper broken root.
        frame.inherited_repair_roots.concat(evaluation.repair_roots)
        frame.fail!(incoming[:admission_error]) if incoming[:admission_error]
        return unless evaluation.noncovered_error

        frame.fail!(
          evaluation.noncovered_error,
          cycle_derived: evaluation.cycle_derived,
          cycle_anchors: evaluation.cycle_anchors
        )
      end

      def complete_frame(frame)
        blockers = deduplicate_blockers(frame.direct_blockers + frame.transitive_blockers)
        unmet = blockers.map(&:unmet).freeze
        inherited_roots = deduplicate_repair_roots(frame.inherited_repair_roots)
        propagated_roots = deduplicate_repair_roots(
          (frame.local_covered_root ? [ frame.local_covered_root ] : []) + inherited_roots
        )
        singular = frame.list_declaration ? nil : frame.direct_blockers.first&.unmet
        effective_error = if frame.admission_error&.cycle?
          frame.admission_error
        else
          frame.local_covered_error || frame.admission_error
        end
        verdict = if effective_error
          error_verdict(effective_error, unmet, dependency_repair_roots: inherited_roots)
        elsif blockers.empty? && inherited_roots.empty?
          clear
        else
          wait(
            blocked_by: singular&.blocked_by,
            dependency_stage: singular&.dependency_stage,
            unmet_dependencies: unmet,
            dependency_repair_roots: inherited_roots
          )
        end
        Evaluation.new(
          verdict: verdict.freeze,
          blockers: blockers.freeze,
          repair_roots: propagated_roots,
          noncovered_error: frame.admission_error,
          cycle_derived: frame.cycle_derived,
          cycle_anchors: frame.cycle_anchors.uniq.freeze
        ).freeze
      end

      def deduplicate_repair_roots(roots)
        seen = {}
        Array(roots).each_with_object([]) do |root, result|
          key = root.qualified_identity
          next if seen.key?(key)

          seen[key] = true
          result << root
        end.freeze
      end

      def reusable_walk_evaluation?(evaluation, active_index)
        !evaluation.cycle_derived || evaluation.cycle_anchors.all? { |anchor| active_index.key?(anchor) }
      end

      def blocker_for_requesting_project(frame, blocker)
        blocker_project, = blocker.identity.split(":", 2)
        return blocker if blocker_project == frame.task.project

        Blocker.new(
          identity: blocker.identity,
          unmet: blocker.unmet.with(
            reference: blocker.identity, blocked_by: blocker.identity
          ).freeze
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
          error = task.validation_error.is_a?(AdmissionError) ?
            task.validation_error :
            validation_failure(task.validation_error, qualify(task)).admission_error
          return { error: error, covered_root: nil, covered_unresolved_identities: [] }
        end

        case task.metadata_status
        when :unreadable
          return {
            error: admission_error(
              "dependency_metadata_unreadable",
              qualify(task),
              "Repair #{task.folder}/meta.yml without removing dependency evidence."
            ).admission_error,
            covered_root: nil,
            covered_unresolved_identities: []
          }
        when :invalid_reference
          correction = invalid_reference_correction(task)
          return {
            error: admission_error(
              "dependency_reference_invalid",
              task.depends_on ? Hive::Dependencies.display_declaration(task.depends_on) : qualify(task),
              correction
            ).admission_error,
            covered_root: nil,
            covered_unresolved_identities: []
          }
        when :invalid
          return {
            error: admission_error(
              "dependency_metadata_invalid",
              qualify(task),
              "Repair #{task.folder}/meta.yml as a YAML mapping and preserve the intended depends_on value."
            ).admission_error,
            covered_root: nil,
            covered_unresolved_identities: []
          }
        end

        if task.plan_status == :invalid || (task.plan_status == :ok && !task.plan_dependency.nil?)
          entries = plan_entries_for(task)
          resolved = resolve_plan_entries(project_name: task.project, entries: entries)
          covered_issues = sort_issues(Array(task.plan_issues) + resolved[:covered_issues])
          if task.plan_status == :invalid && covered_issues.empty?
            error = plan_invalid_error(task_folder: task.folder, issues: []).admission_error
            return covered_node_result(task, error: error, issues: [])
          end
          unless covered_issues.empty?
            enriched = enrich_issues_with_hints(
              project_name: task.project,
              issues: covered_issues,
              exclude_slug: task.slug
            )
            error = plan_invalid_error(task_folder: task.folder, issues: enriched).admission_error
            unresolved_ids = resolved[:covered_issues].filter_map do |issue|
              entry = entries.find { |e| e.index == issue.index && e.raw_value == issue.raw_value }
              next unless entry

              Hive::Dependencies.reference_identity(entry.reference, task.project)
            end.uniq.freeze
            return covered_node_result(
              task, error: error, issues: enriched, covered_unresolved_identities: unresolved_ids
            )
          end
        end

        if task.plan_dependency && task.depends_on.nil?
          offending = Hive::Dependencies.display_declaration(task.plan_dependency)
          error = admission_error(
            "plan_dependency_missing",
            offending,
            "Add the same depends_on value to #{task.folder}/meta.yml or remove the stale plan assertion."
          ).admission_error
          issue = Hive::Dependencies::DeclarationIssue.new(
            index: nil,
            raw_value: task.plan_dependency,
            display_value: offending,
            code: :plan_dependency_missing,
            message: "plan.md depends_on (#{offending}) is absent from meta.yml"
          )
          return covered_node_result(task, error: error, issues: [ issue ])
        end

        if task.plan_dependency && normalized_declaration(task.plan_dependency) != normalized_declaration(task.depends_on)
          offending = Hive::Dependencies.display_declaration(task.plan_dependency)
          error = admission_error(
            "plan_dependency_mismatch",
            offending,
            "Make plan.md depends_on exactly match #{task.folder}/meta.yml."
          ).admission_error
          issue = Hive::Dependencies::DeclarationIssue.new(
            index: nil,
            raw_value: task.plan_dependency,
            display_value: offending,
            code: :plan_dependency_mismatch,
            message: "plan.md depends_on (#{offending}) disagrees with meta.yml"
          )
          return covered_node_result(task, error: error, issues: [ issue ])
        end

        nil
      end

      def covered_node_result(task, error:, issues:, covered_unresolved_identities: [])
        root = RepairRoot.new(
          project: task.project,
          slug: task.slug,
          reason_code: error.reason_code,
          offending_ref: error.offending_ref,
          safe_correction: error.safe_correction,
          issues: issues
        ).freeze
        {
          error: error,
          covered_root: root,
          covered_unresolved_identities: covered_unresolved_identities
        }
      end

      def plan_entries_for(task)
        return task.plan_entries unless Array(task.plan_entries).empty?
        return EMPTY_ENTRIES if task.plan_dependency.nil?

        Hive::Dependencies.inspect_declaration(task.plan_dependency).entries
      end

      def sort_issues(issues)
        Array(issues).each_with_index.sort_by do |issue, order|
          [ issue.index.nil? ? 0 : 1, issue.index || 0, order ]
        end.map(&:first).freeze
      end

      def hint_eligible_issue?(issue)
        %i[task_code_shorthand invalid_reference unresolved_reference].include?(issue.code)
      end

      def hint_lookup_for(project_name)
        return nil unless @hint_provider

        @hint_lookup_mutex.synchronize do
          return @hint_lookups[project_name] if @hint_lookups.key?(project_name)

          @hint_lookups[project_name] = @hint_provider.call(project_name)
        end
      end

      def parse_declaration(value)
        parsed = Hive::Dependencies.parse_declaration(value)
        [ parsed.is_a?(Array) ? parsed : [ parsed ], parsed.is_a?(Array) ]
      rescue Hive::Dependencies::InvalidReference => e
        admission_error(
          "dependency_reference_invalid",
          Hive::Dependencies.display_declaration(value),
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
        name = Hive::Dependencies.reference_project(reference, current_project)
        project = unique_project(name)
        return validation_failure(project.validation_error, name) if project&.validation_error
        return project if project

        admission_error("dependency_project_unknown", name, project_correction(name))
      end

      def resolve_task(project, reference)
        matches = task_matches_for_reference(project, reference)
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

      def task_matches_for_reference(project, reference)
        if reference.explicit_project || !Hive::Dependencies.numeric?(reference.task)
          task_matches(project, slug: reference.task)
        else
          task_matches(project, id: Integer(reference.task))
        end
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
        if prerequisite.superseded_by
          return validation_failure(
            "task was superseded by #{prerequisite.superseded_by} without delivery; " \
            "depend on #{prerequisite.superseded_by} instead (hive stack --on)", reference.to_s
          )
        end
        depending_project = unique_project(depending_task.project)
        return validation_failure("depending project snapshot is ambiguous", depending_task.project) unless depending_project

        gate = if list_declaration
          Hive::Config::DEPENDENCY_GATE_STAGES.last
        else
          depending_project.dependency_gate_stage
        end
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
            "Task #{depending_task.project}:#{depending_task.slug} declares a dependency list in " \
              "#{depending_task.folder}/meta.yml; lists require #{gate} regardless of project " \
              "configuration. Use a prerequisite workflow that reaches #{gate} or correct " \
              "erroneous workflow metadata."
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

      def wait(blocked_by:, dependency_stage:, unmet_dependencies:,
               dependency_repair_roots: EMPTY_REPAIR_ROOTS)
        Verdict.new(
          state: :wait,
          blocked_by: blocked_by,
          dependency_stage: dependency_stage,
          unmet_dependencies: unmet_dependencies,
          admission_error: nil,
          dependency_repair_roots: dependency_repair_roots
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

      def error_verdict(error, unmet_dependencies, dependency_repair_roots: EMPTY_REPAIR_ROOTS)
        Verdict.new(
          state: :error,
          blocked_by: nil,
          dependency_stage: nil,
          unmet_dependencies: unmet_dependencies,
          admission_error: error,
          dependency_repair_roots: dependency_repair_roots
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
