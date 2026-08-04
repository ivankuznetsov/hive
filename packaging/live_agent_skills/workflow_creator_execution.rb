# frozen_string_literal: true

require "digest"
require_relative "workflow_creator_archive"
require_relative "workflow_creator_evidence"
require_relative "workflow_creator_gateway"
require_relative "workflow_creator_installation"

module HiveLiveAgentProof
  class WorkflowCreatorExecution
    class Error < StandardError; end
    class Conflict < Error; end
    class Unavailable < Error; end
    Draft = Data.define(:receipt_bytes, :receipt_sha256, :receipt_size) do
      def initialize(receipt_bytes:, receipt_sha256:, receipt_size:)
        super(receipt_bytes: receipt_bytes.dup.freeze,
              receipt_sha256: receipt_sha256.dup.freeze, receipt_size:)
      end
    end
    Result = Data.define(:status)
    LABELS = WorkflowCreator::ProcessSupervisor::LABELS
    OUTER_LABELS = LABELS.last(2)
    ARCHIVE_LABELS = WorkflowCreator::Vocabulary.fetch("archive_labels")
    SUPERVISOR_KEYS = %w[output_limit tail_limit timeout term_grace kill_grace].freeze

    def self.start!(**options) = new(**options).send(:activate)
    private_class_method :new

    attr_reader :gateway_path, :workspace_path

    def initialize(candidate_sha:, manifest:, candidate:, openclaw:, archives:, workspace_path:,
                   bundle_directory:, correlation_id:, exact_secrets: [], supervisor_options: {})
      input = WorkflowCreator::Values.capture(
        "candidate_sha" => candidate_sha, "manifest" => manifest, "candidate" => candidate,
        "openclaw" => openclaw, "archives" => archives, "workspace_path" => workspace_path,
        "bundle_directory" => bundle_directory, "correlation_id" => correlation_id,
        "exact_secrets" => exact_secrets, "supervisor_options" => supervisor_options
      ).value
      @candidate_sha, @manifest, @candidate, @openclaw, @archives = input.values_at(
        "candidate_sha", "manifest", "candidate", "openclaw", "archives")
      raise Error unless @archives.keys == ARCHIVE_LABELS
      options = input.fetch("supervisor_options")
      raise Error unless options.instance_of?(Hash) && (options.keys - SUPERVISOR_KEYS).empty?
      workspace = input.fetch("workspace_path")
      @workspace_path = File.join(File.realpath(File.dirname(workspace)), File.basename(workspace)).freeze
      @bundle_directory = File.realpath(input.fetch("bundle_directory")).freeze
      paths = [ @candidate.fetch("root"), @openclaw.fetch("root") ].map { |path| File.realpath(path) }
      paths.concat([ @workspace_path, @bundle_directory ])
      raise Error if paths.combination(2).any? do |left, right|
        left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
      end
      @correlation_id = input.fetch("correlation_id")
      @exact_secrets = input.fetch("exact_secrets")
      @supervisor_options = options.transform_keys(&:to_sym)
      @result = Result.new(status: "not_started")
      @outer_launches = {}
    rescue WorkflowCreator::Values::Error, KeyError, TypeError, SystemCallError
      raise Error, "workflow-creator execution inputs are invalid", cause: nil
    end

    def activate
      @supervisor = WorkflowCreator::ProcessSupervisor.new(
        correlation_id: @correlation_id, exact_secrets: @exact_secrets, **@supervisor_options
      )
      @supervisor.create_proof_workspace(@workspace_path)
      @openclaw_installation = scan_openclaw
      executable = role_path(@candidate, "executable")
      gateway = role_path(@candidate, "audit_gateway")
      @gateway = WorkflowCreatorGateway.new(
        root: File.dirname(gateway), candidate_executable: executable,
        candidate_identity: observed_file(executable, relative_role(@candidate, executable)),
        environment: @candidate.fetch("environment"), cwd: @workspace_path, supervisor: @supervisor
      )
      @gateway_path = @gateway.start!
      self
    rescue StandardError => error
      abort_session
      raise_execution(error)
    end
    private :activate

    def run_outer_workflow_creator(**launch) = run_outer(OUTER_LABELS.first, launch)
    def run_outer_authorized_work(**launch) = run_outer(OUTER_LABELS.last, launch)

    def draft!(executed_instruction:)
      raise Conflict, "workflow-creator execution draft already exists" if @draft
      observation = WorkflowCreator::Values.capture(executed_instruction).value
      expected = WorkflowCreator::Vocabulary.fetch("executed_instruction")
      raise Error unless observation == observed_file(File.join(@workspace_path, expected), expected)
      commands = @gateway.finish!
      @candidate_installation = scan_candidate
      @openclaw_installation = scan_openclaw
      archives = ARCHIVE_LABELS.map do |label|
        row = @archives.fetch(label)
        WorkflowCreatorArchive.admit!(archive: row.fetch("path"), label:,
                                      available_bytes: row.fetch("available_bytes"),
                                      available_entries: row.fetch("available_entries")).value
      end
      teardown = @supervisor.teardown
      raise Error, "workflow-creator execution teardown is incomplete" unless teardown.fetch("status") == "passed"
      outer = project_outer(@supervisor.receipts)
      cleanup = @supervisor.cleanup_proof_workspace
      @cleaned = cleanup.values_at("identity_matched", "removed").all?
      raise Error, "workflow-creator execution cleanup failed" unless @cleaned

      names = WorkflowCreator::Vocabulary.fetch("bundle_files").slice(1, 2)
      @installation_records = [ @candidate_installation, @openclaw_installation ].each_with_index.map do |snapshot, index|
        bytes = snapshot.canonical_bytes
        { "kind" => %w[candidate_installation openclaw_installation].fetch(index),
          "path" => names.fetch(index), "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
      end
      @receipt = receipt(commands, outer, archives, observation, teardown, cleanup)
      bytes = WorkflowCreator::Values.capture(@receipt).canonical_bytes
      @draft = Draft.new(receipt_bytes: bytes, receipt_sha256: Digest::SHA256.hexdigest(bytes),
                         receipt_size: bytes.bytesize)
    rescue StandardError => error
      abort_session
      raise_execution(error)
    end

    def finish!(primary_row:)
      raise Error, "workflow-creator execution has no draft" unless @draft
      primary = WorkflowCreator::Values.capture(primary_row)
      WorkflowCreator.validate_execution!(
        receipt: @receipt, row: primary.value, candidate_sha: @candidate_sha, manifest: @manifest,
        installation_records: @installation_records, receipt_sha256: @draft.receipt_sha256,
        candidate_installation: @candidate_installation.value,
        openclaw_installation: @openclaw_installation.value
      )
      raise Conflict, "workflow-creator execution primary identity conflicts" if
        @primary_bytes && @primary_bytes != primary.canonical_bytes
      @primary_bytes ||= primary.canonical_bytes
      names = WorkflowCreator::Vocabulary.fetch("bundle_files").drop(1)
      members = [ @candidate_installation.canonical_bytes, @openclaw_installation.canonical_bytes,
                  @draft.receipt_bytes ]
      names.zip(members).each do |name, bytes|
        WorkflowCreatorReceiptPublisher.new(bundle_directory: @bundle_directory, target_name: name)
                                       .initialize_receipt(bytes)
      end
      @result = Result.new(status: "passed")
    rescue WorkflowCreatorReceiptPublisher::Conflict
      fail_result
      raise Conflict, "workflow-creator execution publication conflicts", cause: nil
    rescue WorkflowCreatorReceiptPublisher::Unavailable
      fail_result
      raise Unavailable, "workflow-creator execution publication is unavailable", cause: nil
    rescue WorkflowCreatorReceiptPublisher::Error
      fail_result
      raise Error, "workflow-creator execution publication failed", cause: nil
    rescue StandardError => error
      fail_result
      raise_execution(error)
    end

    def result = @result

    def close
      @gateway&.close
      cleanup_workspace unless @cleaned
      fail_result unless @result.status == "passed"
      nil
    end

    private

    def run_outer(label, launch)
      keys = launch.keys.sort
      raise Error unless keys == %i[argv environment] || keys == %i[argv environment stdin_data]
      current = scan_openclaw
      raise Error unless current.canonical_bytes == @openclaw_installation.canonical_bytes
      raw = { "argv" => launch.fetch(:argv), "environment" => launch.fetch(:environment),
              "stdin_data" => launch[:stdin_data] }
      options = WorkflowCreator::Values.capture(raw).value
      @outer_launches[label] = options.fetch("argv")
      args = { executable: role_path(@openclaw, "executable"), argv: options.fetch("argv"),
               environment: options.fetch("environment"), cwd: @workspace_path,
               stdin_data: options.fetch("stdin_data") }
      label == OUTER_LABELS.first ? @supervisor.run_outer_workflow_creator(**args) :
        @supervisor.run_outer_authorized_work(**args)
    rescue StandardError => error
      fail_result
      raise_execution(error)
    end

    def scan_candidate
      args = @candidate.except("environment").transform_keys(&:to_sym)
      WorkflowCreatorInstallation.candidate!(**args, candidate_sha: @candidate_sha, manifest: @manifest)
    end

    def scan_openclaw
      WorkflowCreatorInstallation.openclaw!(**@openclaw.transform_keys(&:to_sym),
                                            candidate_sha: @candidate_sha, manifest: @manifest)
    end

    def project_outer(receipts)
      roles = WorkflowCreator::Vocabulary.fetch("outer_roles")
      OUTER_LABELS.each_with_index.map do |label, index|
        process = receipts.find { |row| row.fetch("label") == label }
        raise Error unless passing_process?(process)
        capture = process.fetch("capture").except("tails")
        capture["secret_scan"] = capture.fetch("secret_scan").except("findings")
        role = roles.fetch(index)
        { "label" => label, "role" => role.fetch("role"),
          "argv_sha256" => Digest::SHA256.hexdigest(WorkflowCreator::Values.capture(@outer_launches.fetch(label)).canonical_bytes),
          "prompt_sha256" => role.fetch("prompt_sha256"), "exit_code" => process.fetch("exit_code"),
          "signal" => process.fetch("signal"), "completed" => process.fetch("completed"),
          "capture" => capture, "teardown" => process.fetch("teardown") }
      end
    end

    def passing_process?(process)
      process && process.values_at("exit_code", "signal", "completed", "timed_out") == [ 0, nil, true, false ] &&
        process.dig("teardown", "status") == "passed" &&
        process.dig("capture", "secret_scan", "status") == "passed" &&
        %w[stdout stderr].none? { |stream| process.dig("capture", "#{stream}_truncated") }
    end

    def receipt(commands, outer, archives, observation, teardown, cleanup)
      slug = commands.fetch(6).fetch("argv").fetch(1)
      vocabulary = WorkflowCreator::Vocabulary
      { "schema" => vocabulary.fetch("execution_schema"), "schema_version" => 1,
        "candidate_sha" => @candidate_sha, "result" => "passed",
        "execution_plan" => vocabulary.fetch("execution_plan"),
        "classification" => { "outer" => vocabulary.fetch("classification"), "nested_stage" => {
          "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" } },
        "installed_manifests" => @installation_records,
        "run" => { "correlation_id" => @correlation_id, "expected_labels" => LABELS },
        "gateway" => { "identity" => @candidate_installation.value.dig("required_roles", "audit_gateway"),
                       "command_labels" => vocabulary.fetch("command_labels"), "status" => "passed" },
        "task_slug_binding" => vocabulary.fetch("task_slug_binding").merge("value" => slug),
        "archive_admissions" => archives, "commands" => commands, "outer_processes" => outer,
        "authored_instruction" => observation, "executed_instruction" => observation, "external_actions" => [],
        "containment" => { "status" => "passed", "mechanism" => "supervised-process-tree",
                           "established_before_launch" => true, "owner_correlation_id" => @correlation_id,
                           "root_loss_behavior" => "fail-closed" },
        "teardown" => teardown, "cleanup" => { "status" => "passed", "targets" => [ cleanup ] },
        "secret_scan" => { "status" => "passed", "scanner" => vocabulary.fetch("scanner") } }
    end

    def role_path(source, role)
      value = source.fetch(role)
      value.start_with?(File::SEPARATOR) ? value : File.join(source.fetch("root"), value)
    end

    def relative_role(source, path)
      prefix = "#{source.fetch("root")}/"
      raise Error unless path.start_with?(prefix)
      path.delete_prefix(prefix)
    end

    def observed_file(path, relative)
      stat = File.lstat(path)
      raise Error unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
      { "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest, "size" => stat.size }
    end

    def cleanup_workspace
      cleanup = @supervisor&.cleanup_proof_workspace
      @cleaned = cleanup && cleanup.values_at("identity_matched", "removed").all?
    rescue StandardError
      @cleaned = false
    end

    def abort_session = close
    def fail_result = @result = Result.new(status: "failed")

    def raise_execution(error)
      raise error if error.is_a?(Error)
      raise Error, "workflow-creator execution failed", cause: nil
    end
  end
end
