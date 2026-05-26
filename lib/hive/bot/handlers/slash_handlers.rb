require "securerandom"
require "time"

module Hive
  module Bot
    module Handlers
      class SlashHandlers
        def initialize(projects_provider:, pending_ideas:, last_project:, result_class:,
                       now: -> { Time.now })
          @projects_provider = projects_provider
          @pending_ideas = pending_ideas
          @last_project = last_project
          @result_class = result_class
          @now = now
        end

        def status(update)
          rest = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          tokens = rest.split(/\s+/)
          json = !tokens.delete("--json").nil?
          project = tokens.join(" ").strip
          argv = [ "hive", "status", "--json" ]
          argv += [ "--project", project ] unless project.empty?
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: argv,
                            project: project.empty? ? nil : project,
                            format: json ? :json : nil)
        end

        def queue(_update)
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "status", "--json" ])
        end

        def idea(update)
          text = update.text.to_s.sub(%r{\A/idea\b}, "").strip
          return @result_class.new(action: :reply, text: "Use /idea <text> to capture a new idea.") if text.empty?

          projects = @projects_provider.call
          return @result_class.new(action: :reply, text: "No Hive projects are registered yet.") if projects.empty?

          token = SecureRandom.hex(4)
          @pending_ideas[token] = { text: text, created_at: @now.call }
          @result_class.new(
            action: :reply,
            text: "Pick a project for the idea.",
            reply_markup: project_keyboard(projects, token)
          )
        end

        def answer(update, _conversation_store)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /answer <slug>.") if slug.empty?

          @result_class.new(action: :start_answer, slug: slug, mode: :path_b)
        end

        def approve(update)
          slug = update.text.to_s.split(/\s+/, 2)[1].to_s.strip
          return @result_class.new(action: :reply, text: "Use /approve <slug>.") if slug.empty?

          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "approve", slug, "--json" ],
                            slug: slug)
        end

        def done(update, conversation_store)
          pending = conversation_store.pending_confirm_count(chat_id: update.chat_id)
          if pending.positive?
            return @result_class.new(action: :reply,
                                     text: "You still have #{pending} draft answers awaiting confirm.")
          end

          state = conversation_store.get(chat_id: update.chat_id)
          return @result_class.new(action: :reply, text: "No active brainstorm conversation.") unless state

          conversation_store.clear(chat_id: update.chat_id, slug: state.slug)
          @result_class.new(action: :dispatch_then_reply,
                            command_argv: [ "hive", "run", state.slug, "--json" ],
                            slug: state.slug)
        end

        def help(_update)
          @result_class.new(
            action: :reply,
            text: "Commands: /status [project], /queue, /idea <text>, /answer <slug>, /approve <slug>, /done, /help"
          )
        end

        private

        def project_keyboard(projects, token)
          sorted = projects.sort_by { |project| project["name"] == @last_project.call ? 0 : 1 }
          rows = sorted.map do |project|
            label = project["name"] == @last_project.call ? "★ #{project['name']}" : project["name"]
            [ { text: label, callback_data: "idea_project:#{project['name']}:#{token}" } ]
          end
          rows << [ { text: "+ new project", callback_data: "idea_project_new:#{token}" } ]
          rows
        end
      end
    end
  end
end
