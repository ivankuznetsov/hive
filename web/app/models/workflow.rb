class Workflow
  attr_reader :project, :attributes

  class << self
    attr_writer :lifecycle

    def for(project)
      lifecycle.list(project).map { |attributes| new(project:, attributes:) }
    end

    def templates
      lifecycle.templates
    end

    def scaffold!(project:, id:, template:)
      lifecycle.scaffold(project, id:, template:)
    end

    def lifecycle
      @lifecycle ||= Hive::Web::WorkflowLifecycle.new
    end

    def reset_lifecycle!
      remove_instance_variable(:@lifecycle) if instance_variable_defined?(:@lifecycle)
    end
  end

  def initialize(project:, attributes:)
    @project = project
    @attributes = attributes
  end

  def name = attributes.fetch("name")
  def origin = attributes.fetch("origin")
  def selection = attributes["selection"]
  def integrity = attributes["integrity"]
  def version = attributes["version"]
  def source_commit = attributes["source_commit"]
  def catalog_visibility = attributes["catalog_visibility"]
  def default? = attributes["default"] == true
  def managed? = origin == "managed"
  def selected? = selection == "selected"
  def verified? = integrity == "verified"
end
