# The web equivalent of `hive init`'s TTY questionnaire. Backs the
# /repos/new form AND plugs into Hive::Commands::Init's `prompts:` seam —
# `collect` returns the exact answers hash Prompts#collect produces, so a
# project set up from the browser is indistinguishable from one set up
# interactively. Every enumerated value is validated against the same
# choice constants the TTY uses (claude_model is deliberately free text); an out-of-range value raises Hive::Error (the
# operator-readable 422 page), never silently falls back.
class InitSetup
  Prompts = Hive::Commands::Init::Prompts

  TRIAGE_CHOICES = %w[courageous safetyist].freeze
  EFFORT_CHOICES = Prompts::CLAUDE_EFFORT_CHOICES
  BOOLEAN_KEYS = %w[adhoc_auto_fix daemon_enabled babysitter_enabled daemon_autostart].freeze

  class << self
    # registered_names yields symbols; everything downstream (form values,
    # the answers hash Init consumes) speaks strings.
    def agents = Hive::AgentProfiles.registered_names.map(&:to_s)
    def claude_modes = Prompts::CLAUDE_MODE_CHOICES
    def claude_permission_modes = Prompts::CLAUDE_PERMISSION_MODE_CHOICES
    def reviewer_names = Prompts::DEFAULT_REVIEWER_NAMES
    def patrol_reviewer_names = Prompts::PATROL_REVIEWER_NAMES
    def patrol_modes = Prompts::PATROL_MODE_CHOICES
    def limit_keys = Prompts::LIMIT_KEYS
    def workflows(project_root = nil)
      # The nil arm deliberately reads the frozen Registry::WORKFLOWS constant
      # (built-ins only) rather than Registry.ids: it needs no lock and is immune
      # to a process-wide project overlay, so a fresh /repos/new can't leak
      # another project's authored workflows (plan U3/Risk-1). The project arm
      # holds the overlay stable under Project.synchronize while it resolves
      # valid_names.
      return Hive::Workflows::Registry::WORKFLOWS.keys.map(&:to_s) unless project_root

      Hive::Workflows::Project.synchronize do
        Hive::WorkflowSelection.valid_names(project_root: project_root)
      end
    end

    def defaults
      {
        "planning_agent" => Prompts::DEFAULT_PLANNING_AGENT,
        "claude_mode" => Prompts::DEFAULT_CLAUDE_MODE,
        "claude_permission_mode" => Prompts::DEFAULT_CLAUDE_PERMISSION_MODE,
        "claude_model" => Prompts::DEFAULT_CLAUDE_MODEL,
        "claude_effort" => Prompts::DEFAULT_CLAUDE_EFFORT,
        "development_agent" => Prompts::DEFAULT_DEVELOPMENT_AGENT,
        "enabled_reviewers" => Prompts::DEFAULT_REVIEWER_NAMES.dup,
        "patrol_reviewers" => Prompts::DEFAULT_PATROL_REVIEWER_NAMES.dup,
        "patrol_mode" => Prompts::DEFAULT_PATROL_MODE,
        "triage_bias" => Prompts::DEFAULT_TRIAGE_BIAS,
        "adhoc_auto_fix" => Prompts::DEFAULT_ADHOC_AUTO_FIX,
        "budgets" => limit_keys.index_with { |k| Hive::Config::DEFAULTS["budget_usd"].fetch(k) },
        "timeouts" => limit_keys.index_with { |k| Hive::Config::DEFAULTS["timeout_sec"].fetch(k) },
        "daemon_enabled" => true,
        "babysitter_enabled" => true,
        "daemon_autostart" => false
      }
    end
  end

  # `params` is the settings subtree of the form post (string keys). Any
  # missing field takes the default — so a bare POST (API callers, the
  # GitHub one-click path) behaves exactly like the headless CLI.
  def initialize(params)
    # The whole settings subtree is validated field-by-field below, so
    # strong-parameter filtering adds nothing here — permit! unlocks to_h.
    params = params.permit! if params.respond_to?(:permit!)
    p = (params || {}).to_h.stringify_keys
    d = self.class.defaults
    @answers = {
      "planning_agent" => choose(p, "planning_agent", self.class.agents, d),
      "claude_mode" => choose(p, "claude_mode", self.class.claude_modes, d),
      "claude_permission_mode" => choose(p, "claude_permission_mode", self.class.claude_permission_modes, d),
      "claude_model" => free_text(p, "claude_model", d),
      "claude_effort" => choose(p, "claude_effort", EFFORT_CHOICES, d),
      "development_agent" => choose(p, "development_agent", self.class.agents, d),
      "enabled_reviewers" => choose_many(p, "enabled_reviewers", self.class.reviewer_names, d),
      "patrol_reviewers" => choose_many(p, "patrol_reviewers", self.class.patrol_reviewer_names, d),
      "patrol_mode" => choose(p, "patrol_mode", self.class.patrol_modes, d),
      "triage_bias" => choose(p, "triage_bias", TRIAGE_CHOICES, d),
      "budgets" => limits(p, "budgets", d),
      "timeouts" => limits(p, "timeouts", d),
      **BOOLEAN_KEYS.index_with { |k| boolean(p, k, d) }
    }.freeze
  end

  # The Init `prompts:` contract.
  def collect = @answers

  def [](key) = @answers[key]

  private

  # claude.model is free-form (Claude Code's alias vocabulary changes —
  # "default" tracks its recommended model, "inherit" follows the
  # operator's interactive pick, aliases pass through).
  def free_text(params, key, defaults)
    value = params[key].to_s.strip.presence || defaults.fetch(key)
    # The value eventually becomes argv (--model <value>); a leading dash
    # would smuggle an extra flag into the claude command line.
    raise Hive::Error, "#{key} must not start with '-' (got #{value.inspect})" if value.start_with?("-")

    value
  end

  def choose(params, key, allowed, defaults)
    value = params[key].presence || defaults.fetch(key)
    return value if allowed.include?(value)

    raise Hive::Error, "#{key} must be one of: #{allowed.join(", ")} (got #{value.inspect})"
  end

  # An EMPTY submitted list is a deliberate "none" (unchecked boxes post
  # nothing, so the form carries a presence marker); an absent key means
  # "not asked" and takes the default.
  def choose_many(params, key, allowed, defaults)
    return defaults.fetch(key) unless params.key?(key) || params.key?("#{key}_submitted")

    values = Array(params[key]).map(&:to_s).reject(&:empty?)
    bad = values - allowed
    raise Hive::Error, "#{key} contains unknown entries: #{bad.join(", ")}" if bad.any?

    values
  end

  def limits(params, key, defaults)
    submitted = params[key]
    return defaults.fetch(key) unless submitted.is_a?(Hash) || submitted.is_a?(ActionController::Parameters)

    submitted = submitted.to_h.stringify_keys
    self.class.limit_keys.index_with do |k|
      raw = submitted[k].presence || defaults.fetch(key).fetch(k)
      value = Integer(raw, exception: false)
      raise Hive::Error, "#{key}.#{k} must be a non-negative integer (got #{raw.inspect})" if value.nil? || value.negative?

      value
    end
  end

  def boolean(params, key, defaults)
    return defaults.fetch(key) unless params.key?(key)

    [ "1", "true", "on" ].include?(params[key].to_s)
  end
end
