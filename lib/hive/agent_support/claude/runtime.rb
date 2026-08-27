require "hive/permission_scope"

module Hive::AgentSupport::Claude::Runtime
  module_function

  def resolve_scope(permission_spec, task_root:, profile:)
    [
      Hive::PermissionScope.resolve(
        permission_spec, task_folder: task_root, profile:, stage: "managed-workflow"
      ),
      nil
    ]
  end

  def compile_direct_actor(host:, scope:, task_root:, directories:, environment:, **)
    host.direct_policy(scope, task_root:, directories:, environment:)
  end

  def legacy_policy? = true
end
