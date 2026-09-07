# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "tmpdir"
require "time"
require "timeout"
require "uri"
require "hive/brainstorm_suggestions/validator"
require "hive/stages/base"

module Hive
  module BrainstormSuggestions
    # Sends a bounded, controller-built data message to a provider API. The
    # model has no process, filesystem, shell, tool, or arbitrary-network
    # surface: HTTPS is controller-owned transport to one fixed endpoint and
    # the only result channel is the response body validated below.
    class Runner
      MAX_OUTPUT_BYTES = 512 * 1024
      DEFAULT_TIMEOUT_SEC = 120
      MAX_RESPONSE_TOKENS = 1_024
      REQUIRED_CAPABILITY = :brainstorm_suggestion_data_only
      RUNTIME_PREFIX = "hive-brainstorm-suggestion-"
      OWNER_FILE = ".owner.json"
      SWEEP_GRACE_SEC = 300
      MODEL_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

      Execution = Data.define(:stdout, :exit_code, :timed_out, :too_large) do
        def initialize(stdout:, exit_code:, timed_out: false, too_large: false)
          super
        end
      end
      Request = Data.define(:model, :effort, :prompt, :schema)

      # Thread-safe cooperative cancellation. The scheduler binds this token
      # to the exact question/input/attempt CAS. The HTTP transport watches it
      # and closes an active request as soon as ownership changes.
      class Cancellation
        def initialize(&guard)
          @mutex = Mutex.new
          @cancelled = false
          @guard = guard
        end

        def cancel!
          @mutex.synchronize { @cancelled = true }
        end

        def bind!(&guard)
          @mutex.synchronize { @guard = guard }
          self
        end

        def cancelled?
          cancelled, guard = @mutex.synchronize { [ @cancelled, @guard ] }
          return true if cancelled
          return false unless guard

          guard.call != true
        rescue StandardError
          true
        end
      end

      # Controller-owned Anthropic Messages transport. Authentication is used
      # only to construct the outbound header; it is never copied into a
      # bundle, child environment, request value, result, log, or sidecar.
      class AnthropicTransport
        ENDPOINT = "https://api.anthropic.com/v1/messages"
        API_VERSION = "2023-06-01"
        WATCH_INTERVAL_SEC = 0.05

        class Error < StandardError; end
        class InvalidResponse < Error; end
        class OutputTooLarge < Error; end

        def initialize(api_key:, timeout_sec:, http_factory: nil)
          @api_key = api_key.to_s
          @timeout_sec = Float(timeout_sec)
          @http_factory = http_factory || method(:build_http)
        end

        def available?
          !@api_key.empty?
        end

        def call(request, cancellation = nil)
          return cancelled_execution if cancellation&.cancelled?

          uri = URI(ENDPOINT)
          http = @http_factory.call(uri)
          configure_timeouts(http)
          message = Net::HTTP::Post.new(uri.request_uri)
          message["content-type"] = "application/json"
          message["anthropic-version"] = API_VERSION
          message["x-api-key"] = @api_key
          message.body = JSON.generate(request_payload(request))
          completed = false
          watcher = cancellation_watcher(http, cancellation) { completed }
          response = nil
          body = +"".b
          http.start do |connection|
            connection.request(message) do |incoming|
              response = incoming
              incoming.read_body do |chunk|
                body << chunk
                raise OutputTooLarge if body.bytesize > MAX_OUTPUT_BYTES
              end
            end
          end
          completed = true
          return cancelled_execution if cancellation&.cancelled?
          return Execution.new(stdout: "", exit_code: response.code.to_i) unless response.is_a?(Net::HTTPSuccess)

          Execution.new(stdout: extract_text(body), exit_code: 0)
        rescue OutputTooLarge
          Execution.new(
            stdout: body.to_s.byteslice(0, MAX_OUTPUT_BYTES), exit_code: nil, too_large: true
          )
        rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
          Execution.new(stdout: "", exit_code: nil, timed_out: true)
        rescue InvalidResponse
          raise
        rescue IOError, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
          raise Error, error.class.name
        ensure
          completed = true
          close_http(http)
          watcher&.join(WATCH_INTERVAL_SEC * 4)
          watcher&.kill if watcher&.alive?
          watcher&.join
        end

        private

        def request_payload(request)
          output_config = {
            "format" => { "type" => "json_schema", "schema" => request.schema }
          }
          output_config["effort"] = request.effort if request.effort
          {
            "model" => request.model,
            "max_tokens" => MAX_RESPONSE_TOKENS,
            "messages" => [ { "role" => "user", "content" => request.prompt } ],
            "output_config" => output_config
          }
        end

        def extract_text(body)
          payload = JSON.parse(body.force_encoding(Encoding::UTF_8).scrub)
          blocks = payload.fetch("content")
          raise InvalidResponse, "content must be an array" unless blocks.is_a?(Array)

          text = blocks.filter_map do |block|
            block["text"] if block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String)
          end
          raise InvalidResponse, "expected exactly one structured text block" unless text.length == 1

          text.first
        rescue JSON::ParserError, KeyError => error
          raise InvalidResponse, error.class.name
        end

        def cancellation_watcher(http, cancellation)
          return unless cancellation

          Thread.new do
            loop do
              break if yield
              if cancellation.cancelled?
                close_http(http)
                break
              end
              sleep WATCH_INTERVAL_SEC
            end
          end
        end

        def configure_timeouts(http)
          http.open_timeout = @timeout_sec
          http.read_timeout = @timeout_sec
          http.write_timeout = @timeout_sec if http.respond_to?(:write_timeout=)
        end

        def build_http(uri)
          Net::HTTP.new(uri.host, uri.port, nil).tap { |http| http.use_ssl = true }
        end

        def close_http(http)
          http.finish if http&.started?
        rescue IOError, SystemCallError
          nil
        end

        def cancelled_execution
          Execution.new(stdout: "", exit_code: nil, timed_out: true)
        end
      end

      OUTPUT_SCHEMA = {
        "type" => "object",
        "additionalProperties" => false,
        "required" => [ "disposition" ],
        "properties" => {
          "disposition" => { "enum" => %w[suggestion no_safe_suggestion] },
          "text" => { "type" => "string" },
          "rationale" => { "type" => "string" },
          "provenance" => { "type" => "array", "items" => { "type" => "string" } },
          "reason_code" => {
            "enum" => %w[insufficient_evidence conflicting_evidence sensitive_context unsafe_output]
          }
        }
      }.freeze

      def self.profile_supported?(profile)
        profile.respond_to?(:policy_capabilities) &&
          profile.policy_capabilities.include?(REQUIRED_CAPABILITY)
      rescue NoMethodError
        false
      end

      def self.sweep_inactive!(runtime_parent = Dir.tmpdir, now: Time.now)
        return 0 unless File.directory?(runtime_parent)

        Dir.children(runtime_parent).count do |name|
          next false unless name.start_with?(RUNTIME_PREFIX)

          path = File.join(runtime_parent, name)
          status = File.lstat(path)
          next false unless status.directory? && !status.symlink? && status.uid == Process.uid
          next false if runtime_live?(path)
          next false if now - status.mtime < SWEEP_GRACE_SEC

          FileUtils.remove_entry_secure(path)
          true
        rescue SystemCallError, IOError
          false
        end
      end

      def self.runtime_live?(path)
        owner = JSON.parse(File.read(File.join(path, OWNER_FILE), 4 * 1024))
        pid = Integer(owner.fetch("pid"))
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        true
      end
      private_class_method :runtime_live?

      def initialize(profile:, model:, effort: nil, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     transport: nil, api_key: ENV["ANTHROPIC_API_KEY"], runtime_parent: Dir.tmpdir)
        @profile = profile
        @model = normalize_model(model)
        @effort = normalize_effort(effort)
        @timeout_sec = Float(timeout_sec)
        @transport = transport || AnthropicTransport.new(api_key: api_key, timeout_sec: @timeout_sec)
        @runtime_parent = runtime_parent
      end

      def call(bundle:, cancellation: nil)
        return unavailable_result unless available?
        return failed_result("cancelled") if cancellation&.cancelled?

        runtime_root = Dir.mktmpdir(RUNTIME_PREFIX, @runtime_parent)
        File.chmod(0o700, runtime_root)
        File.write(
          File.join(runtime_root, OWNER_FILE),
          JSON.generate("pid" => Process.pid, "created_at" => Time.now.utc.iso8601),
          mode: "w", perm: 0o400
        )
        bundle.materialize(runtime_root)
        request = Request.new(
          model: @model, effort: @effort, prompt: render_prompt(bundle).freeze,
          schema: OUTPUT_SCHEMA
        ).freeze
        execution = invoke_transport(request, cancellation)
        return failed_result("cancelled") if cancellation&.cancelled?
        return failed_result("timeout") if execution.timed_out
        return failed_result("output_too_large") if execution.too_large
        return failed_result("provider_exit") unless execution.exit_code == 0

        Validator.call(extract_structured_output(execution.stdout), manifest: bundle.manifest)
      rescue AnthropicTransport::InvalidResponse, Validator::InvalidOutput, JSON::ParserError
        failed_result("malformed_result")
      rescue AnthropicTransport::Error, SystemCallError, IOError, ArgumentError
        cancellation&.cancelled? ? failed_result("cancelled") : failed_result("transport_error")
      ensure
        FileUtils.remove_entry_secure(runtime_root) if runtime_root && File.exist?(runtime_root)
      end

      def available?
        self.class.profile_supported?(@profile) && !@model.nil? &&
          @transport.respond_to?(:call) &&
          (!@transport.respond_to?(:available?) || @transport.available?)
      rescue StandardError
        false
      end

      private

      def invoke_transport(request, cancellation)
        @transport.call(request, cancellation)
      end

      def render_prompt(bundle)
        question_text = bundle.question.fetch("text")
        user_supplied_tag = Hive::Stages::Base.user_supplied_tag
        bound_context = bundle.render_context(user_supplied_tag: user_supplied_tag)
        source = File.read(
          File.expand_path("../../../templates/brainstorm_suggestion_prompt.md.erb", __dir__)
        )
        ERB.new(source, trim_mode: "-").result(binding)
      end

      def extract_structured_output(stdout)
        outer = JSON.parse(stdout.to_s)
        return outer.fetch("structured_output") if outer.is_a?(Hash) && outer["structured_output"].is_a?(Hash)
        return JSON.parse(outer.fetch("result")) if outer.is_a?(Hash) && outer["result"].is_a?(String)

        outer
      end

      def normalize_model(value)
        candidate = value.to_s
        return if %w[default inherit].include?(candidate)

        candidate if candidate.match?(MODEL_RE)
      end

      def normalize_effort(value)
        candidate = value.to_s
        candidate unless candidate.empty? || %w[default inherit].include?(candidate)
      end

      def unavailable_result
        {
          "state" => "unavailable", "text" => nil, "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "The configured suggestion route cannot enforce Hive's data-only transport.",
          "retryable" => true, "dismissed" => false, "error_code" => "isolation_unavailable"
        }
      end

      def failed_result(code)
        {
          "state" => "failed", "text" => nil, "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "Suggestion generation failed; manual answering remains available.",
          "retryable" => true, "dismissed" => false, "error_code" => code
        }
      end
    end
  end
end
