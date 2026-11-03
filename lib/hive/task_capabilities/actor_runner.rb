require "securerandom"
require "thread"
require "hive/task_capabilities/admission"
require "hive/task_capabilities/approval"
require "hive/process_kill"
require "tmpdir"
require "hive/provider_routing/configuration"
require "hive/workflow_package/configuration"
require "hive/artifacts/project_command_sandbox"

module Hive
  module TaskCapabilities
    # Sub-spawns share their parent's attempt, lease and usage ledger. A session
    # reserves from a caller's existing finite stage envelope, never a new one.
    class ActorRunner
      Invocation = Data.define(:admitted_route, :parent_attempt_id, :spawn_id) do
        def explicit_routing? = true
        def adapter = admitted_route.fetch("adapter")
        def launch_binding_id = admitted_route.fetch("launch_binding_id")
        def provider_account_id = admitted_route.fetch("provider_account_id")
        def model = admitted_route.fetch("model")
        def effort = admitted_route.fetch("effort")
        def billing_route = admitted_route.fetch("billing_route")
        def billing_evidence_source = admitted_route.fetch("billing_evidence_source")
      end

      def initialize(task:, cfg:, session:, context: Hive::Attempts::Context.current,
                     launcher: nil, store: nil)
        raise Admission::Error, "the capability specialist requires a durable parent attempt; run this task with --durable" unless context
        @task, @cfg, @session, @context = task, cfg, session, context
        @store = store || Hive::Attempts::Repository.open_default
        @launcher = launcher || Hive::Stages::Base.method(:spawn_agent)
      rescue Hive::Attempts::RepositoryError => error
        raise Admission::Error, "capability specialist requires an available durable parent attempt: #{error.message}"
      end

      def run(binding, prompt:)
        actor = binding.fetch("actor")
        Definition.positive(binding.fetch("budget_usd"), label: "capability actor budget_usd")
        Definition.positive(binding.fetch("timeout_sec"), label: "capability actor timeout_sec", integer: true)
        profile = Hive::AgentProfiles.lookup(actor.fetch("profile"), cfg: @cfg)
        unless profile.budget_flag
          raise Admission::Error, "capability actor #{profile.name} cannot enforce a per-spawn budget"
        end
        fingerprint = Hive::WorkflowPackage::Configuration.profile_fingerprint(profile)
        unless binding.fetch("actor_fingerprint") == fingerprint
          raise Admission::Error, "selected #{binding.fetch('id')} runtime identity changed; restore the pinned runtime or revise the execution plan"
        end
        verify_accepted_binding!(binding)
        route = Hive::ProviderRouting::Configuration.capability_route(cfg: @cfg, actor: actor)
        unless binding.fetch("actor_route") == route
          raise Admission::Error, "selected #{binding.fetch('id')} approved route changed; restore its exact provider account and launch binding"
        end
        Admission.verify_skill_binding!(binding, project_root: @task.project_root, cfg: @cfg) if binding["skill"]
        policy = compile_policy(binding, profile)
        spawn = @session.reserve!(budget_usd: binding.fetch("budget_usd"), timeout_sec: binding.fetch("timeout_sec"), launcher_owned: true)
        accounts = @cfg.fetch(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY, {})
        accounts = Hive::ProviderRouting::Configuration.normalize_accounts(accounts, source: "global providers") unless accounts.values.all? { |entry| entry.is_a?(Hive::ProviderRouting::Account) }
        result = @store.with_capability_spawn(attempt_id: @context.attempt_id, spawn_id: spawn.id, route: route, accounts: accounts,
          task_id: @task.id, task_slug: @task.slug, stage: binding.fetch("stage")) do
          @launcher.call(@task, prompt: prompt, profile: profile, cfg: @cfg,
            max_budget_usd: spawn.budget_usd, timeout_sec: spawn.timeout_sec,
            spawn_control: spawn, terminate_on_parent_signal: false,
            capability_invocation: Invocation.new(admitted_route: route, parent_attempt_id: @context.attempt_id, spawn_id: spawn.id),
            runtime_policy: policy, cleanup_runtime_policy: false, cwd: policy.task_root,
            status_mode: :exit_code_only, log_label: "capability-#{binding.fetch('id')}-#{spawn.id}")
        ensure
          # Release route occupancy only after every owned process is gone.
          spawn.finish!
          spawn.close
        end
        if spawn.stop_reason
          result = result.merge(status: :error, error_reason: spawn.stop_reason)
        elsif result[:status] == :ok && (result[:actual_provider] != actor.fetch("provider") || result[:actual_model] != actor.fetch("model"))
          result = result.merge(status: :error, error_reason: "capability_actor_identity_unverified")
        end
        @session.settle!(spawn, result)
        result.merge(capability_spawn_id: spawn.id, parent_attempt_id: @context.attempt_id,
          capability_stop_reason: spawn.stop_reason)
      rescue Hive::ConfigError, Hive::Attempts::RepositoryError, Hive::Artifacts::ProjectCommandSandbox::SandboxError, SystemCallError => error
        recovery = binding["id"] == "security" ? "restore the approved route or archive/cancel the task without finalization" : "restore the pinned route or accept a revised execution plan"
        raise Admission::Error.new("approved capability route or scope unavailable: #{error.message}; #{recovery}", reason: "task_capability_route_unavailable")
      ensure
        spawn&.finish!
        spawn&.close
        @session.settle!(spawn, result || {}) if spawn
        policy&.cleanup!
      end

      private

      def verify_accepted_binding!(binding)
        store = Store.new(@task.folder)
        plan = store.current
        accepted_bindings = plan&.data&.fetch("bindings") || []
        nested_bindings = accepted_bindings.flat_map { |entry| entry.fetch("checks", []).filter_map { |check| check.dig("runner", "actor_binding") } }
        unless (accepted_bindings + nested_bindings).include?(binding)
          raise Admission::Error, "capability invocation does not match the current accepted execution-plan binding"
        end
        return unless binding["id"] == "security" || binding["approval_reference"]
        approvals = plan.data.fetch("approvals").map { |reference| store.read_blob("approval", reference.fetch("digest")) }
        approved = approvals.find { |approval| approval["reference"] == binding["approval_reference"] }
        requested = binding.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => binding.fetch("id"))
        unless approved && Approval.new(reference: approved.fetch("reference"), envelope: approved.fetch("envelope")).covers?(requested)
          raise Admission::Error.new("capability actor is outside its exact accepted operator approval", reason: "task_capability_approval_scope")
        end
      end

      def compile_policy(binding, profile)
        targets = Definition.targets(binding.fetch("targets"), label: "capability")
        raise Admission::Error, "capability runtime supports one exact local target" if targets.size > 1
        task_root = File.realpath(@task.folder)
        root = targets.empty? ? task_root : File.realpath(File.join(task_root, targets.first))
        unless File.directory?(root) && (root == task_root || root.start_with?(task_root + File::SEPARATOR))
          raise Admission::Error, "capability target is outside task-owned local scope"
        end
        permissions = binding.fetch("permissions")
        if permissions.is_a?(String) || (permissions.is_a?(Hash) && permissions.key?("preset"))
          permissions = Hive::PermissionScope.parse_spec(permissions, stage: "capability")
        end
        if %w[read-only yolo].include?(permissions["preset"])
          permissions = { "tools" => Hive::PermissionScope::READ_ONLY_ALLOWED }
        end
        unless permissions.is_a?(Hash) && !permissions.key?("preset")
          raise Admission::Error, "capability specialist requires an enforceable exact bounded permissions map or read-only scope"
        end
        directory = Dir.mktmpdir("hive-capability-policy-")
        policy = Hive::WorkflowPackage::RuntimePolicy.compile(permissions, task_folder: root,
          profile: profile, policy_dir: directory, isolated_commands: true)
        policy.with(cleanup_paths: [ *policy.cleanup_paths, directory ].freeze)
      rescue StandardError
        FileUtils.remove_entry_secure(directory) if directory && File.directory?(directory)
        raise
      end

      class Session
        attr_reader :remaining_budget

        def initialize(budget_usd:, timeout_sec:, parent: nil)
          @remaining_budget = budget_usd
          @deadline = monotonic + timeout_sec if timeout_sec
          @mutex = Mutex.new
          @spawns = []
          @settled = {}
          @cancelled = false
          @closed = false
          @parent = parent
          parent&.register_capability_session(self)
        end

        def reserve!(budget_usd:, timeout_sec:, launcher_owned: false)
          @mutex.synchronize do
            raise Admission::Error, "parent capability session is cancelled or closed" if cancelled? || @closed
            budget = [ budget_usd, @remaining_budget ].compact.min
            timeout = [ timeout_sec, remaining_timeout ].compact.min
            unless budget&.positive? && timeout&.positive?
              raise Admission::Error, "parent capability resource envelope is exhausted"
            end
            @remaining_budget -= budget if @remaining_budget
            Spawn.new(budget_usd: budget, timeout_sec: timeout, cancelled: method(:cancelled?), launcher_owned: launcher_owned).tap { |spawn| @spawns << spawn }
          end
        end

        def remaining_timeout
          @deadline && @deadline - monotonic
        end

        def cancelled? = @cancelled || @parent&.capability_cancelled?

        def primary_limits(budget_usd:, timeout_sec:)
          @mutex.synchronize do
            budget = [ budget_usd, @remaining_budget ].compact.min
            timeout = [ timeout_sec, remaining_timeout ].compact.min
            if @primary_claimed || cancelled? || (budget && !budget.positive?) || !timeout&.positive?
              raise Admission::Error, "parent capability resource envelope is exhausted or cancelled"
            end
            @primary_claimed = true
            @remaining_budget -= budget if @remaining_budget
            [ budget, timeout ]
          end
        end

        def settle!(spawn, result)
          @mutex.synchronize do
            return if @settled[spawn.id]
            @settled[spawn.id] = true
            cost = result.dig(:usage, :cost) || result.dig(:usage, :provider_reported_cost)
            if @remaining_budget && !spawn.started? && result[:status] != :ok
              @remaining_budget += spawn.budget_usd
            elsif @remaining_budget && result[:status] == :ok && cost.is_a?(Numeric) && cost.finite? && cost >= 0
              @remaining_budget += spawn.budget_usd - cost
            end
          end
        end

        def cancel!
          @mutex.synchronize do
            @cancelled = true
            @spawns.each(&:cancel!)
          end
        end

        def close
          spawns = @mutex.synchronize { @closed = true; @spawns.dup }
          spawns.each(&:cancel!)
          spawns.each(&:close)
        end

        private

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Owns the native child's process group, including descendants which keep
      # running after the CLI exits. The launcher still owns normal wait/usage.
      class Spawn
        GRACE_SEC = 0.2
        attr_reader :budget_usd, :timeout_sec, :stop_reason, :id, :observed_cost

        def initialize(budget_usd:, timeout_sec:, cancelled:, launcher_owned:)
          @id = SecureRandom.uuid
          @budget_usd, @timeout_sec = budget_usd, timeout_sec
          @deadline = monotonic + timeout_sec
          @mutex = Mutex.new
          @closed = false
          @cancelled = cancelled
          @finished = !launcher_owned
          @completion = ConditionVariable.new
          @targets = []
        end

        def attach(pid)
          @pid = pid
          @start = Hive::Lock.process_start_time(pid)
          raise Admission::Error, "capability actor process identity is unavailable" unless @start
          @watcher = Thread.new do
            loop do
              break if @closed
              cancel! if @cancelled.call
              stop!("timeout") if monotonic >= @deadline
              terminate if @stop_reason
              break if @stop_reason
              capture_targets
              sleep 0.02
            end
          end
        end

        def started? = !@pid.nil?

        def launch_timeout!
          cancel! if @cancelled.call
          remaining = @deadline - monotonic
          stop!("timeout") unless remaining.positive?
          raise Admission::Error, "capability spawn cannot launch after #{@stop_reason}" if @stop_reason
          remaining
        end

        def observe_cost!(cost)
          return unless cost.is_a?(Numeric) && cost.finite? && cost >= 0
          @observed_cost = [ @observed_cost, cost ].compact.max
          stop!("budget_exhausted") if @observed_cost >= @budget_usd
        end

        def cancel!
          stop!("parent_cancelled") unless @closed
        end

        def finish!
          @mutex.synchronize { @finished = true; @completion.broadcast }
        end

        def close
          @mutex.synchronize do
            return if @closed
            @stop_reason ||= "parent_cancelled" unless @finished
            @completion.wait(@mutex) until @finished
            @closed = true
          end
          @watcher&.join
          if @pid && !@start
            # Failed attachment has not handed the child to the launcher's
            # waiter. waitpid proves it is still our unreaped child, which
            # keeps its PID/group from being reused during this fail-close.
            begin
              unless Process.waitpid(@pid, Process::WNOHANG)
                Process.kill("KILL", -@pid)
                Process.waitpid(@pid)
              end
            rescue Errno::ECHILD, Errno::ESRCH
              nil
            end
            return
          end
          terminate if @pid
          begin
            Process.waitpid(@pid) if @pid
          rescue Errno::ECHILD
            nil
          end
        end

        private

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def stop!(reason)
          @mutex.synchronize { @stop_reason ||= reason }
        end

        def terminate
          capture_targets
          Hive::ProcessKill.signal_captured_processes("TERM", @targets, require_identity: true)
          sleep GRACE_SEC
          Hive::ProcessKill.signal_captured_processes("KILL", @targets, require_identity: true)
        end

        def capture_targets
          return unless @pid && Hive::Lock.process_start_time(@pid) == @start
          observed = Hive::ProcessKill.process_tree_snapshot(@pid)
          return unless observed
          confirmed = Hive::ProcessKill.confirm_process_tree_snapshot(@pid, observed)
          @targets = (@targets + Array(confirmed)).uniq { |target| [ target.fetch(:pid), target[:start_time] ] }
        end
      end
    end
  end
end
