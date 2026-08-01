require "json"
require "pathname"

module HiveLiveAgentProof
  SCHEMA_VERSION = 1
  INVOCATIONS = {
    "openclaw" => "/hive",
    "claude" => "/hive",
    "codex" => "$hive",
    "pi" => "/skill:hive"
  }.freeze
  NATIVE_ACTIVATION_KINDS = {
    "openclaw" => "openclaw-skills-info",
    "claude" => "claude-system-init-skill",
    "codex" => "codex-structured-skill-access",
    "pi" => "pi-rpc-command"
  }.freeze
  SAFE_SHA = /\A[0-9a-f]{40}\z/.freeze
  SECRET_PATTERNS = [
    /sk-ant-[A-Za-z0-9_-]{12,}/,
    /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
    /gh[opsu]_[A-Za-z0-9]{20,}/,
    /github_pat_[A-Za-z0-9_]{20,}/,
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  ].freeze

  class Error < StandardError; end

  module_function

  def safe_relative_path?(value)
    return false unless value.is_a?(String) && !value.empty?
    return false if value.include?("\0")

    clean = Pathname.new(value).cleanpath
    clean.to_s != "." &&
      !clean.absolute? &&
      !clean.each_filename.include?("..") &&
      clean.to_s == value
  rescue ArgumentError
    false
  end

  def secret_findings(text, exact_secrets: [])
    findings = SECRET_PATTERNS.filter_map do |pattern|
      "pattern:#{pattern.source}" if pattern.match?(text)
    end
    exact_secrets.each_with_index do |secret, index|
      needle = secret.to_s
      next if needle.empty?

      findings << "exact-secret:#{index}" if text.include?(needle)
    end
    findings
  end

  def valid_native_activation?(platform, value)
    value.is_a?(Hash) && value.keys.sort == %w[invocation kind] &&
      value["kind"] == NATIVE_ACTIVATION_KINDS.fetch(platform) &&
      value["invocation"] == INVOCATIONS.fetch(platform)
  end
end
