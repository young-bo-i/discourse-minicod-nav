# frozen_string_literal: true

class AddRawSha1ToMinicodNavResourceMaps < ActiveRecord::Migration[7.0]
  def change
    add_column :minicod_nav_resource_maps, :raw_sha1, :string, limit: 40
  end
end
