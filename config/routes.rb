RedmineApp::Application.routes.draw do
  match 'projects/:project_id/issues/import', :to => 'importer#index'
  match 'projects/:project_id/issues/import/:action', :to => 'importer'
end
