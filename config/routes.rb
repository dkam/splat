Rails.application.routes.draw do
  mount ActionCable.server => "/cable"
  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Sentry ingestion endpoint
  namespace :api, defaults: { format: :json } do
    post ":project_id/envelope", to: "envelopes#create"
  end

  # Health check
  get "_health", to: "health#show"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Root - project list
  root "projects#index"

  # Projects and nested resources
  resources :projects, param: :slug do
    resources :issues, only: [:index, :show] do
      member do
        patch :resolve
        patch :ignore
        patch :reopen
      end
    end

    resources :events, only: [:index, :show, :destroy]

    resources :transactions, only: [:index, :show] do
      collection do
        get :slow
        get :by_endpoint
      end
    end
  end
  
  # MCP (Model Context Protocol) endpoint
 namespace :mcp, defaults: {format: "json"} do
   match "/", to: "mcp#handle_mcp_request", via: [:get, :post, :put, :patch, :delete, :head, :options]
 end
end
