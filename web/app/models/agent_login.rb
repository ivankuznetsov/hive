require "hive/web/agents_auth"

# Request-local Rails resource around the process-wide PTY login relay. The
# adapter owns child/session concurrency; this object exposes one immutable
# render snapshot so controllers and views do not reach into its session map.
class AgentLogin
  AUTH_MUTEX = Mutex.new

  class << self
    def create!(agent, auth: self.auth)
      new(session: auth.start(agent), auth:)
    end

    def find!(id, agent: nil, auth: self.auth)
      session = auth.session(id)
      unless session && (agent.nil? || session.agent.to_s == agent.to_s)
        raise Hive::InvalidTaskPath, "unknown login session"
      end

      new(session:, auth:)
    end

    def statuses(auth: self.auth)
      auth.statuses
    end

    def write_pi_token!(token_json, auth: self.auth)
      auth.write_pi_token(token_json)
    end

    def auth
      return @auth if @auth

      AUTH_MUTEX.synchronize { @auth ||= Hive::Web::AgentsAuth.new }
    end

    def reset_auth!
      AUTH_MUTEX.synchronize { @auth = nil }
    end
  end

  attr_reader :id, :agent, :output, :url, :error

  def initialize(session:, auth:)
    @auth = auth
    @id = session.id
    @agent = session.agent
    @output = auth.output_for(id)
    @url = auth.url_for(id)
    @done = session.done == true
    @error = session.error
    @operator_ward = auth.poll_login?(agent)
  end

  def done?
    @done
  end

  def operator_ward?
    @operator_ward
  end

  def polling?
    !done? && (url.nil? || operator_ward?)
  end

  def complete!(code)
    @auth.complete(id, code)
    self
  end
end
