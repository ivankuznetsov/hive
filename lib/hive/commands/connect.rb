require "json"
require "securerandom"
require "time"
require "hive/config"
require "hive/screenote/credential_store"
require "hive/screenote/loopback_server"
require "hive/screenote/mcp_client"
require "hive/screenote/oauth_client"
require "hive/screenote/pkce"

module Hive
  module Commands
    class Connect
      def initialize(service, base_url: nil, json: false, output: $stdout, input: $stdin,
                     credential_store: Hive::Screenote::CredentialStore.new,
                     oauth_client_factory: nil, loopback_factory: nil, mcp_client_factory: nil,
                     browser_opener: nil, project_picker: nil, clock: nil)
        @service = service.to_s
        @base_url = base_url
        @json = json
        @output = output
        @input = input
        @credential_store = credential_store
        @oauth_client_factory = oauth_client_factory || ->(url) { Hive::Screenote::OAuthClient.new(base_url: url) }
        @loopback_factory = loopback_factory || -> { Hive::Screenote::LoopbackServer.new }
        @mcp_client_factory = mcp_client_factory || lambda { |resource:, access_token:|
          Hive::Screenote::McpClient.new(resource: resource, access_token: access_token)
        }
        @browser_opener = browser_opener || ->(url) { self.class.open_browser(url) }
        @project_picker = project_picker
        @clock = clock || -> { Time.now }
      end

      def call
        ensure_screenote!
        base_url = resolved_base_url
        existing = load_existing_credential
        oauth = @oauth_client_factory.call(base_url)
        metadata = oauth.discover
        loopback = @loopback_factory.call
        redirect_uri = loopback.redirect_uri
        client_id = existing["client_id"].to_s
        client_id = oauth.register(redirect_uri, metadata: metadata)["client_id"] if client_id.empty?

        verifier = Hive::Screenote::PKCE.verifier
        state = SecureRandom.hex(16)
        authorize_url = oauth.authorize_url(
          metadata: metadata,
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: Hive::Screenote::PKCE.challenge(verifier),
          state: state
        )
        show_authorize_url(authorize_url)
        callback = loopback.wait_for_callback(expected_state: state)
        token = oauth.exchange_code(
          code: callback.fetch("code"),
          verifier: verifier,
          redirect_uri: redirect_uri,
          client_id: client_id,
          metadata: metadata
        )
        projects = @mcp_client_factory.call(resource: metadata.mcp_resource, access_token: token.fetch("access_token")).list_projects
        project = choose_project(projects)
        credential = credential_payload(token, metadata: metadata, client_id: client_id,
                                        project: project, base_url: base_url)
        @credential_store.save(credential)
        emit_success(credential, project)
      end

      def self.open_browser(url)
        browser = ENV["BROWSER"].to_s.strip
        return system(browser, url, out: File::NULL, err: File::NULL) unless browser.empty?

        system("xdg-open", url, out: File::NULL, err: File::NULL)
      end

      private

      def ensure_screenote!
        return if @service == "screenote"

        raise Hive::Error, "unsupported connect service #{@service.inspect}; expected screenote"
      end

      # A corrupt local screenote.json must not wedge `connect` (which would
      # otherwise leave the operator unable to re-authorize via the CLI).
      # Treat an unreadable file as "no existing credential": connect
      # re-runs the full OAuth flow and `save` overwrites the bad file.
      def load_existing_credential
        @credential_store.load || {}
      rescue Hive::ConfigError => e
        warn "[hive] ignoring unreadable screenote credential (re-authorizing): #{e.message}"
        {}
      end

      def resolved_base_url
        configured = @base_url.to_s.strip
        return configured unless configured.empty?

        Hive::Config.load_global_screenote.fetch("base_url")
      end

      def show_authorize_url(url)
        opened = @browser_opener.call(url)
        if @json
          # Emit the authorize URL as a structured line BEFORE blocking on
          # the loopback callback, so an operator/automation whose browser
          # failed to auto-open still has the fallback URL under --json.
          @output.puts JSON.generate(
            "ok" => true, "service" => "screenote", "stage" => "authorize",
            "authorize_url" => url, "browser_opened" => !opened.nil? && opened != false
          )
          return
        end
        @output.puts "Opening Screenote authorization in your browser..." if opened
        @output.puts "Open this URL to connect Screenote:\n#{url}"
      end

      def choose_project(projects)
        raise Hive::Error, "Screenote returned no projects; create a project in Screenote and reconnect" if projects.empty?

        selected = @project_picker ? @project_picker.call(projects) : prompt_for_project(projects)
        project = selected.is_a?(Hash) ? selected : projects.find { |candidate| project_id(candidate) == selected.to_s }
        raise Hive::Error, "Screenote project selection is required" unless project

        project
      end

      def prompt_for_project(projects)
        @output.puts "Select a default Screenote project:"
        projects.each_with_index do |project, index|
          @output.puts "#{index + 1}. #{project_label(project)}"
        end
        @output.print "Project number: "
        answer = @input.gets.to_s.strip
        return nil if answer.empty?

        return answer unless answer.match?(/\A\d+\z/)

        # Reject out-of-range numbers (including "0") before indexing.
        # `projects[answer.to_i - 1]` made "0" → projects[-1], silently
        # connecting the LAST project — a typo/cancel became a wrong
        # default. nil falls through to "selection is required".
        index = answer.to_i
        return nil unless index.between?(1, projects.size)

        projects[index - 1]
      end

      def credential_payload(token, metadata:, client_id:, project:, base_url:)
        expires_at = token["expires_at"] || computed_expires_at(token)
        credential = {
          "access_token" => token.fetch("access_token"),
          "expires_at" => expires_at,
          "token_type" => token["token_type"] || "Bearer",
          "scope" => token["scope"] || Hive::Screenote::OAuthClient::SCOPE,
          "client_id" => client_id,
          "issuer" => metadata.issuer,
          "project_id" => project_id(project),
          "base_url" => base_url,
          "mcp_resource" => metadata.mcp_resource
        }
        credential["refresh_token"] = token["refresh_token"] if token["refresh_token"]
        credential
      end

      # Derive expires_at from expires_in when the endpoint omits the
      # absolute timestamp. A non-conformant token response that supplies
      # neither used to crash `connect` with a bare KeyError from
      # `token.fetch("expires_in")`; raise a typed Hive::Error instead.
      def computed_expires_at(token)
        expires_in = token["expires_in"]
        if expires_in.nil?
          raise Hive::Error, "Screenote token response omitted both expires_at and expires_in"
        end

        (@clock.call + expires_in.to_i).utc.iso8601
      end

      def emit_success(credential, project)
        if @json
          @output.puts JSON.generate(
            "ok" => true,
            "service" => "screenote",
            "base_url" => credential.fetch("base_url"),
            "issuer" => credential.fetch("issuer"),
            "client_id" => credential.fetch("client_id"),
            "project_id" => credential.fetch("project_id"),
            "credential_path" => @credential_store.path
          )
        else
          @output.puts "Connected Screenote project #{project_label(project)}."
        end
      end

      def project_id(project)
        id = project["id"].to_s
        id.empty? ? project["project_id"].to_s : id
      end

      def project_label(project)
        name = project["name"].to_s.empty? ? "Unnamed project" : project["name"].to_s
        "#{name} (#{project_id(project)})"
      end
    end
  end
end
