# GitHub device-flow sign-in (RFC 8628), reusing Hive::Web::GithubAuth from
# the gem. The flow asks for `repo` scope so the granted token can also list
# and clone the operator's repositories on the Repos page; the token lives
# only in the encrypted Rails session cookie.
class SessionsController < ApplicationController
  skip_before_action :require_login

  # Asking for `repo` (not just read:user) lets the Repos page list and
  # clone private repositories with the operator's own grant.
  DEVICE_SCOPE = "repo".freeze

  # The transport seam tests inject a fake through — the same `http:` DI
  # GithubAuth has carried since the Sinatra tier (no API stubbing).
  class_attribute :http_client, default: Net::HTTP

  def new
    return redirect_to root_path if current_login

    # Surface a misconfigured instance on the page itself — a sign-in button that
    # errors only after the click is a broken first-run.
    @configured = github_auth.configured?
    @claimable = @configured && github_auth.claimable?
  end

  def create
    auth = github_auth
    raise Hive::Error, "GitHub sign-in is not configured: web.github.client_id is empty" unless auth.configured?

    device = auth.start_device_flow(scope: DEVICE_SCOPE)
    now = Time.now.to_i
    session[:github_device] = {
      "device_code" => device["device_code"],
      "user_code" => device["user_code"],
      "verification_uri" => device["verification_uri"],
      "interval" => device["interval"].to_i,
      "expires_at" => now + device["expires_in"].to_i,
      # GitHub requires waiting a full interval before the FIRST poll too.
      "next_poll_at" => now + device["interval"].to_i
    }
    redirect_to auth_github_wait_path
  end

  # The waiting page: shows the user code and refreshes itself every poll
  # interval. Each render performs AT MOST one GitHub poll, gated by
  # `next_poll_at`, so refresh-happy tabs cannot trip GitHub's slow_down.
  def wait
    device = session[:github_device]
    return redirect_to login_path unless device

    now = Time.now.to_i
    if now >= device["expires_at"].to_i
      session.delete(:github_device)
      return render "errors/show", status: :forbidden,
                    locals: { heading: "Sign-in failed", message: "The device code expired. Start again." }
    end

    if now >= device["next_poll_at"].to_i
      result = github_auth.poll_device_flow(device["device_code"])
      case result[:state]
      when :ok
        session.delete(:github_device)
        return admit!(result)
      when :denied
        session.delete(:github_device)
        return render "errors/show", status: :forbidden,
                      locals: { heading: "Sign-in failed", message: "The authorization was denied." }
      when :expired
        session.delete(:github_device)
        return render "errors/show", status: :forbidden,
                      locals: { heading: "Sign-in failed", message: "The device code expired. Start again." }
      when :slow_down
        device["interval"] = result[:interval]
      end
      device["next_poll_at"] = now + device["interval"].to_i
      session[:github_device] = device
    end

    @device = device
  end

  def destroy
    reset_session
    redirect_to login_path
  end

  # Dev/test auth seam — the route only exists in local envs, and the action
  # double-checks so a misconfigured deploy can't expose it.
  def dev_login
    raise ActionController::RoutingError, "Not Found" unless Rails.env.local?

    reset_session
    session[:github_login] = params.fetch(:as)
    session[:github_token] = params[:token] if params[:token].present?
    redirect_to root_path
  end

  private

  def admit!(result)
    login = result[:login]
    unless local_loopback_request?
      claim_ownership!(login) if github_auth.claimable?
      unless github_auth.owner?(login)
        return render "errors/show", status: :forbidden,
                      locals: { heading: "Not allowed", message: "#{login} is not the configured owner." }
      end
    end

    # Rotate the session at the auth boundary; carry the grant into the
    # fresh session so the Repos page can call the GitHub API.
    reset_session
    session[:github_login] = login
    session[:github_token] = result[:token]
    redirect_to root_path
  end

  # First successful login on an ownerless Hive web instance claims it (the install path
  # has no config-editing step). The re-check inside the config lock closes
  # the race where two browsers finish the device flow simultaneously —
  # exactly one login wins; the loser falls through to the owner? 403.
  # Claiming is loud: it is Hive web's single most security-relevant event.
  def claim_ownership!(login)
    claimed = Hive::Config.update_global_config! do |data|
      web = (data["web"] ||= {})
      github = (web["github"] ||= {})
      if github["owner"].to_s.strip.empty?
        github["owner"] = login
        true
      else
        false
      end
    end
    Rails.logger.warn("Hive web CLAIMED by GitHub user #{login.inspect} — web.github.owner written") if claimed
    @github_auth = nil # reload so owner? sees the claim
  end

  def github_auth
    @github_auth ||= Hive::Web::GithubAuth.new(config: Hive::Config.load_global_web, http: http_client)
  end
end
