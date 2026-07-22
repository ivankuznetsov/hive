module Hive
  # Dependency-light validation for branch names crossing Git/worktree and
  # GitHub command boundaries. Callers translate ArgumentError into their
  # domain-specific error type.
  module GitRef
    module_function

    def validate_branch_name(branch_name)
      value = branch_name.to_s.strip
      valid = value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._\/-]{0,240}\z/) &&
              !value.include?("..") && !value.include?("@{") && !value.include?("//") &&
              !value.end_with?("/", ".") &&
              value.split("/").none? do |segment|
                segment.empty? || segment.start_with?(".") || segment.end_with?(".lock")
              end
      raise ArgumentError, "invalid Git branch name #{branch_name.inspect}" unless valid

      value
    end
  end
end
