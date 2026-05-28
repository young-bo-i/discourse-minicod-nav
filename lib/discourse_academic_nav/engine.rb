# frozen_string_literal: true

module DiscourseAcademicNav
  class Engine < ::Rails::Engine
    engine_name "discourse_academic_nav"
    isolate_namespace DiscourseAcademicNav

    config.root = File.expand_path("../..", __dir__)

    routes do
      post "/webhook" => "webhooks#create"

      namespace :admin do
        get "/dashboard" => "dashboards#show"
        get "/maps" => "maps#index"
        get "/receipts" => "receipts#index"
      end
    end
  end
end
