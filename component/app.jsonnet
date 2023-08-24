local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.home_assistant;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('home-assistant', params.namespace.name);

{
  'home-assistant': app,
}
