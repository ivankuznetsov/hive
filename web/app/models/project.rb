require "stringio"

class Project
  attr_reader :attributes

  def self.all
    Hive::Config.registered_projects.map { |attributes| new(attributes) }
  end

  def self.find!(name, projects: all)
    projects.find { |project| project.name == name } ||
      raise(Hive::InvalidTaskPath, "unknown project #{name}")
  end

  def initialize(attributes)
    @attributes = attributes
  end

  def name
    attributes.fetch("name")
  end

  def path
    attributes.fetch("path")
  end

  def hive_state_path
    attributes.fetch("hive_state_path")
  end

  def [](key)
    attributes[key]
  end

  def fetch(...)
    attributes.fetch(...)
  end

  def workflows
    InitSetup.workflows(path)
  end

  def config
    return @config if defined?(@config)
    raise @config_error if defined?(@config_error)

    @config = Hive::Config.load(path)
  rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
    @config_error = e
    raise
  end

  def active_tasks
    @active_tasks ||= attributes.fetch("tasks", []).map do |task_attributes|
      Task.new(project: self, attributes: task_attributes)
    end
  end

  def default_workflow
    config["default_workflow"].presence
  rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
    Rails.logger.warn("default_workflow unreadable for #{name}: #{e.class}: #{e.message}")
    nil
  end

  def daemon_enabled?
    config.dig("daemon", "enabled") != false
  rescue StandardError => e
    Rails.logger.warn("project config unreadable for #{name}: #{e.class}: #{e.message}")
    true
  end

  def setup!(prompts, workflow: nil)
    provisioning_error = StringIO.new
    Hive::Commands::Init.new(
      path,
      force: true,
      json: false,
      prompts:,
      workflow:,
      provisioning_input: StringIO.new,
      provisioning_error:
    ).call
    provisioning_error.string.strip.presence
  end
end
