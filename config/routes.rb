RedmineApp::Application.routes.draw do
  match 'projects/:project_id/importer', :to => 'importer#index'
  match 'projects/:project_id/importer/:action', :to => 'importer'
end
