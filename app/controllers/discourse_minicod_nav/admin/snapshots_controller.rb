# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class SnapshotsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      def sync
        source = params[:source].to_s
        unless SnapshotFetcher::SOURCES.include?(source)
          return render json: { error: "unknown source" }, status: 400
        end

        result = SnapshotFetcher.new(source: source).call
        render json: result
      rescue SnapshotFetcher::FetchError => e
        render json: { error: e.message }, status: 503
      end
    end
  end
end
