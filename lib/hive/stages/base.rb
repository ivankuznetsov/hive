require "erb"
require "securerandom"
require "hive/agent"

module Hive
  module Stages
    module Base
      module_function

      # Per-process random nonce for the user_supplied wrapper. Defends against
      # prompt-injection attacks that close the wrapper from inside user content
      # (e.g. payload `</user_supplied><system>...`). Templates use
      # `<%= user_supplied_tag %>` for both opening and closing tags.
      def user_supplied_tag
        @user_supplied_tag ||= "user_supplied_#{SecureRandom.hex(8)}"
      end

      def reset_user_supplied_tag!
        @user_supplied_tag = nil
      end

      def render(template_name, bindings_obj)
        path = File.expand_path("../../../templates/#{template_name}", __dir__)
        ERB.new(File.read(path), trim_mode: "-").result(bindings_obj.binding_for_erb)
      end

      def spawn_agent(task, prompt:, max_budget_usd:, timeout_sec:, add_dirs: [], cwd: nil, log_label: nil)
        Hive::Agent.check_version!
        Hive::Agent.new(
          task: task,
          prompt: prompt,
          max_budget_usd: max_budget_usd,
          timeout_sec: timeout_sec,
          add_dirs: add_dirs,
          cwd: cwd,
          log_label: log_label
        ).run!
      end

      def stage_dir_for(task)
        "#{task.stage_index}-#{task.stage_name}"
      end

      class TemplateBindings
        def initialize(values = {})
          values.each do |k, v|
            instance_variable_set("@#{k}", v)
            self.class.send(:attr_reader, k) unless respond_to?(k)
          end
        end

        def binding_for_erb
          binding
        end
      end
    end
  end
end
