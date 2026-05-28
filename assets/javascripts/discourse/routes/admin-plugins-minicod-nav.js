import Route from "@ember/routing/route";

export default class AdminPluginsMinicodNavRoute extends Route {
  setupController(controller) {
    super.setupController(...arguments);
    controller.load();
  }
}
