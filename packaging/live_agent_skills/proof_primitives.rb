# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module HiveLiveAgentProof
  SCHEMA_VERSION = 1
  SAFE_SHA = /\A[0-9a-f]{40}\z/.freeze
  SAFE_DIGEST = /\A[0-9a-f]{64}\z/.freeze
  SECRET_PATTERNS = [
    /sk-ant-[A-Za-z0-9_-]{12,}/,
    /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
    /gh[opsu]_[A-Za-z0-9]{20,}/,
    /github_pat_[A-Za-z0-9_]{20,}/,
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  ].freeze

  class Error < StandardError; end

  module_function

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def canonical_json(value)
    normalize = lambda do |nested|
      case nested
      when Hash
        raise TypeError, "JSON object keys must be strings" unless nested.keys.all?(String)

        nested.keys.sort.to_h { |key| [ key, normalize.call(nested.fetch(key)) ] }
      when Array
        nested.map { |item| normalize.call(item) }
      else
        nested
      end
    end
    "#{JSON.pretty_generate(normalize.call(value))}\n"
  rescue JSON::GeneratorError, ArgumentError, TypeError => e
    raise Error, "cannot canonicalize JSON: #{e.message}"
  end

  def safe_relative_path?(value)
    return false unless value.is_a?(String) && !value.empty?

    clean = Pathname.new(value).cleanpath
    clean.to_s == value && value != "." && !clean.absolute? &&
      !clean.each_filename.include?("..")
  rescue ArgumentError
    false
  end

  def secret_findings(text, exact_secrets: [])
    findings = SECRET_PATTERNS.filter_map do |pattern|
      "pattern:#{pattern.source}" if pattern.match?(text)
    end
    exact_secrets.each_with_index do |secret, index|
      next if secret.to_s.empty?

      findings << "exact-secret:#{index}" if text.include?(secret)
    end
    findings
  end
end
