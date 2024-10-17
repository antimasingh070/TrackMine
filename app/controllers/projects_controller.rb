# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-2023  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class ProjectsController < ApplicationController
  menu_item :overview
  menu_item :settings, :only => :settings
  menu_item :projects, :only => [:index, :new, :copy, :create]

  before_action :find_project,
                :except => [:index, :autocomplete, :list, :new, :create, :copy, :bulk_destroy]
  before_action :authorize,
                :except => [:index, :autocomplete, :list, :new, :create, :copy,
                            :archive, :unarchive,
                            :destroy, :bulk_destroy, :go_live, :hold, :cancelled, :check_member, :update_revised_end_date, :activty_log]
  before_action :authorize_global, :only => [:new, :create]
  before_action :require_admin, :only => [:copy, :archive, :unarchive, :bulk_destroy]
  accept_atom_auth :index
  accept_api_auth :index, :show, :create, :update, :destroy, :archive, :unarchive, :close, :reopen, :go_live, :hold, :cancelled, :check_member, :activty_log, :update_revised_end_date
  require_sudo_mode :destroy, :bulk_destroy

  after_action :create_template_record, only: [:create]
  helper :custom_fields
  helper :issues
  helper :queries
  include QueriesHelper
  helper :projects_queries
  include ProjectsQueriesHelper
  helper :repositories
  helper :members
  helper :trackers

  def create_template_record
    begin 
      template_field = CustomField.find_by(type: "ProjectCustomField", name: "Template")
      return unless template_field

      custom_value = params[:project][:custom_field_values][template_field.id.to_s]
      @project.auto_create_records(custom_value)
    rescue => e
    end
  end

  def activty_logs
    @project = Project.find(params[:id])
    @activty_logs = @project.activty_logs.order(created_at: :desc)
  end

  def update_revised_end_date
    @project = Project.find(params[:id])
  
    if params[:reason].blank?
      flash[:error] = "Reason can't be blank."
      return
    end
  
    new_revised_end_date = params[:revised_end_date]
    custom_field = CustomField.find_by(name: "Revised End Date")
    if new_revised_end_date.present?
      custom_value = CustomValue.find_or_create_by(custom_field: custom_field, customized: @project, value: new_revised_end_date.to_date, author_id: User.current.id)
      custom_value.reason = params[:reason]

      if custom_value.save
        flash[:notice] = "Revised End Date updated successfully!"
      else
        flash[:error] = "Failed to update Revised End Date: #{custom_value.errors.full_messages.join(', ')}"
      end
    end
  end
  
  # Lists visible projects
  def index
    # try to redirect to the requested menu item
    if params[:jump] && redirect_to_menu_item(params[:jump])
      return
    end

    retrieve_default_query
    retrieve_project_query
    scope = project_scope

    respond_to do |format|
      format.html do
        # TODO: see what to do with the board view and pagination
        if @query.display_type == 'board'
          @entries = scope.to_a
        else
          @entry_count = scope.count
          @entry_pages = Paginator.new @entry_count, per_page_option, params['page']
          @entries = scope.offset(@entry_pages.offset).limit(@entry_pages.per_page).to_a
        end
      end
      format.api do
        @offset, @limit = api_offset_and_limit
        @project_count = scope.count
        @projects = scope.offset(@offset).limit(@limit).to_a
      end
      format.atom do
        projects = scope.reorder(:created_on => :desc).limit(Setting.feeds_limit.to_i).to_a
        render_feed(projects, :title => "#{Setting.app_title}: #{l(:label_project_latest)}")
      end
      format.csv do
        # Export all entries
        @entries = scope.to_a
        send_data(query_to_csv(@entries, @query, params), :type => 'text/csv; header=present', :filename => 'projects.csv')
      end
      format.json do
        @projects = scope.offset(@offset).limit(@limit).to_a
      end

    end
  end

  def autocomplete
    respond_to do |format|
      format.js do
        if params[:q].present?
          @projects = Project.visible.like(params[:q]).to_a
        else
          @projects = User.current.projects.to_a
        end
      end
    end
  end

  def new
    @issue_custom_fields = IssueCustomField.sorted.to_a
    @trackers = Tracker.sorted.to_a
    @project = Project.new
    @project.safe_attributes = params[:project]
  end

  def check_member
    if @project.members.blank?
      flash[:notice] = "You have not added members for project manager, program manager & PMO roles"
    else
      required_roles = Role.where(name: ["Project Manager", "Program Manager", "pmo"]).pluck(:id)
      Mailer.deliver_membership_added_email(User.current, @project)
    end
  end
  
  def create
    @issue_custom_fields = IssueCustomField.sorted.to_a
    @trackers = Tracker.sorted.to_a
    @project = Project.new
    @project.safe_attributes = params[:project]
    if !@project.id.nil?
      custom_field = CustomField.find_by(name: "author_id")
      custom_value = CustomValue.find_or_create_by(customized_type: "Project", customized_id: @project&.id, custom_field_id: custom_field&.id)
      custom_value.update(value: (User.current.id).to_s)
    end
    pmo = Role.find_by(name: "PMO")
    if Member.joins(:member_roles).where(project_id: @project.id, member_roles: { role_id: pmo.id }).empty?
    # Assuming user_id for PMO is known, you can replace this with the actual user_id
    pmo_user = User.find_by(login: 'pmo_user_login') # Replace with actual PMO user login or ID
    if pmo_user
      member = Member.create!(project_id: @project.id, user_id: pmo_user.id)
      MemberRole.create!(member_id: member.id, role_id: pmo.id)

      flash[:notice] = "PMO member has been automatically created for this project."
    else
      flash[:error] = "PMO user not found. Please add a member for the PMO role manually."
    end
  end
    # @project.author_id = User.current.id
    @parent = Project.where(id: @project&.parent_id)&.first
    if @project&.id&.nil? && !@project&.parent_id&.nil? && !@parent&.nil?
      new_identifier = "#{Project.where(parent_id: @project.parent_id).count + 1}"
      @project.identifier = "#{@parent.identifier}_#{new_identifier}"
    elsif @project.id.nil? && !@project.parent_id.nil?
      new_identifier = "#{@project.parent_id}_#{Project.where(parent_id: @project.parent_id).count + 1}"
      @project.identifier = "neo_#{new_identifier}"
    else
      @project.identifier = "neo_#{Project.where(parent_id: @project.parent_id).last.id + 1
      }"
    end
    if @project.save
      Mailer.deliver_project_created(User.current, @project)
      unless User.current.admin?
        @project.add_default_member(User.current)
      end
      respond_to do |format|
        format.html do
          flash[:error] = "Please add a member for Program Manager, Project Manager, and PMO roles."
          if params[:continue]
            attrs = {:parent_id => @project.parent_id}.reject {|k,v| v.nil?}
            redirect_to new_project_path(attrs)
          else
            redirect_to "/projects/#{@project.identifier}/settings/members"
          end
        end
        format.api do
          render(
            :action => 'show',
            :status => :created,
            :location => url_for(:controller => 'projects',
                                 :action => 'show', :id => @project.id)
          )
        end
      end
    else
      respond_to do |format|
        format.html {render :action => 'new'}
        format.api  {render_validation_errors(@project)}
      end
    end
  end

  def copy
    @issue_custom_fields = IssueCustomField.sorted.to_a
    @trackers = Tracker.sorted.to_a
    @source_project = Project.find(params[:id])
    if request.get?
      @project = Project.copy_from(@source_project)
      @project.identifier = Project.next_identifier if Setting.sequential_project_identifiers?
    else
      Mailer.with_deliveries(params[:notifications] == '1') do
        @project = Project.new
        @project.safe_attributes = params[:project]
        if @project.copy(@source_project, :only => params[:only])
          flash[:notice] = l(:notice_successful_create)
          redirect_to settings_project_path(@project)
        elsif !@project.new_record?
          # Project was created
          # But some objects were not copied due to validation failures
          # (eg. issues from disabled trackers)
          # TODO: inform about that
          redirect_to settings_project_path(@project)
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    # source_project not found
    render_404
  end

  # Show @project
  def show
    @project = Project.find(params[:id])
    pmo = Role.find_by(name: "PMO")
    project_manager = Role.find_by(name: "Project Manager")
    program_manager = Role.find_by(name: "Program Manager")

    # Fetch all user_ids of members for the project
    user_ids = Member.where(project_id: @project.id).pluck(:user_id)

    # Check if any of the required roles are missing members
    if [project_manager, program_manager].any? do |role|
      Member.joins(:member_roles).where(project_id: @project.id, member_roles: { role_id: role.id }).empty?
    end
      flash[:error] = "Please add a member for Program Manager, Project Manager roles."
      return redirect_to "/projects/#{@project.identifier}/settings/members"
    end
    
    # try to redirect to the requested menu item
    if params[:jump] && redirect_to_project_menu_item(@project, params[:jump])
      return
    end
    
    @revised_end_date_history = @project.revised_end_date_history
    respond_to do |format|
      format.html do
        @principals_by_role = @project.principals_by_role
        @subprojects = @project.children.visible.to_a
        @news = @project.news.limit(5).includes(:author, :project).reorder("#{News.table_name}.created_on DESC").to_a
        with_subprojects = Setting.display_subprojects_issues?
        @trackers = @project.rolled_up_trackers(with_subprojects).visible

        cond = @project.project_condition(with_subprojects)

        @open_issues_by_tracker = Issue.visible.open.where(cond).group(:tracker).count
        @total_issues_by_tracker = Issue.visible.where(cond).group(:tracker).count

        if User.current.allowed_to_view_all_time_entries?(@project)
          @total_hours = TimeEntry.visible.where(cond).sum(:hours).to_f
          @total_estimated_hours = Issue.visible.where(cond).sum(:estimated_hours).to_f
        end

        @key = User.current.atom_key
      end
      format.api
    end
  end

  def settings
    # pmo = Role.find_by(name: "PMO")
    # project_manager = Role.find_by(name: "Project Manager")
    # program_manager = Role.find_by(name: "Program Manager")

    # # Fetch all user_ids of members for the project
    # user_ids = Member.where(project_id: @project.id).pluck(:user_id)

    # # Check if any of the required roles are missing members
    # if [project_manager, program_manager].any? do |role|
    #   Member.joins(:member_roles).where(project_id: @project.id, member_roles: { role_id: role.id }).empty?
    # end
    #   flash[:error] = "Please add members for Program Manager, Project Manager roles."
    # end
    @issue_custom_fields = IssueCustomField.sorted.to_a
    @issue_category ||= IssueCategory.new
    @member ||= @project.members.new
    @trackers = Tracker.sorted.to_a
    @project = Project.find(params[:id])
    @revised_end_date_history = @project.revised_end_date_history
    @version_status = params[:version_status] || 'open'
    @version_name = params[:version_name]
    @versions = @project.shared_versions.status(@version_status).like(@version_name).sorted
  end

  def edit
  end

  def update
    old_custom_field_values = @project.custom_field_values.map { |cfv| [cfv.custom_field_id, cfv.value] }.to_h
    @project.safe_attributes = params[:project]
    @project.status = params[:project][:status] if params[:project][:status].present?
    @parent = Project.where(id: @project.parent_id).first
    # @project.author_id = User.current.id
    parent_id = @project.parent_id
    project_id = @project.id
    if @project.save
      updated_fields = {}
      @project.previous_changes.each do |key, values|
        next if key == 'updated_on' || key == '11'   # Skip the 'updated_on' field
        updated_fields[key] = { before: values[0], after: values[1] }
      end

      custom_field_values = params[:project].delete('custom_field_values') || {}
      custom_field_values.each do |custom_field_id, value|
        custom_field = CustomField.find_by(id: custom_field_id)
        next if custom_field.nil?
        custom_field_name = custom_field.name
        old_value = old_custom_field_values[custom_field_id.to_i]
  
        next if old_value == value  # Skip if the value has not changed

        if custom_field.field_format == 'enumeration'
          if old_value.is_a?(Array)
            old_value_name = old_value.map { |val| CustomFieldEnumeration.find_by(id: val.to_i, custom_field_id: custom_field_id).try(:name) }.compact
            new_value_name = value.map { |val| CustomFieldEnumeration.find_by(id: val.to_i, custom_field_id: custom_field_id).try(:name) }.compact
          else
            old_value_name = CustomFieldEnumeration.find_by(id: old_value.to_i, custom_field_id: custom_field_id).try(:name)
            new_value_name = CustomFieldEnumeration.find_by(id: value.to_i, custom_field_id: custom_field_id).try(:name)  
          end
        elsif custom_field.field_format == 'date' || custom_field.field_format == 'string' || custom_field.field_format == 'bool' || custom_field.field_format == 'int'
          old_value_name = old_value
          new_value_name = CustomValue.find_by(customized_type: "Project", customized_id: @project&.id, custom_field_id: custom_field.id).try(:value)
        else
          old_value_name = old_value
          new_value_name = value
        end
        updated_fields[custom_field_name] = { before: old_value_name, after: new_value_name }
      end
      Mailer.deliver_project_updated(User.current, @project, updated_fields)  
      respond_to do |format|
        format.html do
          flash[:notice] = l(:notice_successful_update)
          redirect_to settings_project_path(@project, params[:tab])
        end
        format.api {render_api_ok}
      end
    else
      respond_to do |format|
        format.html do
          # flash.now[:error] = @project.errors.full_messages.join(", ")
          # settings
          render :action => 'settings'
        end
        format.api {render_validation_errors(@project)}
      end
    end
  end

  def archive
    unless @project.archive
      error = l(:error_can_not_archive_project)
    end
    respond_to do |format|
      format.html do
        flash[:error] = error if error
        redirect_to_referer_or admin_projects_path(:status => params[:status])
      end
      format.api do
        if error
          render_api_errors error
        else
          render_api_ok
        end
      end
    end
  end

  def unarchive
    unless @project.active?
      @project.unarchive
    end
    respond_to do |format|
      format.html{ redirect_to_referer_or admin_projects_path(:status => params[:status]) }
      format.api{ render_api_ok }
    end
  end

  def bookmark
    jump_box = Redmine::ProjectJumpBox.new User.current
    if request.delete?
      jump_box.delete_project_bookmark @project
    elsif request.post?
      jump_box.bookmark_project @project
    end
    respond_to do |format|
      format.js
      format.html {redirect_to project_path(@project)}
    end
  end

  def close
    actual_end_date_field = CustomField.find_by(name: "Actual End Date")
    actual_end_date = @project.custom_value_for(actual_end_date_field).try(:value)

    if actual_end_date.blank?
      flash[:error] = "Actual End Date must be filled in before closing the project."
      redirect_to project_path(@project)
      return
    end
    old_status = @project.status
  
    # Check if there are any issues in the project that are not closed
    open_issues = Issue.where(project_id: @project.id).where.not(status_id: [5,7]) # Assuming status_id: 5 means 'closed'

    if open_issues.exists?
      flash[:error] = "Project cannot be closed. Please close the pending activities"
      redirect_to project_path(@project) and return
    end
  
    @project.close
    Mailer.deliver_project_status(User.current, old_status, @project)
  
    respond_to do |format|
      format.html { redirect_to project_path(@project) }
      format.api { render_api_ok }
    end
  end
  

  def reopen
    old_status = @project.status
    @project.reopen
    new_status = @project.status
    Mailer.deliver_project_status(User.current, old_status, @project)
    respond_to do |format|
      format.html { redirect_to project_path(@project) }
      format.api { render_api_ok }
    end
  end

  def hold
    @old_status = @project.status
    @project.hold
    Mailer.deliver_project_status(User.current, @old_status, @project)
    respond_to do |format|
      format.html { redirect_to project_path(@project) }
      format.api { render_api_hold }
    end
  end

  def go_live
    actual_project_go_live_date = @project.custom_value_for(CustomField.find_by(name: "Actual Project Go Live Date")).try(:value)
    ccb_id = @project.custom_value_for(CustomField.find_by(name: "CCB ID")).try(:value)

    if actual_project_go_live_date.blank? || ccb_id.blank?
      missing_fields = []
      missing_fields << "Actual Project Go Live Date" if actual_project_go_live_date.blank?
      missing_fields << "CCB ID" if ccb_id.blank?
      flash[:error] = "#{missing_fields.join(' and ')} must be filled in before closing the project."
      redirect_to project_path(@project)
      return
    end

    @old_status = @project.status
    @project.go_live
    Mailer.deliver_project_status(User.current, @old_status, @project)
    respond_to do |format|
      format.html { redirect_to project_path(@project) }
      format.api { render_api_go_live }
    end
  end

  def cancelled
    @old_status = @project.status
    @project.cancelled
    Mailer.deliver_project_status(User.current, @old_status, @project)
    respond_to do |format|
      format.html { redirect_to project_path(@project) }
      format.api { render_api_cancelled }
    end
  end


  # Delete @project
  def destroy
    unless @project.deletable?
      deny_access
      return
    end

    @project_to_destroy = @project
    if api_request? || params[:confirm] == @project_to_destroy.identifier
      DestroyProjectJob.schedule(@project_to_destroy)
      flash[:notice] = l(:notice_successful_delete)
      respond_to do |format|
        format.html do
          redirect_to(
            User.current.admin? ? admin_projects_path : projects_path
          )
        end
        format.api  {render_api_ok}
      end
    end
    # hide project in layout
    @project = nil
  end

  # Delete selected projects
  def bulk_destroy
    @projects = Project.where(id: params[:ids]).
      where.not(status: Project::STATUS_SCHEDULED_FOR_DELETION).to_a

    if @projects.empty?
      render_404
      return
    end

    if params[:confirm] == I18n.t(:general_text_Yes)
      DestroyProjectsJob.schedule @projects
      flash[:notice] = l(:notice_successful_delete)
      redirect_to admin_projects_path
    end
  end

  private

  # Returns the ProjectEntry scope for index
  def project_scope(options={})
    @query.results_scope(options)
  end

  def retrieve_project_query
    retrieve_query(ProjectQuery, false, :defaults => @default_columns_names)
  end

  def retrieve_default_query
    return if params[:query_id].present?
    return if api_request?
    return if params[:set_filter]

    if params[:without_default].present?
      params[:set_filter] = 1
      return
    end

    if default_query = ProjectQuery.default
      params[:query_id] = default_query.id
    end
  end
end
