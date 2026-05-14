module Hive
  module Bot
    module Handlers
      class CallbackHandlers
        def initialize(pending_ideas:, set_last_project:, result_class:)
          @pending_ideas = pending_ideas
          @set_last_project = set_last_project
          @result_class = result_class
        end

        def handle(intent, update)
          data = update.callback_data.to_s
          case intent
          when :callback_approve then approve(data)
          when :callback_reject then @result_class.new(action: :reply, text: "Left unchanged.")
          when :callback_clear_and_retry then clear_and_retry(data)
          when :callback_open_laptop then @result_class.new(action: :reply, text: "Open laptop for this one.")
          when :callback_show_details then @result_class.new(action: :reply, text: "Details are available from /queue.")
          when :callback_idea_project_pick then idea_project(data)
          when :callback_path_a_yes then path_a(data)
          when :callback_path_a_just_type then path_b(data)
          when :callback_codex_write_draft then codex_write(data)
          when :callback_codex_edit then @result_class.new(action: :reply, text: "Send the edited answer as a message.")
          when :callback_codex_cancel then @result_class.new(action: :reply, text: "Draft cancelled.")
          when :callback_findings_accept_all then findings_toggle(data, "accept-finding")
          when :callback_findings_reject_all then findings_toggle(data, "reject-finding")
          else @result_class.new(action: :reply, text: "Bot got confused - please retry from /queue.")
          end
        rescue ArgumentError
          @result_class.new(action: :reply, text: "Bot got confused - please retry from /queue.")
        end

        private

        def approve(data)
          _prefix, verb, project, slug, stage = split_callback(data, 5)
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", verb, slug, "--from", stage, "--project", project, "--json" ]
          )
        end

        def clear_and_retry(data)
          _prefix, project, slug, stage, marker = split_callback(data, 5)
          verb = retry_verb_for_stage(stage)
          commands = [
            [ "hive", "markers", "clear", slug, "--name", marker.upcase, "--project", project, "--json" ]
          ]
          commands << [ "hive", verb, slug, "--from", stage, "--project", project, "--json" ] if verb
          @result_class.new(action: :dispatch_commands, project: project, slug: slug, commands: commands)
        end

        def idea_project(data)
          _prefix, project, token = split_callback(data, 3)
          idea_text = @pending_ideas.delete(token)
          return @result_class.new(action: :reply, text: "That idea picker expired. Send /idea <text> again.") unless idea_text

          @set_last_project.call(project)
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            command_argv: [ "hive", "new", project, idea_text ]
          )
        end

        def path_a(data)
          _prefix, project, slug = split_callback(data, 3)
          @result_class.new(action: :start_codex, project: project, slug: slug, mode: :path_a)
        end

        def path_b(data)
          _prefix, project, slug = split_callback(data, 3)
          @result_class.new(action: :reply, project: project, slug: slug,
                            text: "Send the answer as a message.")
        end

        def codex_write(data)
          _prefix, project, slug, question_n = split_callback(data, 4)
          @result_class.new(action: :confirm_codex_draft, project: project, slug: slug,
                            question_n: Integer(question_n))
        end

        def findings_toggle(data, verb)
          _prefix, _kind, project, slug, stage = split_callback(data, 5)
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", verb, slug, "--all", "--stage", stage, "--project", project, "--json" ]
          )
        end

        def retry_verb_for_stage(stage)
          {
            "4-execute" => "develop",
            "5-review" => "review",
            "6-pr" => "pr"
          }[stage]
        end

        def split_callback(data, expected)
          parts = data.split(":", expected)
          raise ArgumentError, "malformed callback" unless parts.length == expected

          parts
        end
      end
    end
  end
end
