require "hive/agent_support/grok"

module Hive::AgentSupport::Grok::CliIdentity
  module_function

  def dynamic_launcher?(target)
    source = File.open(target, File::RDONLY | File::NOFOLLOW) { |file| file.read(4096) }
    source.start_with?("#!") && source.include?("grok-bootstrap.js")
  rescue SystemCallError
    true
  end

  def native_version_first? = true

  def native_version(target, version_pattern:)
    match = target.match(%r{/\.grok/bin/grok-([^/]+)\z})
    return unless match && version_pattern.match?(match[1])

    directory = File.dirname(target)
    metadata = File.join(File.dirname(directory), "config.toml")
    launcher = File.join(directory, "grok")
    return unless File.file?(metadata) && File.symlink?(launcher) && File.realpath(launcher) == target

    content = File.read(metadata, 128 * 1024)
    cli = content[/^\[cli\][ \t]*(?:#[^\n]*)?\n(.*?)(?=^\[|\z)/m, 1]
    if cli && cli.match?(/^installer[ \t]*=[ \t]*["']npm["'][ \t]*(?:#[^\n]*)?$/)
      [ match[1], "grok_native_install", nil ]
    end
  end
end
