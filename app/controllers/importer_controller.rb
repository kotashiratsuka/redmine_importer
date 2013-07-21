# -*- coding: utf-8 -*-

class ImporterController < ApplicationController
  unloadable

  before_filter :find_project
  before_filter :authorize,:except => :result

  ISSUE_ATTRS = [
    :id, :subject, :parent_issue, :assigned_to, :fixed_version, :author,
    :description, :category, :priority, :tracker, :status, :start_date,
    :due_date, :done_ratio, :estimated_hours
  ]

  def index
  end

  def match
    # params
    file = params[:file]
    splitter = params[:splitter]
    wrapper = params[:wrapper]
    encoding = params[:encoding]

    if file.nil?
      redirect_to({:action => "index", :project_id => params[:project_id]}, :notice => l(:label_file_undefined))
      return
    end

    # save import file
    @original_filename = file.original_filename
    tmpfilepath = file.tempfile.path

    session[:importer_tmpfile] = tmpfilepath
    session[:importer_splitter] = splitter
    session[:importer_wrapper] = wrapper
    session[:importer_encoding] = encoding

    # display sample
    sample_count = 5
    @samples = []

    begin
      CSV.open(tmpfilepath, {:headers => true, :encoding => encoding, :quote_char => wrapper, :col_sep => splitter}) do |csv|
        sample_count.times do
          row = csv.shift
          @samples << row if row
        end
        @headers = csv.headers
      end # do
    rescue => err
      redirect_to({:action => "index", :project_id => params[:project_id]}, :notice => "Failed to read file (#{err.message})")
      return
    end

    @headers.each do |h|
      if h.blank?
        redirect_to({:action => "index", :project_id => params[:project_id]}, :notice => l(:label_header_blank))
        return
      end
    end

    # fields
    @attrs = []

    ISSUE_ATTRS.each do |attr|
      @attrs.push([l("field_#{attr}".to_sym), attr])
    end

    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end

    @attrs.sort!
  end

  def result
    tmpfilepath = session[:importer_tmpfile]
    splitter = session[:importer_splitter]
    wrapper = session[:importer_wrapper]
    encoding = session[:importer_encoding]

    if !File.exist?(tmpfilepath)
      redirect_to({:action => "index", :project_id => params[:project_id]}, :notice => "Missing imported file")
      return
    end

    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    ignore_non_exist = params[:ignore_non_exist]
    fields_map = params[:fields_map].inject({}) do |h, (k, v)|
      h[k.dup.force_encoding('UTF-8')] = v; h
    end
    unique_attr = fields_map[unique_field]
    add_categories = params[:add_categories]

    # check params
    if update_issue && unique_attr.nil?
      redirect_to({:action => "index", :project_id => params[:project_id]}, :notice => "Unique field hasn't match an issue's field")
      return
    end

    @handle_count = 0
    @update_count = 0
    @failed_count = 0
    @failed_issues = {}
    @affect_projects_issues = Hash.new(0)

    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert

    CSV.open(tmpfilepath, {:headers => true, :encoding => encoding, :quote_char => wrapper, :col_sep => splitter}) do |csv|
      csv.each do |row|

        project = Project.find_by_name(row[attrs_map["project"]])
        tracker = Tracker.find_by_name(row[attrs_map["tracker"]])
        status = IssueStatus.find_by_name(row[attrs_map["status"]])
        author = User.find_by_login(row[attrs_map["author"]])
        priority = Enumeration.find_by_name(row[attrs_map["priority"]])
        category_name = row[attrs_map["category"]]
        category = IssueCategory.find_by_name(category_name)
        assigned_to = User.find_by_login(row[attrs_map["assigned_to"]])

        # new issue or find exists one
        issue = Issue.new
        journal = nil
        issue.project_id = project ? project.id : @project.id
        issue.tracker_id = tracker ? tracker.id : default_tracker
        issue.author_id = author && author.class.name != "AnonymousUser" ? author.id : User.current.id
        fixed_version = Version.find_by_name_and_project_id(row[attrs_map["fixed_version"]], issue.project_id)

        if update_issue
          # custom field
          if !ISSUE_ATTRS.include?(unique_attr.to_sym)
            issue.available_custom_fields.each do |cf|
              if cf.name == unique_attr
                unique_attr = "cf_#{cf.id}"
                break
              end
            end
          end

          if unique_attr == "id"
            issues = [Issue.find_by_id(row[unique_field])]
          else
            query = Query.new(:name => "_importer", :project => @project)
            query.add_filter("status_id", "*", [1])
            query.add_filter(unique_attr, "=", [row[unique_field]])

            issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
          end

          if issues.size > 1
            flash[:warning] = "Unique field #{unique_field} has duplicate record"
            @failed_issues[@handle_count + 1] = row
            break
          else
            if issues.size > 0
              # found issue
              issue = issues.first

              # ignore other project's issue or not
              next if issue.project_id != @project.id && !update_other_project

              # ignore closed issue except reopen
              next if issue.status.is_closed? && (status.nil? || status.is_closed?)

              # init journal
              note = row[journal_field] || ''
              journal = issue.init_journal(author || User.current, note || '')

              @update_count += 1
            else
              # ignore none exist issues
              next if ignore_non_exist
            end
          end
        end

        # project affect
        project = Project.find_by_id(issue.project_id) if project.nil?
        if !project
          project = @project
        end

        @affect_projects_issues[project.name] += 1

        # required attributes
        issue.status_id = status ? status.id : issue.status_id
        issue.priority_id = priority ? priority.id : issue.priority_id
        issue.subject = row[attrs_map["subject"]] || issue.subject

        # optional attributes
        issue.parent_issue_id = row[attrs_map["parent_issue"]] || issue.parent_issue_id
        issue.description = row[attrs_map["description"]] || issue.description
        issue.category_id = category ? category.id : issue.category_id
        if (!category) && category_name && category_name.length > 0 && add_categories
          category = project.issue_categories.build(:name => category_name)
          category.save
        end
        issue.start_date = row[attrs_map["start_date"]] || issue.start_date
        issue.due_date = row[attrs_map["due_date"]] || issue.due_date
        issue.assigned_to_id = assigned_to && assigned_to.class.name != "AnonymousUser"? assigned_to.id : issue.assigned_to_id
        issue.fixed_version_id = fixed_version ? fixed_version.id : issue.fixed_version_id
        issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
        issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

        # custom fields
        issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, cf|
          value = row[attrs_map[cf.name]]
          h[cf.id] = value if value; h
        end

        @failed_issues[@handle_count + 1] = row if !issue.save

        @handle_count += 1
      end

      @headers = csv.headers
    end # do

    @failed_count = @failed_issues.count
  end

  private

  def find_project
    begin
      @project = Project.find(params[:project_id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end
  end

end
