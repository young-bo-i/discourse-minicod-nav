import Route from "@ember/routing/route";

export default class AdminPluginsAcademicNavRoute extends Route {
  setupController(controller) {
    super.setupController(...arguments);
    controller.load();
  }
}
