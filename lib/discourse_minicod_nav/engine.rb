# frozen_string_literal: true

module DiscourseMinicodNav
  class Engine < ::Rails::Engine
    engine_name "discourse_minicod_nav"
    isolate_namespace DiscourseMinicodNav

    config.root = File.expand_path("../..", __dir__)

    routes do
      post "/webhook/:source" => "webhooks#create"

      namespace :admin do
        get "/dashboard" => "dashboards#show"
        get "/maps" => "maps#index"
        get "/receipts" => "receipts#index"
        post "/snapshot/:source/sync" => "snapshots#sync"
      end
    end
  end
end
