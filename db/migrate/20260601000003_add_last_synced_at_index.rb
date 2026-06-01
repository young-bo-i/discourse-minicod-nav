# frozen_string_literal: true

class AddLastSyncedAtIndex < ActiveRecord::Migration[7.0]
  def change
    add_index :minicod_nav_resource_maps, :last_synced_at
  end
end
