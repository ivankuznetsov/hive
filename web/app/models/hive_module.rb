class HiveModule
  attr_reader :project, :attributes

  class << self
    attr_writer :lifecycle

    def for(project, include_history: false)
      lifecycle.list(project, include_history:).map { |attributes| new(project:, attributes:) }
    end

    def lifecycle
      @lifecycle ||= Hive::Web::ModuleLifecycle.new
    end

    def reset_lifecycle!
      remove_instance_variable(:@lifecycle) if instance_variable_defined?(:@lifecycle)
    end
  end

  def initialize(project:, attributes:)
    @project = project
    @attributes = attributes
  end

  delegate :[], :dig, :fetch, to: :attributes

  def name = fetch("name")
  def lifecycle_state = fetch("lifecycle_state")
  def installed? = fetch("installed") == true
  def enabled? = fetch("enabled") == true
  def active = self["active"]
  def previous = self["previous"]
  def version = (active || previous)&.fetch("version", nil)
  def source_commit = (active || previous)&.fetch("source_commit", nil)
  def hooks = fetch("hooks")
  def settings = fetch("settings")
  def grants = self["grants"] || {}
  def latest_decision = self["latest_decision"]
end
