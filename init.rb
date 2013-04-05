require 'redmine'

Redmine::Plugin.register :redmine_importer do
  name 'Redmine Issue Importer plugin'
  author 'Martin Liu'
  description 'Issue import plugin for Redmine.'
  version '0.4.0'
  requires_redmine :version_or_higher => '2.0.0'
  url 'https://github.com/ichizok/redmine_importer'

  project_module :importer do
    permission :import, {:importer => [:index, :match, :result]}, :require => :member
  end

  menu :project_menu, :importer, { :controller => 'importer', :action => 'index' }, :caption => :label_import, :after => :new_issue, :param => :project_id
end
