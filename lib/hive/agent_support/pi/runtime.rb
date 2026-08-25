require "fileutils"
require "json"
require "pathname"
require "tmpdir"
require "hive/atomic_file"
require "hive/permission_scope"

module Hive::AgentSupport::Pi::Runtime
  SANDBOX_PATH = "/usr/bin/bwrap".freeze
  RUNTIME_MOUNT = "/pi-runtime".freeze
  TOOL_NAMES = {
    "Read" => "read", "LS" => "ls", "Grep" => "grep", "Glob" => "find"
  }.freeze
  NETWORK_TOOLS = %w[WebFetch WebSearch].freeze
  RESOLVE_TIMEOUT_SEC = 30

  def self.compile_evidence_actor(host:, task_folder:, package_root:, profile:, environment:,
                                     mailbox_root:, writable_root:, hive_executable:,
                                     browser: false)
    unless profile.name == :pi
      raise Hive::ConfigError, "managed Pi evidence runtime requires the Pi agent"
    end
    require_sandbox!("evidence")
    source_root = File.realpath(task_folder)
    task_root = File.realpath(package_root)
    mailbox_root = File.realpath(mailbox_root)
    writable_root = File.realpath(writable_root)
    unless File.directory?(mailbox_root) && File.directory?(writable_root) &&
           writable_root.start_with?(task_root + File::SEPARATOR)
      raise Hive::ConfigError, "managed Pi evidence roots are unavailable or unconfined"
    end

    executable, auth_path = runtime_files(host:, profile:)
    hive_executable = File.realpath(hive_executable)
    hive_root = File.realpath(File.dirname(File.dirname(hive_executable)))
    hive_relative = Pathname.new(hive_executable).relative_path_from(Pathname.new(hive_root)).to_s
    gem_paths = Gem.path.select { |path| File.directory?(path) }.map { |path| File.realpath(path) }
    gem_mounts = gem_paths.reject do |path|
      path == "/usr" || path.start_with?("/usr/")
    end.to_h { |path| [ path, path ] }

    runtime_home = Dir.mktmpdir("hive-managed-pi-evidence-")
    FileUtils.mkdir_p(File.join(runtime_home, ".pi", "agent"), mode: 0o700)
    extension = File.join(runtime_home, "evidence-tools.ts")
    task_relative_write_root = Pathname.new(writable_root)
      .relative_path_from(Pathname.new(task_root)).to_s
    Hive::AtomicFile.write(
      extension,
      evidence_extension(
        source_root: source_root, task_root: task_root,
        writable_root: writable_root,
        task_relative_write_root: task_relative_write_root,
        hive_executable: File.join("/hive-runtime", hive_relative),
        browser: browser
      ),
      mode: 0o600
    )

    tool_names = %w[read ls grep find evidence_write evidence_terminal]
    tool_names << "evidence_browser" if browser
    flags = [
      "--no-builtin-tools", "--no-extensions", "--no-skills",
      "--no-prompt-templates", "--no-context-files",
      "--extension", "/runtime-home/evidence-tools.ts",
      "--tools", tool_names.join(",")
    ]
    evidence_environment = environment.to_h.transform_keys(&:to_s)
    unless evidence_environment.all? do |key, value|
      key.start_with?("HIVE_EVIDENCE_") && value.is_a?(String)
    end
      raise Hive::ConfigError, "managed Pi evidence environment is malformed"
    end
    child_environment = host.actor_environment({}).merge(evidence_environment).merge(
      "HOME" => "/runtime-home",
      "PI_CODING_AGENT_DIR" => "/runtime-home/.pi/agent",
      "GEM_PATH" => gem_paths.join(File::PATH_SEPARATOR),
      "PATH" => "#{RUNTIME_MOUNT}:/usr/bin"
    )
    prefix = bwrap_prefix(
      host: host,
      executable: executable, auth_path: auth_path, runtime_home: runtime_home,
      directories: [ source_root, task_root ], cwd: source_root,
      readonly_mounts: { hive_root => "/hive-runtime", **gem_mounts },
      writable_directories: [ mailbox_root, writable_root ]
    )

    host.policy(
      permission_mode: nil,
      allowed_tools: %w[Read LS Grep Glob].freeze,
      disallowed_tools: %w[Bash Write Edit MultiEdit NotebookEdit WebFetch WebSearch].freeze,
      directories: [ source_root, task_root ].freeze,
      commands: [].freeze, domains: [].freeze, executables: {}.freeze,
      environment: child_environment, settings_path: nil, mcp_config_path: nil,
      policy_path: nil, cli_flags: flags.freeze, permission_flags: [].freeze,
      agent_add_dirs: [].freeze, command_prefix: prefix.freeze,
      executable: File.join(RUNTIME_MOUNT, File.basename(executable)).freeze,
      task_root: source_root.freeze, output_paths: {}.freeze,
      cleanup_paths: [ runtime_home ].freeze
    ).freeze
  rescue StandardError
    FileUtils.remove_entry_secure(runtime_home, true) if runtime_home
    raise
  end

  def self.compile_managed_actor(host:, scope:, task_root:, directories:, profile:, environment:,
                            outputs:, runtime_root:, tool_names:, prepare:)
    unless prepare
      return host.portable_admission_policy(
        scope, task_root:, directories:, environment:
      )
    end
    require_sandbox!("workflow")
    network_tools = tool_names & NETWORK_TOOLS
    unless network_tools.empty?
      raise Hive::ConfigError,
            "runner :pi cannot enforce managed network tools #{network_tools.sort.inspect}"
    end

    executable, auth_path = runtime_files(host:, profile:)

    runtime_home = runtime_root || Dir.mktmpdir("hive-managed-pi-")
    FileUtils.mkdir_p(File.join(runtime_home, ".pi", "agent"), mode: 0o700)
    visible_tools = tool_names - Hive::PermissionScope::FILE_EDIT_TOOLS
    pi_tools = visible_tools.filter_map { |name| TOOL_NAMES[name] }.uniq
    flags = [
      "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files"
    ]
    flags.concat(pi_tools.empty? ? [ "--no-tools" ] : [ "--tools", pi_tools.join(",") ])
    flags.concat([ "--append-system-prompt", host_output_system_prompt(outputs.keys) ]) unless outputs.empty?
    pi_environment = environment.merge(
      "HOME" => "/runtime-home",
      "PI_CODING_AGENT_DIR" => "/runtime-home/.pi/agent",
      "PATH" => "#{RUNTIME_MOUNT}:/usr/bin"
    ).freeze
    prefix = bwrap_prefix(
      host: host,
      executable: executable, auth_path: auth_path, runtime_home: runtime_home,
      directories: directories, cwd: task_root
    )

    host.portable_policy(
      scope, task_root: task_root, directories: directories,
      environment: pi_environment, outputs: outputs, runtime_root: runtime_home,
      cli_flags: flags, executable: File.join(RUNTIME_MOUNT, File.basename(executable)),
      command_prefix: prefix
    )
  end

  def self.host_output_system_prompt(paths)
    keys = paths.sort.map { |path| JSON.generate(path) }.join(", ")
    <<~PROMPT.strip
      Hive host-output mode is active. You cannot write task files directly.
      Your final response MUST be exactly one JSON object and nothing else:
      {"files":{PATH:"complete file contents"}}.
      The files object MUST contain exactly these keys: #{keys}.
      Do not wrap the object in Markdown, prefix it with prose, or say that
      you will write a file. Put the complete requested artifact inside each
      JSON string value and end the turn with that object.
    PROMPT
  end

  def self.executable(host:, profile:)
    configured = host.resolve_profile_executable(profile)
    return configured if runtime_root?(File.dirname(configured))

    mise = host.find_executable("mise")
    raise Hive::ConfigError, "runner :pi reported an unavailable managed executable" unless mise

    stdout, _stderr, status = host.capture3_bounded(
      mise, "which", "pi", timeout_sec: RESOLVE_TIMEOUT_SEC,
      environment: { "MISE_QUIET" => "1" }
    )
    candidate = stdout.to_s.strip
    unless status.success? && File.absolute_path?(candidate) &&
           File.file?(candidate) && File.executable?(candidate) &&
           runtime_root?(File.dirname(candidate))
      raise Hive::ConfigError, "runner :pi reported an unavailable managed executable"
    end
    File.realpath(candidate)
  rescue Timeout::Error
    raise Hive::ConfigError,
          "runner :pi managed executable probe timed out after #{RESOLVE_TIMEOUT_SEC}s"
  rescue Errno::ENOENT, Errno::EACCES
    raise Hive::ConfigError, "runner :pi reported an unavailable managed executable"
  end

  def self.runtime_root?(root)
    File.file?(File.join(root, "theme", "dark.json")) &&
      File.file?(File.join(root, "theme", "light.json"))
  end

  def self.auth_path
    configured = ENV.fetch("PI_CODING_AGENT_DIR", "").to_s
    root = configured.empty? ? File.join(ENV.fetch("HOME", Dir.home), ".pi", "agent") : configured
    File.realpath(File.join(File.expand_path(root), "auth.json"))
  rescue Errno::ENOENT, Errno::EACCES
    File.join(File.expand_path(root || "."), "auth.json")
  end

  def self.require_sandbox!(isolation)
    return if File.file?(SANDBOX_PATH) && File.executable?(SANDBOX_PATH)

    raise Hive::ConfigError, "runner :pi requires bubblewrap for managed #{isolation} isolation"
  end

  def self.runtime_files(host:, profile:)
    executable = executable(host:, profile:)
    auth = auth_path
    raise Hive::ConfigError, "runner :pi managed workflow auth file is unavailable" unless File.file?(auth)

    [ executable, auth ]
  end

  def self.bwrap_prefix(host:, executable:, auth_path:, runtime_home:, directories:, cwd:,
                        readonly_mounts: {}, writable_directories: [])
    parent_dirs = host.sandbox_parent_dirs(
      directories + [ cwd ] + writable_directories + readonly_mounts.values,
      excluded: %w[/tmp /usr /etc /proc /dev /runtime-home]
    )
    prefix = [
      SANDBOX_PATH,
      "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
      "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
      "--ro-bind", "/usr", "/usr",
      "--symlink", "usr/bin", "/bin", "--symlink", "usr/bin", "/sbin",
      "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
      "--ro-bind", File.dirname(executable), RUNTIME_MOUNT,
      "--dir", "/etc", "--ro-bind", "/etc/ssl", "/etc/ssl",
      "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
      "--ro-bind", "/etc/hosts", "/etc/hosts",
      "--bind", runtime_home, "/runtime-home",
      "--ro-bind", auth_path, "/runtime-home/.pi/agent/auth.json"
    ]
    models_path = File.join(File.dirname(auth_path), "models.json")
    prefix.concat([ "--ro-bind", File.realpath(models_path), "/runtime-home/.pi/agent/models.json" ]) if File.file?(models_path)
    prefix.concat(parent_dirs.flat_map { |path| [ "--dir", path ] })
    prefix.concat(directories.uniq.flat_map { |path| [ "--ro-bind", path, path ] })
    prefix.concat(readonly_mounts.flat_map { |host, guest| [ "--dir", guest, "--ro-bind", host, guest ] })
    prefix.concat(writable_directories.uniq.flat_map { |path| [ "--bind", path, path ] })
    prefix.concat([
      "--setenv", "HOME", "/runtime-home",
      "--setenv", "PI_CODING_AGENT_DIR", "/runtime-home/.pi/agent",
      "--setenv", "PATH", "#{RUNTIME_MOUNT}:/usr/bin",
      "--chdir", cwd,
      "--"
    ])
  end

  def self.evidence_extension(source_root:, task_root:, writable_root:,
                                 task_relative_write_root:, hive_executable:, browser:)
    browser_tool = if browser
      <<~TYPESCRIPT
        pi.registerTool(defineTool({
          name: "evidence_browser",
          label: "Capture browser evidence",
          description: "Run one controller-admitted browser capture action.",
          parameters: Type.Object({
            command: Type.String({ minLength: 1, maxLength: 64 }),
            argv: Type.Array(Type.String({ maxLength: 4096 }), { maxItems: 64 })
          }),
          async execute(_id, params, signal) {
            return runHive(["evidence", "browser", params.command, ...params.argv], signal);
          }
        }));
      TYPESCRIPT
    else
      ""
    end

    <<~TYPESCRIPT
      import { Type } from "@earendil-works/pi-ai";
      import {
        createFindTool, createGrepTool, createLsTool, createReadTool,
        defineTool, type ExtensionAPI
      } from "@earendil-works/pi-coding-agent";
      import { realpathSync, writeFileSync } from "node:fs";
      import { isAbsolute, relative, resolve, sep } from "node:path";

      const roots = #{JSON.generate([ source_root, task_root ])};
      const writeRoot = #{JSON.generate(writable_root)};
      const taskRelativeWriteRoot = #{JSON.generate(task_relative_write_root)};
      const hiveExecutable = #{JSON.generate(hive_executable)};

      function confinedPath(raw: unknown): string {
        const candidate = realpathSync(resolve(process.cwd(), typeof raw === "string" ? raw : "."));
        if (!roots.some((root) => candidate === root || candidate.startsWith(root + sep))) {
          throw new Error("read path escapes the frozen source and task roots");
        }
        return candidate;
      }

      function scopedReadTool(tool: any) {
        return {
          ...tool,
          async execute(id: string, params: any, signal: AbortSignal, onUpdate: any, ctx: any) {
            confinedPath(params.path);
            return tool.execute(id, params, signal, onUpdate, ctx);
          }
        };
      }

      function toolText(text: string, details: any = {}) {
        return { content: [{ type: "text" as const, text }], details };
      }

      export default function (pi: ExtensionAPI) {
        const cwd = process.cwd();
        pi.registerTool(scopedReadTool(createReadTool(cwd)));
        pi.registerTool(scopedReadTool(createLsTool(cwd)));
        pi.registerTool(scopedReadTool(createGrepTool(cwd)));
        pi.registerTool(scopedReadTool(createFindTool(cwd)));

        async function runHive(argv: string[], signal: AbortSignal) {
          const result = await pi.exec("/usr/bin/ruby", [hiveExecutable, ...argv], {
            signal, timeout: 70000
          });
          const text = [result.stdout, result.stderr].filter(Boolean).join("\\n").slice(0, 524288);
          if (result.code !== 0) throw new Error(text || `Hive evidence command failed (${result.code})`);
          return toolText(text, { status: result.code });
        }

        pi.registerTool(defineTool({
          name: "evidence_write",
          label: "Write evidence document",
          description: "Write one text, Markdown, or JSON representation under the controller-owned evidence root.",
          parameters: Type.Object({
            name: Type.String({ pattern: "^[a-z][a-z0-9_-]{0,63}\\\\.(txt|md|json)$" }),
            content: Type.String({ minLength: 1, maxLength: 4194304 })
          }),
          async execute(_id, params) {
            if (!/^[a-z][a-z0-9_-]{0,63}\\.(txt|md|json)$/.test(params.name)) {
              throw new Error("evidence filename is invalid");
            }
            const destination = resolve(writeRoot, params.name);
            if (relative(writeRoot, destination).startsWith("..") || isAbsolute(relative(writeRoot, destination))) {
              throw new Error("evidence filename escapes the attempt root");
            }
            if (Buffer.byteLength(params.content, "utf8") > 4194304) {
              throw new Error("evidence document is oversized");
            }
            writeFileSync(destination, params.content, { encoding: "utf8", flag: "wx", mode: 0o600 });
            const mediaType = params.name.endsWith(".md") ? "text/markdown" :
              (params.name.endsWith(".json") ? "application/json" : "text/plain");
            return toolText(JSON.stringify({
              path: `${taskRelativeWriteRoot}/${params.name}`, media_type: mediaType
            }), { path: `${taskRelativeWriteRoot}/${params.name}`, media_type: mediaType });
          }
        }));

        pi.registerTool(defineTool({
          name: "evidence_terminal",
          label: "Capture terminal evidence",
          description: "Record one exact target command through Hive's controller-owned PTY capture boundary. Pass only the target command argv; this tool adds the Hive evidence-terminal prefix.",
          parameters: Type.Object({
            name: Type.String({ pattern: "^[a-z][a-z0-9_-]{0,63}$" }),
            argv: Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), {
              minItems: 1, maxItems: 64
            })
          }),
          async execute(_id, params, signal) {
            return runHive(["evidence", "terminal", params.name, "--json", "--", ...params.argv], signal);
          }
        }));

        #{browser_tool}
      }
    TYPESCRIPT
  end
end
