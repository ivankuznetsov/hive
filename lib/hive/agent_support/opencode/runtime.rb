module Hive::AgentSupport::OpenCode::Runtime
  module_function

  def compile_managed_actor(host:, scope:, task_root:, directories:, environment:,
                            outputs:, prepare:, **)
    unless prepare
      return host.portable_admission_policy(
        scope, task_root:, directories:, environment:
      )
    end
    host.portable_policy(
      scope, task_root:, directories:, environment:, outputs:,
      runtime_root: nil, cli_flags: [], executable: nil
    )
  end
end
