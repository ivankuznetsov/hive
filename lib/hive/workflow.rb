module Hive
  Workflow = Data.define(:id, :stages) do
    def initialize(id:, stages:)
      # Shallow dup+freeze: the element Stage objects stay shared with the
      # caller, safe only because Stage is itself frozen. Don't add a mutable
      # field to Stage on the assumption this dup deep-copies — it does not.
      super(id: id, stages: stages.dup.freeze)
      validate_structure!
    end
  end

  # Reopened (not redefined): nested Stage/AdvanceVerb constants must live in a
  # class body so they resolve as Workflow::Stage — they can't be declared inside
  # the Data.define block above.
  class Workflow
    # Behaviorally significant stage kinds: `:agent` selects the agent runner,
    # `:inert` auto-advances with no runner, `:marker` is a coding marker-gated
    # stage, and `nil` is the unspecified default. A typo'd kind
    # (`Stage.new(kind: :agnet)`) would otherwise construct cleanly and only
    # strand the task at run time (Resolver raises StageError); the
    # construction-time check below turns it into a load-time error.
    KNOWN_KINDS = [ nil, :agent, :inert, :marker ].freeze

    # Structural invariants every "ordered, unique pipeline" consumer
    # (next_stage_after, the VERBS derivation, validate_workflow_stage!)
    # silently assumes but never enforces on its own. Checking them once at
    # construction converts five runtime-stranding modes — empty stage list,
    # gapped/unordered indices, duplicate names or dirs, an unknown kind, and a
    # first stage that carries an advance_verb — into a single load-time
    # ArgumentError at the descriptor that introduced the typo, instead of a
    # mis-route far from the cause. Valid descriptors (coding + every test
    # fixture) satisfy it with no behavior change.
    def validate_structure!
      raise ArgumentError, "workflow #{id.inspect} must declare at least one stage" if stages.empty?

      indices = stages.map(&:index)
      expected = (1..stages.length).to_a
      unless indices == expected
        raise ArgumentError,
              "workflow #{id.inspect} stage indices must be #{expected.inspect} in order, got #{indices.inspect}"
      end

      names = stages.map(&:name)
      unless names.uniq.length == names.length
        raise ArgumentError, "workflow #{id.inspect} has duplicate stage names: #{names.inspect}"
      end

      dirs = stages.map(&:dir)
      unless dirs.uniq.length == dirs.length
        raise ArgumentError, "workflow #{id.inspect} has duplicate stage dirs: #{dirs.inspect}"
      end

      stages.each do |stage|
        next if KNOWN_KINDS.include?(stage.kind)

        raise ArgumentError,
              "workflow #{id.inspect} stage #{stage.name.inspect} has unknown kind #{stage.kind.inspect} " \
              "(known: #{KNOWN_KINDS.map(&:inspect).join(', ')})"
      end

      return if stages.first.advance_verb.nil?

      raise ArgumentError,
            "workflow #{id.inspect} first stage #{stages.first.name.inspect} must not declare an advance_verb " \
            "(no stage precedes it to advance from)"
    end
    private :validate_structure!

    # Soft lookup: returns the Stage or nil so callers can decide how to handle
    # an unknown name (Task#validate_workflow_stage! raises its own message).
    def stage_named(name)
      stages.find { |stage| stage.name == name }
    end

    # Descriptor-scoped sequence lookup. Verb/sequence resolution is
    # data-driven from the workflow descriptor; the coding-only TaskAction
    # action map remains a separate bespoke gate.
    #
    # Soft lookup: returns nil for BOTH the terminal stage (no successor) and an
    # unknown name. Callers can't distinguish the two from the return value — a
    # typo'd `name` collapses into the same "no next stage" signal as the real
    # final stage. The terminal-nil is handled differently per caller:
    # Approve#resolve_destination raises FinalStageReached, while Run#next_stage_dir
    # and New#call fall back to a `hive run` hint, and Approve#json_next_action
    # emits a NO_OP/final_stage signal. All four callers (approve.rb
    # resolve_destination + json_next_action, run.rb next_stage_dir, new.rb call)
    # pass a `Task#validate_workflow_stage!`-validated `task.stage_name` or the
    # descriptor's own `entry_stage.name`, so the unknown-name arm is unreachable
    # on every live path today — it can only surface if a future caller feeds an
    # unvalidated name.
    def next_stage_after(name)
      index = stages.index { |stage| stage.name == name }
      index && stages[index + 1]
    end

    # Returns the verb that ARRIVES AT this stage (the descriptor's inbound
    # advance verb), not the verb that advances OUT of it — the bare name reads
    # the opposite way.
    # Soft lookup: nil means EITHER the stage advances by bare mv (no incoming
    # verb in the descriptor) OR the name is unknown — both fold into one nil.
    def advance_verb_for(name)
      stage_named(name)&.advance_verb&.name
    end

    # Soft lookup: returns nil if no stage has this dir.
    def stage_for_dir(dir)
      stages.find { |stage| stage.dir == dir }
    end

    # Accepts a full dir (`3-plan`) or a short name (`plan`) and returns the
    # canonical `Stage#dir` (or nil if neither matches). Deriving the return from
    # the matched Stage on both arms keeps the provenance workflow-canonical —
    # callers (File.rename targets, commit messages) get the descriptor's dir,
    # not the caller's raw string.
    def resolve_stage_ref(ref)
      (stage_for_dir(ref) || stage_named(ref))&.dir
    end

    def has_stage?(ref)
      !resolve_stage_ref(ref).nil?
    end

    # Hard resolve: raises KeyError on an unknown name — used where a missing
    # stage is a programmer error, not a recoverable condition.
    def state_file_for(name)
      stage = stage_named(name)
      return stage.state_file if stage

      raise KeyError, "unknown stage #{name.inspect} for workflow #{id.inspect}"
    end

    def stage_names
      # Frozen to match the parallel frozen Task::STAGE_NAMES constant — a
      # uniform immutability contract across both sources of truth. A fresh
      # array is built each call, so freezing it is safe (callers don't mutate).
      stages.map(&:name).freeze
    end

    def stage_dirs
      # Frozen for the same reason as stage_names: a uniform immutability
      # contract across descriptor-derived lists. A fresh array is built each
      # call, so freezing it is safe (callers don't mutate).
      stages.map(&:dir).freeze
    end

    Stage = Data.define(
      :name,
      :index,
      :state_file,
      :advance_verb,
      :kind,
      :skill,
      :instruction,
      :permissions,
      :status_mode,
      :budget_usd,
      :timeout_sec,
      :capability
    ) do
      def initialize(
        name:,
        index:,
        state_file:,
        advance_verb: nil,
        kind: nil,
        skill: nil,
        instruction: nil,
        permissions: nil,
        status_mode: nil,
        budget_usd: nil,
        timeout_sec: nil,
        capability: nil
      )
        super
      end

      def dir
        "#{index}-#{name}"
      end
    end

    AdvanceVerb = Data.define(:name, :force_source, :interactive) do
      def initialize(name:, force_source: false, interactive: false)
        super
      end
    end
  end
end
