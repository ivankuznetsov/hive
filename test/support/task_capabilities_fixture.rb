require "hive/task_capabilities/verification"
require "hive/task_capabilities/resolver"
require "hive/attempts/dispatcher"
require "hive/task_counter"

module TaskCapabilitiesFixture
  def with_verification(command: "ruby -e 'puts 42'", catalog: [], selections: [], configure: nil, **inputs)
    with_tmp_dir do |dir|
      prepare_test_runtime_project(dir)
      code = File.join(dir, "code")
      FileUtils.mkdir_p(code)
      system("git", "init", "-q", code, exception: true)
      File.write(File.join(code, "README.md"), "example\n")
      File.write(File.join(code, "expected.txt"), "example\n")
      system("git", "-C", code, "add", ".", exception: true)
      system("git", "-C", code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "initial", exception: true)
      folder = File.join(dir, ".hive-state/stages/6-review/verification-task")
      task_id = Hive::TaskCounter.next_or_nil
      Hive::TaskMeta.write(folder, id: task_id, slug: "verification-task", display_name: nil)
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["review"]["ci"]["command"] = command
      cfg["task_capabilities"]["catalog"] = catalog
      cfg["agents"] = { "claude" => { "bin" => File.expand_path("../fixtures/fake-claude", __dir__) } }
      configure&.call(cfg, dir)
      state_file = File.join(folder, "task.md")
      File.write(state_file, "Verification task\n")
      task = Struct.new(:folder, :project_root, :id, :slug, :workflow, :state_file, :stage_name, :stage_index, :worktree_path).new(
        folder, dir, task_id, "verification-task", Hive::Workflows::Coding::DESCRIPTOR, state_file, "review", 6, code)
      resolution = Hive::TaskCapabilities::Resolver.new(workflow: Hive::Workflows::Coding::DESCRIPTOR, cfg: cfg, project_root: dir).resolve(
        task_identity: Hive::TaskMeta.stable_identity(Hive::TaskMeta.read(folder)), selections: selections, **inputs)
      plan = resolution.plan
      Hive::TaskMeta.rewrite(folder, task_capabilities: plan.adoption)
      store = Hive::TaskCapabilities::Store.new(folder)
      store.activate(plan, expected_version: nil, approvals: resolution.approvals)
      attempts = Hive::Attempts::Repository.new(database: Hive::TaskCounter.database, root: File.join(dir, "attempt-payloads"))
      launcher = Object.new
      launcher.define_singleton_method(:preflight!) { true }
      launcher.define_singleton_method(:launch) { |*, **| { "claimed" => true } }
      dispatcher = Hive::Attempts::Dispatcher.new(store: attempts, launcher: launcher, capability_generator: -> { "c" * 64 })
      project = "test-#{Digest::SHA256.hexdigest(dir)[0, 16]}"
      dispatch = -> { dispatcher.dispatch(task: task, project: project, intended_stage: "6-review", argv: [ "hive", "run", task.slug ], request_id: "parent-#{task_id}", provider: "claude").attempt }
      # A running-parent fixture also exercises the reader's fail-closed
      # result for a plan whose normal dispatch admission is already blocked.
      parent = if plan.data.fetch("blockers").empty?
        dispatch.call
      else
        with_replaced_singleton_method(Hive::TaskCapabilities::Admission, :enforce!, ->(*) { true }, &dispatch)
      end
      owner = { "pid" => Process.pid, "start_fingerprint" => Hive::Lock.process_start_time(Process.pid), "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
      parent = attempts.claim(parent, owner: owner, claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
      parent = attempts.first_heartbeat(parent, stale_sec: 30, now: Time.now.utc)
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0, ownership_generation: parent.ownership_generation, intended_stage: "6-review")
      verification = Hive::TaskCapabilities::Verification.new(task: task, cfg: cfg, worktree_path: code, context: context)
      with_replaced_singleton_method(Hive::Attempts::Repository, :open_default, ->(**) { attempts }) do
        yield verification, plan, store, code, cfg, task, context, attempts
      end
    ensure
      context&.close
      if attempts && parent
        attempts.terminalize(attempts.fetch(parent.attempt_id), outcome: "succeeded", exit_status: 0,
          final_checkpoint: { "marker" => "review_complete" }, output_references: [],
          log_reference: { "path" => "open/fixture.frames", "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
      end
    end
  end

  def actor_definition(id: "audit", checks: nil)
    { "id" => id, "kind" => "verification", "stages" => [ "review" ],
      "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
      "permissions" => "read-only", "targets" => [ "capability-source" ], "budget_usd" => 1, "timeout_sec" => 5,
      "checks" => checks || [ { "id" => "source", "kind" => "source_review", "claim" => "Check example prose against its reference", "provider" => "independent-actor" } ] }
  end

  def proposed_outcome(task, identity, target: "capability-source")
    { "kind" => "document", "summary" => "Observed source agrees with expected reference", "claims" => [ identity.fetch("check_id") ],
      "source" => { "type" => "task", "name" => "independent-check", "source_sha" => identity.fetch("evaluated_sha") },
      "representations" => [ [ "original", "README.md" ], [ "review", "expected.txt" ] ].map do |role, file|
        path = "#{target}/#{file}"
        { "role" => role, "media_type" => "text/plain", "path" => path,
          "bytes" => File.size(File.join(task.folder, path)), "sha256" => Digest::SHA256.file(File.join(task.folder, path)).hexdigest }
      end }
  end

  def with_actor_response(response = nil)
    proof_builder = method(:proposed_outcome)
    with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |task, **args|
      identity = JSON.parse(args.fetch(:prompt).split("Identity: ", 2).last.split(". Planned check:", 2).first)
      proposal = identity.merge("state" => "passed", "reason" => nil, "applicability" => {}, "findings" => [],
        "evidence" => [ proof_builder.call(task, identity, target: File.basename(args.fetch(:cwd))) ])
      raw = response ? response.call(task, args, proposal) : JSON.generate(proposal)
      raw.is_a?(Hash) ? raw : { status: :ok, actual_provider: "anthropic", actual_model: args.fetch(:capability_invocation).model, final_message: raw }
    }) { yield }
  end

  def with_capability_parent(task)
    prepare_test_runtime_project(task.project_root)
    attempts = Hive::Attempts::Repository.new(database: Hive::TaskCounter.database, root: File.join(task.project_root, "capability-attempt-payloads"))
    launcher = Object.new
    launcher.define_singleton_method(:preflight!) { true }
    launcher.define_singleton_method(:launch) { |*, **| { "claimed" => true } }
    dispatcher = Hive::Attempts::Dispatcher.new(store: attempts, launcher: launcher, capability_generator: -> { "c" * 64 })
    parent = dispatcher.dispatch(task: task, project: "test-#{Digest::SHA256.hexdigest(task.project_root)[0, 16]}", intended_stage: "#{task.stage_index}-#{task.stage_name}", argv: [ "hive", "run", task.slug ], request_id: "parent-#{task.id}", provider: "claude").attempt
    owner = { "pid" => Process.pid, "start_fingerprint" => Hive::Lock.process_start_time(Process.pid), "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
    parent = attempts.claim(parent, owner: owner, claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
    parent = attempts.first_heartbeat(parent, stale_sec: 30, now: Time.now.utc)
    context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0,
      ownership_generation: parent.ownership_generation, intended_stage: "#{task.stage_index}-#{task.stage_name}")
    with_replaced_singleton_method(Hive::Attempts::Repository, :open_default, ->(**) { attempts }) do
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) { yield context }
    end
  ensure
    context&.close
    if attempts && parent
      attempts.terminalize(attempts.fetch(parent.attempt_id), outcome: "succeeded", exit_status: 0,
        final_checkpoint: { "marker" => "review_complete" }, output_references: [],
        log_reference: { "path" => "open/fixture.frames", "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
    end
  end
end
