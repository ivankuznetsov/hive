# frozen_string_literal: true

module Hive
  module Babysitter
    # Startup and dynamic-loader variables that must not cross the dry-run
    # overlay boundary. The shell overlay, Ruby stubs, and parent environment
    # all consume this one definition so newly discovered loader seams cannot
    # drift between handoff layers.
    module StubEnvironment
      module_function

      RUBY_STARTUP_ENV = %w[
        RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH GEM_HOME GEM_PATH
        BUNDLER_SETUP BUNDLER_VERSION
        BUNDLER_ORIG_RUBYOPT BUNDLER_ORIG_RUBYLIB
        BUNDLER_ORIG_BUNDLE_GEMFILE BUNDLER_ORIG_BUNDLE_BIN_PATH
        BUNDLER_ORIG_GEM_HOME BUNDLER_ORIG_GEM_PATH
        BUNDLER_ORIG_BUNDLER_SETUP BUNDLER_ORIG_BUNDLER_VERSION
      ].freeze
      DYNAMIC_LOADER_ENV = %w[
        LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_BIND_NOT LD_BIND_NOW LD_DEBUG LD_DEBUG_OUTPUT
        LD_DYNAMIC_WEAK LD_HWCAP_MASK LD_ORIGIN_PATH LD_PROFILE LD_SHOW_AUXV
        LD_TRACE_LOADED_OBJECTS LD_USE_LOAD_BIAS LD_VERBOSE LD_WARN
        DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
        DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH
        DYLD_VERSIONED_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH
        DYLD_IMAGE_SUFFIX DYLD_PRINT_TO_FILE
      ].freeze
      DYNAMIC_LOADER_ENV_PATTERN = /\A(?:LD|DYLD)_/.freeze
      STUB_STARTUP_ENV = (RUBY_STARTUP_ENV + DYNAMIC_LOADER_ENV).freeze

      def scrub_dynamic_loader_env!
        ENV.keys.grep(DYNAMIC_LOADER_ENV_PATTERN).each { |key| ENV.delete(key) }
      end
    end
  end
end
