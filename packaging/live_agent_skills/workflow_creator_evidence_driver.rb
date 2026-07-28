#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "timeout"
require_relative "proof"

module HiveLiveAgentProof
  class WorkflowCreatorEvidenceDriver
    PHASE_REASONS = {
      "artifact_download" => %w[artifact_download_failed],
      "artifact_extraction" => %w[artifact_missing artifact_extraction_failed],
      "ruby_setup" => %w[infrastructure_action_failed],
      "node_setup" => %w[infrastructure_action_failed],
      "lock_validation" => %w[openclaw_lock_invalid],
      "openclaw_install" => %w[openclaw_npm_install_failed],
      "openclaw_identity" => %w[openclaw_binary_invalid openclaw_version_invalid],
      "candidate_install" => %w[candidate_gem_install_failed],
      "candidate_identity" => %w[candidate_binary_invalid candidate_version_invalid],
      "bundle_install" => %w[bundle_install_failed],
      "openclaw_receipt" => %w[openclaw_receipt_failed],
      "candidate_receipt" => %w[candidate_receipt_failed],
      "proof" => %w[proof_not_completed],
      "infrastructure" => %w[infrastructure_action_failed]
    }.freeze
    OUTPUT_LIMIT = 8 * 1024
    DETAIL_LIMIT = 1_000
    DEFAULT_TIMEOUT = 600
    MAX_TIMEOUT = 900

    def initialize(path:, candidate_sha:, model:)
      @path = File.expand_path(path)
      @candidate_sha = candidate_sha.to_s.downcase
      @model = model.to_s
    end

    def initialize_evidence!
      raise Error, "evidence already exists" if File.exist?(@path)

      write(
        "schema" => "hive-live-workflow-creator-evidence",
        "schema_version" => SCHEMA_VERSION,
        "platform" => "openclaw",
        "candidate_sha" => SAFE_SHA.match?(@candidate_sha) ? @candidate_sha : "unresolved",
        "result" => "failed",
        "phase" => "preparation",
        "reason" => "not_started",
        "provider" => {
          "name" => "unresolved",
          "model" => redact(@model),
          "credential_environment" => nil
        },
        "openclaw_package" => {
          "version" => WORKFLOW_CREATOR_OPENCLAW_VERSION,
          "integrity" => WORKFLOW_CREATOR_OPENCLAW_INTEGRITY,
          "lock_sha256" => WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256,
          "package_count" => WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT,
          "verified" => false
        },
        "preparation" => [],
        "secret_scan" => {
          "status" => "passed",
          "scanner" => "hive-live-agent-proof/v1"
        }
      )
    end

    def run!(phase:, reason:, command:, timeout: DEFAULT_TIMEOUT)
      validate_partition!(phase, reason)
      timeout = Integer(timeout)
      raise Error, "preparation timeout is invalid" unless timeout.between?(1, MAX_TIMEOUT)
      raise Error, "preparation command is missing" if command.empty?

      output = +"".b
      status = nil
      timed_out = false
      Open3.popen2e({}, *command, pgroup: true) do |input, stream, waiter|
        input.close
        reader = Thread.new do
          loop do
            chunk = stream.readpartial(16 * 1024)
            $stdout.write(chunk)
            remaining = OUTPUT_LIMIT - output.bytesize
            output << chunk.byteslice(0, remaining) if remaining.positive?
          end
        rescue EOFError, IOError
          nil
        end
        begin
          Timeout.timeout(timeout) { status = waiter.value }
        rescue Timeout::Error
          timed_out = true
          terminate_group(waiter.pid)
          status = waiter.value
        ensure
          stream.close unless stream.closed?
          reader.join(2)
        end
      end
      if status&.success? && !timed_out
        record_success(phase, command)
        return true
      end

      detail = output.to_s.scrub.lines.first(12).join
      detail = "preparation command timed out" if timed_out
      fail_partition!(phase: phase, reason: reason, detail: detail)
      false
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => e
      fail_partition!(phase: phase, reason: reason, detail: e.message)
      false
    end

    def fail_partition!(phase:, reason:, detail:)
      validate_partition!(phase, reason)
      payload = read
      payload.merge!(
        "result" => "failed",
        "phase" => phase,
        "reason" => reason,
        "detail" => redact(detail)
      )
      payload["secret_scan"] = {
        "status" => "passed",
        "scanner" => "hive-live-agent-proof/v1"
      }
      write(payload)
    end

    def finalize!
      payload = read
      if payload["reason"] == "not_started" || payload["reason"] == "in_progress"
        payload.merge!(
          "result" => "failed",
          "phase" => "proof",
          "reason" => "proof_not_completed",
          "detail" => "workflow-creator proof did not retain a terminal result"
        )
      end
      write(payload)
    end

    private

    def validate_partition!(phase, reason)
      unless PHASE_REASONS.fetch(phase.to_s, []).include?(reason.to_s)
        raise Error, "unknown workflow-creator failure partition"
      end
    end

    def record_success(phase, command)
      payload = read
      preparation = Array(payload["preparation"])
      raise Error, "preparation receipt count exceeded" if preparation.length >= 32

      preparation << {
        "phase" => phase,
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(command.map(&:to_s))),
        "status" => "passed"
      }
      payload.merge!(
        "phase" => "preparation",
        "reason" => "in_progress",
        "preparation" => preparation
      )
      write(payload)
    end

    def terminate_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.1
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    def read
      payload = JSON.parse(File.read(@path))
      unless payload.is_a?(Hash) &&
             payload["schema"] == "hive-live-workflow-creator-evidence" &&
             payload["schema_version"] == SCHEMA_VERSION
        raise Error, "workflow-creator preparation evidence is invalid"
      end
      payload
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot read workflow-creator preparation evidence: #{e.message}"
    end

    def write(payload)
      serialized = JSON.pretty_generate(deep_redact(payload))
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      temporary = "#{@path}.tmp-#{Process.pid}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(serialized)
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, @path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def deep_redact(value)
      case value
      when Hash
        value.to_h { |key, nested| [ key, deep_redact(nested) ] }
      when Array
        value.map { |nested| deep_redact(nested) }
      when String
        redact(value)
      else
        value
      end
    end

    def redact(value)
      redacted = value.to_s
      SECRET_PATTERNS.each { |pattern| redacted = redacted.gsub(pattern, "[REDACTED]") }
      redacted.byteslice(0, DETAIL_LIMIT).to_s.scrub
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
  command = ARGV.shift.to_s
  options = { timeout: HiveLiveAgentProof::WorkflowCreatorEvidenceDriver::DEFAULT_TIMEOUT }
  parser = OptionParser.new do |value|
    value.on("--path PATH") { |path| options[:path] = path }
    value.on("--candidate-sha SHA") { |sha| options[:candidate_sha] = sha }
    value.on("--model MODEL") { |model| options[:model] = model }
    value.on("--phase PHASE") { |phase| options[:phase] = phase }
    value.on("--reason REASON") { |reason| options[:reason] = reason }
    value.on("--detail DETAIL") { |detail| options[:detail] = detail }
    value.on("--timeout SECONDS", Integer) { |seconds| options[:timeout] = seconds }
  end
  parser.order!(ARGV)
  path = options.fetch(:path)
  candidate_sha = options.fetch(:candidate_sha, "unresolved")
  model = options.fetch(:model, "unresolved")
  driver = HiveLiveAgentProof::WorkflowCreatorEvidenceDriver.new(
    path: path,
    candidate_sha: candidate_sha,
    model: model
  )
  case command
  when "initialize"
    driver.initialize_evidence!
  when "run"
    succeeded = driver.run!(
      phase: options.fetch(:phase),
      reason: options.fetch(:reason),
      command: ARGV,
      timeout: options.fetch(:timeout)
    )
    exit 1 unless succeeded
  when "fail"
    driver.fail_partition!(
      phase: options.fetch(:phase),
      reason: options.fetch(:reason),
      detail: options.fetch(:detail)
    )
    exit 1
  when "finalize"
    driver.finalize!
  else
    abort "usage: workflow_creator_evidence_driver.rb initialize|run|fail|finalize [options]"
  end
  rescue HiveLiveAgentProof::Error, KeyError, ArgumentError => e
    warn e.message
    exit 64
  end
end
