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

    # :agent selects the agent runner, :inert auto-advances with no runner,
    # :execute/:review-council/:finalize select coding runtime primitives,
    # :marker is the legacy coding marker-gated stage kind, nil is the
    # unspecified default.
    KNOWN_KINDS = [ nil, :agent, :inert, :execute, :"review-council", :finalize, :marker ].freeze

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

    Stage = Data.define(
      :name, :index, :state_file, :advance_verb, :kind, :skill, :instruction,
      :permissions, :status_mode, :budget_usd, :timeout_sec, :capability
    ) do
      def initialize(name:, index:, state_file:, advance_verb: nil, kind: nil,
                     skill: nil, instruction: nil, permissions: nil,
                     status_mode: nil, budget_usd: nil, timeout_sec: nil,
                     capability: nil)
        super
      end

      def dir = "#{index}-#{name}"
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
      raise ArgumentError, "workflow #{id.inspect} must declare at least one stage" if stages.empty?

      expected = (1..stages.length).to_a
      actual = map(&:index)
      actual == expected or
        raise ArgumentError,
              "workflow #{id.inspect} stage indices must be #{expected.inspect} in order, got #{actual.inspect}"

      reject_duplicates!(map(&:name), "stage names")
      reject_duplicates!(map(&:dir), "stage dirs")

      each do |stage|
        KNOWN_KINDS.include?(stage.kind) or
          raise ArgumentError,
                "workflow #{id.inspect} stage #{stage.name.inspect} has unknown kind #{stage.kind.inspect} " \
                "(known: #{KNOWN_KINDS.map(&:inspect).join(', ')})"
      end

      stages.first.advance_verb.nil? or
        raise ArgumentError,
              "workflow #{id.inspect} first stage #{stages.first.name.inspect} must not declare an " \
              "advance_verb (no stage precedes it to advance from)"
    end

    def reject_duplicates!(values, label)
      return if values.uniq.length == values.length

      raise ArgumentError, "workflow #{id.inspect} has duplicate #{label}: #{values.inspect}"
    end
  end
end
