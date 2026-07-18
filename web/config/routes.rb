Rails.application.routes.draw do
  # Container healthcheck — unauthenticated by design; exposes no state.
  get "health" => "health#show"
  get "up" => "rails/health#show", as: :rails_health_check

  # GitHub device-flow sign-in (RFC 8628). Start is a POST (it creates a
  # GitHub device code); the wait page polls the grant.
  # Development/test only: the auth seam Capybara logs in through (and dev
  # smoke-testing uses) without driving real GitHub. Never drawn in
  # production, and the action re-checks the env.
  get "dev_login" => "sessions#dev_login" if Rails.env.local?

  get  "login" => "sessions#new", as: :login
  post "auth/github" => "sessions#create", as: :auth_github
  get  "auth/github/wait" => "sessions#wait", as: :auth_github_wait
  post "logout" => "sessions#destroy", as: :logout

  root "status#index"
  post "daemon/repair" => "daemon#repair", as: :daemon_repair

  post "ideas" => "ideas#create", as: :ideas

  # Task pages are addressed by project name + task slug, mirroring the CLI.
  scope "tasks/:project/:slug", constraints: { slug: /[a-z][a-z0-9-]{0,62}[a-z0-9]/, project: %r{[^/]+} } do
    get  "" => "tasks#show", as: :task
    get  "diff" => "tasks#diff", as: :task_diff
    get  "log" => "tasks#log", as: :task_log
    get  "media/:filename" => "tasks#media", as: :task_media,
         format: false,
         constraints: { filename: /[\w.-]+\.(?:png|jpe?g|gif)/i }
    post "approve" => "tasks#approve", as: :task_approve
    post "reject" => "tasks#reject", as: :task_reject
    post "drop" => "tasks#drop", as: :task_drop
    post "run" => "tasks#run_stage", as: :task_run
    post "recover" => "tasks#recover", as: :task_recover
    post "intervene" => "tasks#intervene", as: :task_intervene
    post "answers" => "tasks#answer", as: :task_answers
  end

  get  "repos" => "repos#index", as: :repos
  get  "repos/new" => "repos#new", as: :new_repo
  post "repos" => "repos#create", as: :create_repo

  get  "agents" => "agents#index", as: :agents
  post "agents/skills/repair" => "agents#repair_skills", as: :agent_skills_repair
  post "agents/:agent/login" => "agents#start_login", as: :agent_login,
       constraints: { agent: /claude|codex|grok|gh/ }
  get  "agents/:agent/login/:session_id" => "agents#login_status", as: :agent_login_status,
       constraints: { agent: /claude|codex|grok|gh/ }
  post "agents/:agent/login/:session_id/complete" => "agents#complete_login", as: :agent_login_complete,
       constraints: { agent: /claude|codex|grok|gh/ }
  post "agents/pi_token" => "agents#save_pi_token", as: :agent_pi_token

  get  "telegram" => "telegram#show", as: :telegram
  post "telegram" => "telegram#update", as: :update_telegram
  post "telegram/test" => "telegram#test", as: :test_telegram
  post "telegram/pairings/:code" => "telegram#approve_pairing", as: :telegram_pairing_approve,
       constraints: { code: /[A-Za-z]{8}/ }
end
