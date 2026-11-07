# frozen_string_literal: true

require "digest"
require "hive/command_receipt_store"
require "hive/project_identity"
require "hive/remote/serializers"

module Hive
  module Remote
    # Receipt identity survives disposable dispatch transport rows. This reader
    # accepts an already-authorized project and never enrolls a new namespace.
    class OperationProjection
      COMMANDS = %w[new act answer approve].freeze

      def initialize(store: Hive::CommandReceiptStore.new)
        @store = store
        @database = store.database
      end

      def existing(project:, key:, principal:)
        identity = identity(project)
        return nil unless identity
        digest = Digest::SHA256.hexdigest(Hive::CommandMutations.normalize_key(key))
        row = @database.read do |db|
          db[:command_receipts][namespace_id: identity.namespace_id, key_digest: digest]
        end
        raise Hive::CommandConflict if row && row.fetch(:principal) != principal
        row
      end

      def call(project:, id:, principal:, scopes:)
        not_found! unless id.to_s.match?(/\A[0-9a-f-]{36}\z/)
        identity = identity(project)
        row = identity && @database.read do |db|
          db[:command_receipts][namespace_id: identity.namespace_id, receipt_id: id]
        end
        not_found! unless row && row[:principal_source] == "api_token" && COMMANDS.include?(row[:command])
        not_found! unless row.fetch(:principal) == principal || Array(scopes).include?("read")

        payload = payload(row)
        acknowledgement = payload && payload["command_receipt"].is_a?(Hash) ? Serializers.acknowledgement(payload) : nil
        progress = workflow_progress(row, payload, project)
        state = state_for(row, payload, progress)
        {
          "id" => row.fetch(:receipt_id), "command" => row.fetch(:command),
          "state" => state, "command_outcome" => row.fetch(:state),
          "result_available" => !acknowledgement.nil?,
          "result_expired" => row.fetch(:state) == "settled" || state == "result_expired",
          "acknowledgement" => acknowledgement, "progress" => progress
        }
      end

      private

      def identity(project)
        @store.verify_extension!
        Hive::ProjectIdentity.resolve(project_root: project.fetch("path"), database: @database, create: false)
      end

      def payload(row)
        bytes = row[:result_json]
        return nil unless bytes
        unless Digest::SHA256.hexdigest(bytes) == row.fetch(:result_digest)
          raise Hive::ConfigError, "invalid command result"
        end
        stored = Hive::RuntimeControlPlane::Codec.load_json(bytes)
        value = stored["payload"] if %w[dual json].include?(stored["format"])
        value if value.is_a?(Hash)
      end

      def workflow_progress(row, payload, project)
        return nil unless %w[act approve].include?(row.fetch(:command))
        @database.read do |db|
          context = db[:command_dispatch_contexts].where(receipt_id: row.fetch(:receipt_id)).order(:ordinal).first
          request_id = payload && payload["request_id"] || context && context[:request_id]
          next nil unless request_id
          slug = payload && payload["slug"] || row.fetch(:original_target).split(":", 2).last
          attempt = db[:attempts][request_id: request_id, project_name: project.fetch("name"), task_slug: slug]
          if attempt
            receipt = attempt[:terminal_receipt_json] && Hive::RuntimeControlPlane::Codec.load_json(attempt[:terminal_receipt_json])
            subject = Hive::RuntimeControlPlane::Codec.load_json(attempt.fetch(:subject_json))
            next {
              "request_id" => request_id, "attempt_id" => attempt.fetch(:attempt_id),
              "state" => attempt_state(attempt), "stage" => subject["intended_stage"],
              "outcome" => attempt[:outcome], "exit_status" => receipt && receipt["exit_status"],
              "started_at" => attempt[:started_at], "ended_at" => attempt[:ended_at]
            }
          end
          dispatch = db[:dispatch_requests][request_id: request_id, task_slug: slug]
          if dispatch
            request = Hive::RuntimeControlPlane::Codec.load_json(dispatch.fetch(:payload_json))
            result = dispatch[:result_json] && Hive::RuntimeControlPlane::Codec.load_json(dispatch[:result_json])
            outcome = result && result.dig("receipt", "outcome")
            state = if outcome
              outcome == "succeeded" ? "succeeded" : "failed"
            elsif result && result["exit_code"]
              result["exit_code"] == 0 ? "succeeded" : "failed"
            elsif %w[queued claimed admitted].include?(dispatch[:state])
              "queued"
            else
              "unresolved"
            end
            next { "request_id" => request_id, "state" => state, "stage" => request["expected_stage"], "outcome" => outcome }
          end
          { "request_id" => request_id, "state" => "result_expired" }
        end
      end

      def attempt_state(attempt)
        case attempt.fetch(:state)
        when "launching", "running" then "running"
        when "terminal" then attempt[:outcome] == "succeeded" ? "succeeded" : "failed"
        else "unresolved"
        end
      end

      def state_for(row, payload, progress)
        case row.fetch(:state)
        when "prepared" then "accepted"
        when "executing" then "running"
        when "aborted", "unresolved" then "unresolved"
        when "succeeded"
          progress ? progress.fetch("state") : payload && payload["queued"] ? "queued" : "succeeded"
        else row.fetch(:state)
        end
      end

      def not_found!
        raise Error.new(code: "not_found", status: 404, message: "resource not found")
      end
    end
  end
end
