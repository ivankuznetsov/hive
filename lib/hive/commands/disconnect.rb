require "json"
require "hive/config"
require "hive/commands/screenote_envelope"
require "hive/screenote/credential_store"
require "hive/screenote/oauth_client"

module Hive
  module Commands
    class Disconnect
      def initialize(service, json: false, output: $stdout,
                     credential_store: Hive::Screenote::CredentialStore.new,
                     oauth_client_factory: nil)
        @service = service.to_s
        @json = json
        @output = output
        @credential_store = credential_store
        @oauth_client_factory = oauth_client_factory || ->(url) { Hive::Screenote::OAuthClient.new(base_url: url) }
      end

      def call
        ensure_screenote!
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue SystemCallError => e
        # An OS-level failure (e.g. clearing the credential file on a
        # read-only FS) is not a Hive::Error, so it would escape bin/hive's
        # rescue as a raw backtrace. Map it to a typed error with the same
        # envelope treatment as the sibling commands.
        wrapped = Hive::Error.new("Screenote disconnect failed: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      private

      def do_call
        credential = load_credential
        # File genuinely absent → idempotent no-op. A present-but-corrupt
        # file returns nil from load_credential AND must still be cleared,
        # so it falls through to the clear path below.
        return emit_absent if credential.nil? && !@credential_store.present?

        revoked, reason = credential ? revoke(credential) : [ false, "unreadable_credential" ]
        @credential_store.clear
        emit_disconnected(revoked, reason)
      end

      def ensure_screenote!
        return if @service == "screenote"

        raise Hive::Error, "unsupported disconnect service #{@service.inspect}; expected screenote"
      end

      # A corrupt local file must not block `disconnect` — the operator
      # wants to clear it. Treat an unreadable file as nil so `call` skips
      # revoke (no usable token) and still clears the file.
      def load_credential
        @credential_store.load
      rescue Hive::ConfigError => e
        warn "[hive] screenote credential unreadable; clearing it anyway: #{e.message}"
        nil
      end

      # Returns [revoked, reason]. `reason` is nil when revoke succeeds and a
      # short string otherwise, so a `--json` consumer can tell the failure
      # apart from `revoked: false` alone. RFC 7009 makes revoke idempotent
      # (an already-revoked token still returns success), so the only emitted
      # reasons are `no_token`, `unreadable_credential` (set by the caller),
      # or the raw revoke/discover error message.
      def revoke(credential)
        token = credential["access_token"].to_s
        return [ false, "no_token" ] if token.empty?

        client = @oauth_client_factory.call(credential["base_url"] || Hive::Config.global_screenote_base_url)
        metadata = client.discover
        client.revoke(token: token, client_id: credential["client_id"], metadata: metadata)
        [ true, nil ]
      rescue StandardError => e
        # Broaden beyond Hive::Error as a backstop: any unmapped failure from
        # discover/revoke must NOT escape before `clear` runs — that would
        # crash disconnect AND leave the stale local credential, the opposite
        # of the documented fail-soft. (Http now maps TLS and OS-level
        # transport errors to Hive::Error, so this mostly catches the
        # unexpected; the broad rescue stays as the safety net.)
        warn "[hive] screenote revoke failed; clearing local credential anyway: #{e.message}"
        [ false, e.message ]
      end

      def emit_absent
        if @json
          # Carry `revoked` (always false here) so the not-connected path is
          # shape-consistent with emit_disconnected and the documented
          # `{ "disconnected", "revoked", "reason" }` contract — a consumer
          # that unconditionally reads result["revoked"] gets false, not nil.
          @output.puts JSON.generate("ok" => true, "service" => "screenote", "disconnected" => false,
                                     "revoked" => false, "reason" => "not_connected")
        else
          @output.puts "Screenote is not connected."
        end
      end

      def emit_disconnected(revoked, reason = nil)
        if @json
          payload = { "ok" => true, "service" => "screenote", "disconnected" => true,
                      "revoked" => revoked, "credential_path" => @credential_store.path }
          payload["reason"] = reason if reason
          @output.puts JSON.generate(payload)
        else
          @output.puts "Disconnected Screenote."
        end
      end

      # A `--json` failure (unsupported service, an OS-level clear failure)
      # otherwise printed only Thor plain-text to stderr, inconsistent with
      # the success envelope. Emit a structured `{ "ok": false, … }` line so
      # automation gets a parseable failure document before the non-zero exit.
      def emit_error_envelope(error)
        @output.puts JSON.generate(Hive::Commands::ScreenoteEnvelope.error_payload(error))
      rescue Errno::EPIPE, JSON::GeneratorError
        nil
      end
    end
  end
end
