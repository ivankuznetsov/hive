# Presentation only: which agent does which workflow role.
#
# With a project, roles come from that project's loaded config (what Hive
# will actually run). Without one, the fresh-project defaults `hive init`
# writes (Init::Prompts, rendered by templates/project_config.yml.erb) are
# shown and labelled as such. Config::DEFAULTS is deliberately not used for
# the fresh view: its execute agent is a legacy-compatibility fallback, not
# the init recommendation.
class AgentRoles
  Role = Data.define(:label, :agents)

  NAMES = {
    "claude" => "Claude Code", "codex" => "Codex", "grok" => "Grok",
    "pi" => "Pi", "opencode" => "OpenCode", "gh" => "GitHub CLI"
  }.freeze

  def self.display_name(agent) = NAMES.fetch(agent.to_s) { agent.to_s.humanize }

  def self.fresh_init
    prompts = InitSetup::Prompts
    reviewers = prompts::DEFAULT_REVIEWER_NAMES.map do |name|
      prompts::REVIEWER_CAPABILITIES.dig(name, "agent")
    end
    new(
      planning: [ prompts::DEFAULT_PLANNING_AGENT ] * 2,
      execute: prompts::DEFAULT_DEVELOPMENT_AGENT,
      reviewers: reviewers, source: :fresh_init
    )
  end

  def self.for_project(project)
    cfg = project.config
    # Only the kinds Hive::Reviewers.dispatch runs: "agent" (the default when
    # kind is absent) and "codex_review", whose adapter is always native
    # Codex. "linter" is rejected by the dispatcher, so it is no role.
    reviewers = Array(cfg.dig("review", "reviewers")).filter_map do |row|
      next unless row.is_a?(Hash)

      case (row["kind"] || "agent").to_s
      when "agent" then row["agent"]
      when "codex_review" then "codex"
      end
    end
    new(
      planning: [ cfg.dig("brainstorm", "agent"), cfg.dig("plan", "agent") ],
      execute: cfg.dig("execute", "agent"),
      reviewers: reviewers, source: :project, project_name: project.name,
      default_workflow: cfg["default_workflow"]
    )
  end

  attr_reader :source, :project_name, :default_workflow

  # These are the coding workflow's stage keys. A project whose default
  # workflow is another one (content: research/outline/draft/…) still stores
  # them, but its default tasks run that workflow's own stage agents.
  def coding_default? = default_workflow.nil? || default_workflow == "coding"

  def initialize(planning:, execute:, reviewers:, source:, project_name: nil, default_workflow: nil)
    @brainstorm, @plan = planning.map { |agent| agent.presence&.to_s }
    @execute = execute.presence&.to_s
    @reviewers = reviewers.compact.map(&:to_s).uniq
    @source = source
    @project_name = project_name
    @default_workflow = default_workflow.presence&.to_s
  end

  def roles
    planning = if @brainstorm == @plan
      [ Role.new("Brainstorm and plan", [ @brainstorm ].compact) ]
    else
      [ Role.new("Brainstorm", [ @brainstorm ].compact), Role.new("Plan", [ @plan ].compact) ]
    end
    (planning + [ Role.new("Implement", [ @execute ].compact), Role.new("Review", @reviewers) ])
      .reject { |role| role.agents.empty? }
  end

  # Agent name => role labels, for annotating login cards.
  def by_agent
    roles.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |role, memo|
      role.agents.each { |agent| memo[agent] << role.label }
    end
  end
end
