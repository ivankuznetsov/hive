require "hive/work_ledger"

module Hive
  Workflow = Data.define(:id, :stages) do
    def initialize(id:, stages:)
      # Shallow freeze: the element Stages stay shared with the caller, which is
      # safe only because Stage is itself frozen. This dup does NOT deep-copy.
      super(id: id, stages: stages.dup.freeze)
      validate_structure!
    end
  end

  # Reopened (not redefined) so the nested Stage/AdvanceVerb constants resolve as
  # Workflow::Stage — Data.define's block can't host constant declarations.
  class Workflow
    include Enumerable

    # :agent selects the agent runner, :council selects the generic document
    # council runner, :inert auto-advances with no runner,
    # :execute/:review_council/:finalize drive coding status/action
    # classification (the coding runners are selected by name, not kind — see
    # Stages::Resolver), and nil is the unspecified default.
    KNOWN_KINDS = [ nil, :agent, :council, :inert, :execute, :review_council, :finalize ].freeze

    # Single source of truth for the council triage artifact default. Referenced
    # by the Council default below, the descriptor parser, and both council
    # runners (council.rb round-tracking + triage.rb path building) so the value
    # can't drift across those copies.
    DEFAULT_TRIAGE_OUTPUT = "reviews/triage.md"
    MAPPING_ROLES = %w[planning development reviewer].freeze

    ExecutableSlot = Data.define(:id, :kind, :actor, :default_role)

    def each(&) = stages.each(&)

    def stage_named(name) = find { |stage| stage.name == name }
    def stage_for_dir(dir) = find { |stage| stage.dir == dir }

    # The next stage in sequence, or nil at the terminal stage. (An unknown name
    # also folds into nil; every live caller passes a validated name, so only the
    # terminal-nil arm is reachable today.)
    def next_stage_after(name)
      index = find_index { |stage| stage.name == name }
      index && stages[index + 1]
    end

    # The verb that ARRIVES AT this stage, not the one that advances out of it.
    # nil means bare-mv advance (no inbound verb) or an unknown name.
    def advance_verb_for(name) = stage_named(name)&.advance_verb&.name

    # A full dir (`3-plan`) or a short name (`plan`) → the canonical Stage#dir, so
    # callers (rename targets, commit messages) get the descriptor's dir.
    def resolve_stage_ref(ref) = (stage_for_dir(ref) || stage_named(ref))&.dir
    def has_stage?(ref) = !resolve_stage_ref(ref).nil?

    # Hard resolve: a missing stage here is a programmer error, not recoverable.
    # (Returns the matched stage's state_file verbatim — only an unknown NAME
    # raises, matching the original; a found stage's nil state_file would not.)
    def state_file_for(name)
      stage = stage_named(name) or
        raise KeyError, "unknown stage #{name.inspect} for workflow #{id.inspect}"
      stage.state_file
    end

    # Frozen to match Task::STAGE_NAMES's immutability contract; a fresh array is
    # built each call, so freezing it can't surprise a caller.
    def stage_names = map(&:name).freeze
    def stage_dirs = map(&:dir).freeze
    def draft_pr_handoff? = any? { |stage| stage.handoff == :draft_pr }

    # Canonical managed-runtime topology. Configuration snapshots, package
    # validation, and admission all consume these same stable actor slots.
    def executable_slots
      stages.flat_map do |stage|
        next [] unless [ :agent, :council ].include?(stage.kind)

        slots = [
          ExecutableSlot.new(
            id: "stages.#{stage.name}", kind: :stage, actor: stage,
            default_role: "development"
          )
        ]
        Array(stage.reviewers).each do |reviewer|
          slots << ExecutableSlot.new(
            id: "stages.#{stage.name}.reviewers.#{reviewer.name}",
            kind: :reviewer, actor: reviewer, default_role: "reviewer"
          )
        end
        if stage.council&.revise
          slots << ExecutableSlot.new(
            id: "stages.#{stage.name}.revise", kind: :revise,
            actor: stage.council.revise, default_role: "development"
          )
        end
        slots
      end
    end

    Stage = Data.define(
      :name, :index, :state_file, :advance_verb, :kind, :skill, :instruction,
      :permissions, :status_mode, :budget_usd, :timeout_sec, :capability,
      :agent, :model, :effort, :input, :reviewers, :council, :deliverable,
      :workspace, :handoff, :condition_policy, :mapping_role, :mapping_contract
    ) do
      def initialize(name:, index:, state_file:, advance_verb: nil, kind: nil,
                     skill: nil, instruction: nil, permissions: nil,
                     status_mode: nil, budget_usd: nil, timeout_sec: nil,
                     capability: nil, agent: nil, model: nil, effort: nil,
                     input: nil, reviewers: nil, council: nil, deliverable: nil,
                     workspace: nil, handoff: nil,
                     condition_policy: nil, mapping_role: nil, mapping_contract: nil)
        super
      end

      def dir = "#{index}-#{name}"
    end

    Council = Data.define(:quorum, :max_rounds, :exit_rule, :on_max_rounds, :triage_output, :revise) do
      def initialize(quorum:, max_rounds: 1, exit_rule: :human,
                     on_max_rounds: :wait, triage_output: DEFAULT_TRIAGE_OUTPUT, revise: nil)
        super
      end
    end

    Reviewer = Data.define(
      :name, :agent, :model, :effort, :skill, :instruction, :prompt,
      :command, :output_basename, :permissions, :max_attempts,
      :mapping_role, :mapping_contract
    ) do
      def initialize(name:, agent: nil, model: nil, effort: nil, skill: nil,
                     instruction: nil, prompt: nil, command: nil,
                     output_basename: nil, permissions: nil, max_attempts: nil,
                     mapping_role: nil, mapping_contract: nil)
        super
      end
    end

    Revise = Data.define(
      :agent, :model, :effort, :skill, :instruction, :prompt, :command,
      :permissions, :mapping_role, :mapping_contract
    ) do
      def initialize(agent: nil, model: nil, effort: nil, skill: nil,
                     instruction: nil, prompt: nil, command: nil, permissions: nil,
                     mapping_role: nil, mapping_contract: nil)
        super
      end
    end

    AdvanceVerb = Data.define(:name, :force_source, :interactive) do
      def initialize(name:, force_source: false, interactive: false) = super
    end

    private

    # Turn five runtime-stranding modes — empty list, gapped/unordered indices,
    # duplicate names or dirs, an unknown kind, and a leading advance_verb — into
    # one load-time error at the descriptor that introduced the typo. Coding and
    # every test fixture satisfy it with no behavior change.
    def validate_structure!
      structural_stages = stages.map do |stage|
        {
          name: stage.name,
          index: stage.index,
          dir: stage.dir,
          kind: stage.kind,
          advance_verb: stage.advance_verb
        }
      end
      Hive::WorkLedger.validate_descriptor(
        identity: id,
        stages: structural_stages,
        allowed_kinds: KNOWN_KINDS
      )
    rescue Hive::WorkLedger::InvalidDescriptor => e
      raise ArgumentError, "workflow #{id.inspect} #{e.message}"
    end
  end
end
