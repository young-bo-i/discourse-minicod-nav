# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class MapsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      def index
        page = params[:page].to_i
        page = 1 if page <= 0
        per_page = params[:per_page].to_i
        per_page = 50 if per_page <= 0
        per_page = 200 if per_page > 200

        scope = ResourceMap.order(last_synced_at: :desc)
        maps = scope.offset((page - 1) * per_page).limit(per_page)
        topic_ids = maps.map(&:topic_id)
        topics_by_id = Topic.unscoped.where(id: topic_ids).index_by(&:id)

        data =
          maps.map do |m|
            topic = topics_by_id[m.topic_id]
            {
              resource_id: m.resource_id,
              topic_id: m.topic_id,
              topic_title: topic&.title,
              topic_deleted: topic.nil? ? true : topic.deleted_at.present?,
              topic_url: topic.nil? ? nil : "/t/#{topic.slug}/#{topic.id}",
              last_synced_version: m.last_synced_version,
              last_synced_at: m.last_synced_at,
            }
          end

        render json: { data: data, total: scope.count, page: page, per_page: per_page }
      end
    end
  end
end
