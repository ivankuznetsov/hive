require "fileutils"
require "find"
require "json"

module Hive::AgentSupport::Muse::PluginStaging
  CLONE_TIMEOUT_SEC = 300

  module_function

  # Muse refuses to install any plugin bundle that contains a symlink
  # (`plugin contains symlink entries and cannot be installed`), and the
  # upstream Compound Engineering repository ships several (`.agy/skills`,
  # `.claude/skills`, site assets). Hive therefore stages each muse plugin
  # package under its own subtree of the Muse data home: clone the
  # manifest-declared git source, copy it dereferencing every symlink, and
  # hand the resulting plain tree to `muse plugins install`. The staged
  # tree stays the plugin's recorded source, so `muse plugins update`
  # refreshes from it after Hive re-stages.

  def root(package_id:, environment:)
    File.join(
      Hive::AgentSupport::Muse.data_directory(environment: environment),
      "hive", package_id
    )
  end

  def clone_dir(root) = File.join(root, "clone")
  def package_dir(root) = File.join(root, "package")

  # Returns the staged plugin version. Raises Hive::Error with an
  # operator-readable message on any failure; a failed stage leaves the
  # installed plugin untouched because Muse runs from its own cache copy.
  def stage(source:, root:, runner:, env:)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)
    clone = clone_dir(root)
    result = runner.call(
      [ "git", "clone", "--depth", "1", "--", source, clone ],
      env: env, timeout: CLONE_TIMEOUT_SEC
    )
    unless result.success?
      detail = result.stderr.to_s.lines.first.to_s.strip
      detail = "exit #{result.exit_status}" if detail.empty?
      detail = "timed out" if result.timed_out
      raise Hive::Error, "git clone #{source} failed: #{detail}"
    end

    package = package_dir(root)
    copy_tree(clone, package)
    manifest = File.join(package, ".claude-plugin", "plugin.json")
    unless File.file?(manifest)
      raise Hive::Error, "staged plugin has no .claude-plugin/plugin.json"
    end
    if Find.find(package).any? { |path| File.symlink?(path) }
      raise Hive::Error, "staged plugin still contains symlinks"
    end

    version = JSON.parse(File.binread(manifest))["version"].to_s
    raise Hive::Error, "staged plugin manifest has no version" if version.empty?

    version
  rescue JSON::ParserError, SystemCallError => e
    raise Hive::Error, "could not stage muse plugin: #{e.message}"
  end

  def copy_tree(source, destination, ancestry = [])
    real = File.realpath(source)
    if ancestry.include?(real)
      raise Hive::Error, "symlink cycle in plugin source at #{source}"
    end

    FileUtils.mkdir_p(destination)
    Dir.children(source).sort.each do |name|
      next if name == ".git" && ancestry.empty?

      from = File.join(source, name)
      to = File.join(destination, name)
      if File.symlink?(from)
        target = File.realpath(from)
        if File.directory?(target)
          copy_tree(target, to, ancestry + [ real ])
        else
          copy_file(target, to)
        end
      elsif File.directory?(from)
        copy_tree(from, to, ancestry + [ real ])
      else
        copy_file(from, to)
      end
    end
  end

  def copy_file(from, to)
    FileUtils.cp(from, to)
    FileUtils.chmod(File.stat(from).mode & 0o777, to)
  end

  private_class_method :copy_tree, :copy_file
end
