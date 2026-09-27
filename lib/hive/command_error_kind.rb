# frozen_string_literal: true

module Hive
  module CommandErrorKind
    module_function

    def typed(error)
      return error.reason if error.is_a?(Hive::CommandOutcomeError)
      return error.reason if error.is_a?(Hive::CommandCapacityError)
      return error.reason if error.is_a?(Hive::CommandIntakeDisabled)

      nil
    end
  end
end
