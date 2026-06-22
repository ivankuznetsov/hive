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
        credential = @credential_store.load
        return emit_absent unless credential

        revoked = revoke(credential)
        @credential_store.clear
        emit_disconnected(revoked)
      end

      private

      def ensure_screenote!
        return if @service == "screenote"

        raise Hive::Error, "unsupported disconnect service #{@service.inspect}; expected screenote"
      end

      def revoke(credential)
        token = credential["access_token"].to_s
        return false if token.empty?

        client = @oauth_client_factory.call(credential["base_url"] || Hive::Config.load_global_screenote.fetch("base_url"))
        metadata = client.discover
        client.revoke(token: token, client_id: credential["client_id"], metadata: metadata)
      rescue Hive::Error => e
        warn "[hive] screenote revoke failed; clearing local credential anyway: #{e.message}"
        false
      end

      def emit_absent
        if @json
          @output.puts JSON.generate("ok" => true, "service" => "screenote", "disconnected" => false,
                                     "reason" => "not_connected")
        else
          @output.puts "Screenote is not connected."
        end
      end

      def emit_disconnected(revoked)
        if @json
          @output.puts JSON.generate("ok" => true, "service" => "screenote", "disconnected" => true,
                                     "revoked" => revoked, "credential_path" => @credential_store.path)
        else
          @output.puts "Disconnected Screenote."
        end
      end
    end
  end
end
