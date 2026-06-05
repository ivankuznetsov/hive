module Hive
  module Bot
    # Shared rendering for the voice/idea capture surface. The supervisor and
    # the slash/callback handlers each used to carry byte-identical copies of
    # these helpers, which drift the moment a wording or callback-data change
    # lands in only one copy. Single source of truth lives here.
    module IdeaKeyboards
      module_function

      def transcript_preview_text(text)
        "Transcript:\n\n#{text}\n\nConfirm or send corrected text / a new voice note."
      end

      def voice_confirm_keyboard(token)
        [
          [ { text: "Confirm", callback_data: "idea_voice_confirm:#{token}" },
            { text: "Discard", callback_data: "idea_voice_discard:#{token}" } ]
        ]
      end

      # `last_project` is the resolved project name (or nil) to star and sort
      # to the top; callers pass the value, not the lambda that produces it.
      def project_keyboard(projects, token, last_project: nil)
        sorted = projects.sort_by { |project| project["name"] == last_project ? 0 : 1 }
        rows = sorted.map do |project|
          label = project["name"] == last_project ? "★ #{project['name']}" : project["name"]
          [ { text: label, callback_data: "idea_project:#{project['name']}:#{token}" } ]
        end
        rows << [ { text: "+ new project", callback_data: "idea_project_new:#{token}" } ]
        rows
      end
    end
  end
end
