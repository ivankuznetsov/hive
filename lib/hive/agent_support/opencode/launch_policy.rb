require "hive/permission_scope"

module Hive::AgentSupport::OpenCode::LaunchPolicy
  module_function

  def prepare_scope(values:, stage_name:, yolo:, host_outputs: false, **)
    if yolo
      raise Hive::ConfigError,
            "stage #{stage_name} must select read-only or scoped permissions for OpenCode"
    end

    directories = Array(values[:add_dirs])
    allowed_tools = values[:allowed_tools]
    edit_patterns = qualified_patterns(allowed_tools, "Edit")
    bash_patterns = qualified_patterns(allowed_tools, "Bash")
    granted = Array(allowed_tools).flat_map do |rule|
      Hive::PermissionScope.granted_tool_names(rule)
    end
    if granted.include?("Bash") && bash_patterns.empty?
      raise Hive::ConfigError,
            "stage #{stage_name} OpenCode permissions cannot grant unrestricted Bash"
    end
    write_roots = writable_roots(granted, edit_patterns, directories, host_outputs:)
    values.merge(
      permission_mode: write_roots.empty? ? "read-only" : "workspace-write",
      allowed_tools: nil, disallowed_tools: nil,
      additional_read_roots: directories,
      additional_write_roots: write_roots,
      edit_patterns: edit_patterns,
      bash_patterns: bash_patterns
    )
  end

  def custody_scope(prompt:, task_root:, actor:, cwd:, add_dirs:, output_path:, **)
    task_root = File.expand_path(task_root)
    worktree = File.expand_path(cwd)
    output = File.expand_path(output_path)
    write_roots = [ task_root ]
    edit_patterns = [ output ]
    bash_patterns = []
    if actor == "patrol_fix"
      write_roots.unshift(worktree)
      edit_patterns.unshift(File.join(worktree, "**"))
      bash_patterns << "*"
    end
    [
      prompt,
      {
        add_dirs: Array(add_dirs), permission_mode: "workspace-write",
        allowed_tools: nil, disallowed_tools: nil,
        additional_read_roots: Array(add_dirs), additional_write_roots: write_roots,
        edit_patterns: edit_patterns, bash_patterns: bash_patterns
      }
    ]
  end

  def restrict_task_state_scope(scope:, task:)
    task_root = File.expand_path(task.folder)
    without_task_root = lambda do |roots|
      Array(roots).reject { |root| File.expand_path(root) == task_root }
    end
    scope.merge(
      add_dirs: without_task_root.call(scope[:add_dirs]),
      additional_read_roots: without_task_root.call(scope[:additional_read_roots]),
      additional_write_roots: without_task_root.call(scope[:additional_write_roots])
    )
  end

  def writable_roots(granted, edit_patterns, directories, host_outputs:)
    return [] if host_outputs || (granted & Hive::PermissionScope::FILE_EDIT_TOOLS).empty?

    qualified = edit_patterns.map { |pattern| pattern.delete_suffix("/**") }
    return directories if qualified.empty?

    directories.select do |directory|
      expanded = File.expand_path(directory)
      qualified.any? do |root|
        expanded == root || expanded.start_with?(root + File::SEPARATOR) ||
          root.start_with?(expanded + File::SEPARATOR)
      end
    end
  end

  def qualified_patterns(allowed_tools, tool)
    Array(allowed_tools).filter_map do |rule|
      match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s)
      next unless match && match[:tool] == tool && match[:specifier]

      match[:specifier].sub(%r{\A//}, "/")
    end.uniq
  end

  private_class_method :writable_roots, :qualified_patterns
end
