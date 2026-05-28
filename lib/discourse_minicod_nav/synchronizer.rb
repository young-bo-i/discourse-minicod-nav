# frozen_string_literal: true

module DiscourseMinicodNav
  class SyncError < StandardError
    attr_reader :status

    def initialize(message, status = 400)
      super(message)
      @status = status
    end
  end

  # Applies Resource Station webhook payload (architecture doc shape).
  class Synchronizer
    STATUS_ARCHIVED = 2
    STATUS_DELETED = 3

    EVENT_CREATED = "resource.created"
    EVENT_UPDATED = "resource.updated"
    EVENT_ARCHIVED = "resource.archived"
    EVENT_DELETED = "resource.deleted"
    EVENT_RESTORED = "resource.restored"
    EVENT_TAG_RENAMED = "tag.renamed"
    EVENT_TAG_MERGED = "tag.merged"
    EVENT_TAG_DELETED = "tag.deleted"

    def initialize(bot_user:, default_category_id:, archived_tag:)
      @bot_user = bot_user
      @default_category_id = default_category_id
      @archived_tag = archived_tag
    end

    def self.from_site_settings
      cid = SiteSetting.minicodnav_target_category_id.to_i
      raise SyncError.new("minicodnav_target_category_id must be set (fallback Discourse category)", 503) if cid <= 0

      bot =
        begin
          id = SiteSetting.minicodnav_bot_user_id.to_i
          id.positive? ? (User.find_by(id: id) || Discourse.system_user) : Discourse.system_user
        end

      tag = SiteSetting.minicodnav_archived_tag.presence || "minicodnav-archived"
      new(bot_user: bot, default_category_id: cid, archived_tag: tag)
    end

    def process!(payload)
      event = payload["event"].to_s
      version = payload["version"].to_i

      if event.start_with?("tag.")
        tag = payload["tag"]
        raise SyncError.new("tag missing", 400) unless tag.is_a?(Hash)

        dispatch_tag_event!(event, tag)
        return { ok: true }
      end

      resource = payload["resource"]
      raise SyncError.new("resource missing", 400) unless resource.is_a?(Hash)

      resource_id = resource["id"].to_s
      raise SyncError.new("resource.id missing", 400) if resource_id.blank?

      map = ResourceMap.find_by(resource_id: resource_id)

      if map && version.positive? && version < map.last_synced_version
        return { skipped: true, reason: "older_version" }
      end

      case event
      when EVENT_CREATED, EVENT_UPDATED
        upsert_topic!(resource, map, version, event)
      when EVENT_ARCHIVED
        archive_topic!(map, version)
      when EVENT_DELETED
        delete_topic!(map, version)
      when EVENT_RESTORED
        restore_topic!(resource, map, version)
      else
        raise SyncError.new("unsupported event: #{event}", 400)
      end

      { ok: true }
    end

    private

    def dispatch_tag_event!(event, tag)
      case event
      when EVENT_TAG_RENAMED
        rename_tag!(tag)
      when EVENT_TAG_MERGED
        merge_tag!(tag)
      when EVENT_TAG_DELETED
        delete_tag!(tag)
      else
        raise SyncError.new("unsupported tag event: #{event}", 400)
      end
    end

    def guardian
      @guardian ||= Guardian.new(@bot_user)
    end

    # Prefer discourse_category_id from Resource Station; then route by source_type; then default.
    def discourse_category_id_for(resource)
      payload_cid = resource["discourse_category_id"].to_i
      return payload_cid if payload_cid.positive?

      case resource["source_type"].to_s
      when "pavlovia"
        pav = SiteSetting.minicodnav_pavlovia_category_id.to_i
        return pav if pav.positive?
      when "journal"
        jrn = SiteSetting.minicodnav_journal_category_id.to_i
        return jrn if jrn.positive?
      end

      @default_category_id
    end

    def upsert_topic!(resource, map, version, _event)
      title = resource["title"].to_s
      raw = resource["rendered_markdown"].to_s
      raise SyncError.new("title required", 422) if title.blank?
      raise SyncError.new("rendered_markdown required", 422) if raw.blank?

      tags = normalize_tags(Array(resource["tags"]))
      status = resource["status"].to_i
      target_category_id = discourse_category_id_for(resource)

      if map.nil?
        create_opts = {
          title: title,
          raw: raw,
          category: target_category_id,
          skip_validations: true,
          import_mode: true,
        }
        create_opts[:tags] = tags if tags.present?

        post = PostCreator.create!(@bot_user, create_opts)
        topic = post.topic
        ResourceMap.create!(
          resource_id: resource["id"].to_s,
          topic_id: topic.id,
          post_id: post.id,
          last_synced_version: version,
          last_synced_at: Time.zone.now,
        )
        apply_status_flags!(topic, status)
        return
      end

      topic = Topic.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      if topic.category_id != target_category_id
        topic.update!(category_id: target_category_id)
      end

      first_post = topic.first_post
      raise SyncError.new("first post not found", 422) unless first_post

      revisor = PostRevisor.new(first_post, topic)
      unless revisor.revise!(@bot_user, { raw: raw, title: title }, { skip_validations: true })
        raise SyncError.new(first_post.errors.full_messages.join(", "), 422)
      end

      if tags.present?
        tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, tags)
        raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
      end

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
      apply_status_flags!(topic, status)
      map
    end

    def archive_topic!(map, version)
      # Never synced to Discourse — treat as idempotent success (Outbox may replay
      # archive/delete before a create, or resource was only local).
      return if map.nil?

      topic = Topic.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      topic.update_status(:closed, true, @bot_user)
      tag_ok =
        DiscourseTagging.tag_topic_by_names(topic, guardian, [@archived_tag], append: true)
      raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
    end

    def delete_topic!(map, version)
      return if map.nil?

      topic = Topic.unscoped.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      if topic.deleted_at.blank?
        first_post = topic.first_post
        raise SyncError.new("first post not found", 422) unless first_post

        PostDestroyer.new(@bot_user, first_post).destroy
      end

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
    end

    def restore_topic!(resource, map, version)
      return if map.nil?

      topic = Topic.unscoped.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      topic.recover!(@bot_user) if topic.deleted_at.present?

      topic.update_status(:closed, false, @bot_user) if topic.closed

      names = topic.tags.pluck(:name) - [@archived_tag]
      tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, names)
      raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok

      title = resource["title"].to_s
      raw = resource["rendered_markdown"].to_s
      if title.present? && raw.present?
        first_post = topic.first_post
        raise SyncError.new("first post not found", 422) unless first_post

        revisor = PostRevisor.new(first_post, topic)
        unless revisor.revise!(@bot_user, { raw: raw, title: title }, { skip_validations: true })
          raise SyncError.new(first_post.errors.full_messages.join(", "), 422)
        end
      end

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
    end

    def apply_status_flags!(topic, status)
      case status
      when STATUS_ARCHIVED
        topic.update_status(:closed, true, @bot_user)
        tag_ok =
          DiscourseTagging.tag_topic_by_names(topic, guardian, [@archived_tag], append: true)
        raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
      when STATUS_DELETED
        nil
      end
    end

    def normalize_tags(tags)
      max = SiteSetting.max_tags_per_topic.to_i
      max = 5 if max <= 0
      tags.map(&:to_s).map(&:strip).reject(&:blank?).uniq.take(max)
    end

    def rename_tag!(tag)
      old_name = tag["old_name"].to_s
      new_name = tag["new_name"].to_s
      raise SyncError.new("old_name/new_name required", 400) if old_name.blank? || new_name.blank?
      return if old_name == new_name

      src = Tag.find_by(name: old_name)
      return if src.nil?

      if (dst = Tag.find_by(name: new_name)) && dst.id != src.id
        Topic.joins(:tags).where(tags: { id: src.id }).find_each do |topic|
          names = (topic.tags.pluck(:name) - [old_name] + [new_name]).uniq
          tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, names)
          raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
        end
        src.destroy!
      else
        src.update!(name: new_name)
      end
    end

    def merge_tag!(tag)
      src_name = tag["src_name"].to_s
      dst_name = tag["dst_name"].to_s
      raise SyncError.new("src_name/dst_name required", 400) if src_name.blank? || dst_name.blank?
      return if src_name == dst_name

      src = Tag.find_by(name: src_name)
      return if src.nil?

      dst = Tag.find_or_create_by!(name: dst_name)
      Topic.joins(:tags).where(tags: { id: src.id }).find_each do |topic|
        names = (topic.tags.pluck(:name) - [src_name] + [dst.name]).uniq
        tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, names)
        raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
      end
      src.destroy!
    end

    def delete_tag!(tag)
      name = tag["name"].to_s
      raise SyncError.new("name required", 400) if name.blank?

      src = Tag.find_by(name: name)
      return if src.nil?

      Topic.joins(:tags).where(tags: { id: src.id }).find_each do |topic|
        names = topic.tags.pluck(:name) - [name]
        tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, names)
        raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
      end
      src.destroy!
    end
  end
end
