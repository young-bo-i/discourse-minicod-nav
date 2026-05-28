import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

export default class AdminPluginsMinicodNavController extends Controller {
  @tracked loading = false;
  @tracked dashboard = null;
  @tracked maps = [];
  @tracked receipts = [];

  @action
  async load() {
    this.loading = true;
    try {
      this.dashboard = await ajax("/minicod-nav/admin/dashboard");
      const mapsRes = await ajax("/minicod-nav/admin/maps?page=1&per_page=20");
      this.maps = mapsRes?.data || [];
      const receiptsRes = await ajax("/minicod-nav/admin/receipts?limit=20");
      this.receipts = receiptsRes?.data || [];
    } finally {
      this.loading = false;
    }
  }
}
