require "json"
require "hive/config"
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
        credential = load_credential
        # File genuinely absent → idempotent no-op. A present-but-corrupt
        # file returns nil from load_credential AND must still be cleared,
        # so it falls through to the clear path below.
        return emit_absent if credential.nil? && !@credential_store.present?

        revoked, reason = credential ? revoke(credential) : [ false, "unreadable_credential" ]
        @credential_store.clear
        emit_disconnected(revoked, reason)
      end

      private

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

      # Returns [revoked, reason]. `reason` is nil on success and a short
      # string otherwise, so a `--json` consumer can distinguish
      # already-revoked / unreachable / no-token instead of just seeing
      # `revoked: false`.
      def revoke(credential)
        token = credential["access_token"].to_s
        return [ false, "no_token" ] if token.empty?

        client = @oauth_client_factory.call(credential["base_url"] || Hive::Config.load_global_screenote.fetch("base_url"))
        metadata = client.discover
        client.revoke(token: token, client_id: credential["client_id"], metadata: metadata)
        [ true, nil ]
      rescue StandardError => e
        # Broaden beyond Hive::Error: an unmapped transport failure (TLS /
        # OS-level timeout) from discover/revoke must NOT escape before
        # `clear` runs — that would crash disconnect AND leave the stale
        # local credential, the opposite of the documented fail-soft.
        warn "[hive] screenote revoke failed; clearing local credential anyway: #{e.message}"
        [ false, e.message ]
      end

      def emit_absent
        if @json
          @output.puts JSON.generate("ok" => true, "service" => "screenote", "disconnected" => false,
                                     "reason" => "not_connected")
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
    end
  end
end
