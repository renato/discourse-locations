# frozen_string_literal: true
# name: discourse-locations
# about: Tools for handling locations in Discourse
# version: 6.5.3
# authors: Angus McLeod, Robert Barrow
# contact_emails: development@pavilion.tech
# url: https://github.com/angusmcleod/discourse-locations

enabled_site_setting :location_enabled

register_asset 'stylesheets/common/locations.scss'
register_asset 'stylesheets/desktop/locations.scss', :desktop
register_asset 'stylesheets/mobile/locations.scss', :mobile
register_asset 'lib/leaflet/leaflet.css'
register_asset 'lib/leaflet/leaflet.js'
register_asset 'lib/leaflet/leaflet.markercluster.js'
register_asset 'lib/leaflet/MarkerCluster.css'
register_asset 'lib/leaflet/MarkerCluster.Default.css'

Discourse.top_menu_items.push(:map)
Discourse.anonymous_top_menu_items.push(:map)
Discourse.filters.push(:map)
Discourse.anonymous_filters.push(:map)

gem 'geocoder', '1.8.2'

load File.expand_path('../app/models/location_country_default_site_setting.rb', __FILE__)
load File.expand_path('../app/models/location_geocoding_language_site_setting.rb', __FILE__)
load File.expand_path('../app/models/user_location.rb', __FILE__)
load File.expand_path('../app/models/topic_location.rb', __FILE__)
load File.expand_path('../lib/user_location_process.rb', __FILE__)
load File.expand_path('../lib/topic_location_process.rb', __FILE__)

if respond_to?(:register_svg_icon)
  register_svg_icon "far-map"
  register_svg_icon "info"
  register_svg_icon "expand"
end

after_initialize do
  Category.register_custom_field_type('location', :json)
  Category.register_custom_field_type('location_enabled', :boolean)
  Category.register_custom_field_type('location_topic_status', :boolean)
  Category.register_custom_field_type('location_map_filter_closed', :boolean)

  add_to_class(:category, :location) do
    if self.custom_fields['location']
      if self.custom_fields['location'].is_a?(String)
        begin
          JSON.parse(self.custom_fields['location'])
        rescue JSON::ParserError => e
          puts e.message
        end
      elsif self.custom_fields['location'].is_a?(Hash)
        self.custom_fields['location']
      else
        nil
      end
    else
      nil
    end
  end

  module LocationsSiteSettingExtension
    def type_hash(name)
      if name == :top_menu
        @choices[name].push("map") if @choices[name].exclude?("map")
      end
      super(name)
    end
  end

  require_dependency 'site_settings/type_supervisor'
  class SiteSettings::TypeSupervisor
    prepend LocationsSiteSettingExtension
  end

  [
    "location",
    "location_enabled",
    "location_topic_status",
    "location_map_filter_closed"
  ].each do |key|
    Site.preloaded_category_custom_fields << key if Site.respond_to? :preloaded_category_custom_fields
  end

  Topic.register_custom_field_type('location', :json)
  Topic.register_custom_field_type('has_geo_location', :boolean)
  add_to_class(:topic, :location) { self.custom_fields['location'] }

  add_to_serializer(:topic_view, :location, include_condition: -> { object.topic.location.present? }) do
    object.topic.location
  end

  TopicList.preloaded_custom_fields << 'location' if TopicList.respond_to? :preloaded_custom_fields
  add_to_serializer(:topic_list_item, :location, include_condition: -> { object.location.present? }) do
    object.location
  end

  User.register_custom_field_type('geo_location', :json)
  register_editable_user_custom_field [:geo_location,  geo_location: {}] if defined? register_editable_user_custom_field
  add_to_serializer(:user, :geo_location, respect_plugin_enabled: false) do
    object.custom_fields['geo_location']
  end
  add_to_serializer(
    :user_card,
    :geo_location,
    include_condition: -> do
      object.custom_fields['geo_location'].present? && object.custom_fields['geo_location'] != "{}"
    end,
  ) do
    object.custom_fields['geo_location']
  end

  require_dependency 'directory_item_serializer'
  class ::DirectoryItemSerializer::UserSerializer
    attributes :geo_location

    def geo_location
      object.custom_fields['geo_location']
    end

    def include_geo_location?
      SiteSetting.location_users_map
    end
  end

  public_user_custom_fields = SiteSetting.public_user_custom_fields.split('|')
  public_user_custom_fields.push('geo_location') unless public_user_custom_fields.include?('geo_location')
  SiteSetting.public_user_custom_fields = public_user_custom_fields.join('|')

  PostRevisor.track_topic_field(:location) do |tc, location|
    if location.present? &&
       location = Locations::Helper.parse_location(location.to_unsafe_hash)

      tc.record_change('location', tc.topic.custom_fields['location'], location)
      tc.topic.custom_fields['location'] = location
      tc.topic.custom_fields['has_geo_location'] = location['geo_location'].present?

      Locations::TopicLocationProcess.upsert(tc.topic.id)
    else
      tc.topic.custom_fields['location'] = {}
      tc.topic.custom_fields['has_geo_location'] = false
    end
  end

  DiscourseEvent.on(:post_created) do |post, opts, user|
    if post.is_first_post? &&
       opts[:location].present? &&
       location = Locations::Helper.parse_location(opts[:location])

      topic = post.topic
      topic.custom_fields['location'] = location
      topic.custom_fields['has_geo_location'] = location['geo_location'].present?
      topic.save!
      Locations::TopicLocationProcess.upsert(topic.id)
    end
  end

  require_dependency 'application_controller'
  module ::Locations
    class Engine < ::Rails::Engine
      engine_name 'locations'
      isolate_namespace Locations
    end
  end

  Locations::Engine.routes.draw do
    get 'search' => 'geo#search'
    get 'validate' => 'geo#validate'
    get 'countries' => 'geo#countries'
  end

  Discourse::Application.routes.append do
    mount ::Locations::Engine, at: 'location'
  end

  Discourse::Application.routes.prepend do
    get 'u/user-map' => 'users#index'
    get 'users/user-map' => 'users#index'
    get '/map_feed' => 'list#map_feed'
  end

  load File.expand_path('../serializers/geo_location.rb', __FILE__)
  load File.expand_path('../lib/country.rb', __FILE__)
  load File.expand_path('../lib/geocode.rb', __FILE__)
  load File.expand_path('../lib/locations.rb', __FILE__)
  load File.expand_path('../lib/map.rb', __FILE__)
  load File.expand_path('../lib/users_map.rb', __FILE__)
  load File.expand_path('../controllers/geocode.rb', __FILE__)

  # check latitude and longitude are included when updating users location or raise and error
  register_modifier(:users_controller_update_user_params) do |result, current_user, params|
    if params &&
      params[:custom_fields] &&
      params[:custom_fields][:geo_location] &&
      params[:custom_fields][:geo_location] != "{}" &&
      (!params[:custom_fields][:geo_location]['lat'] ||
       !params[:custom_fields][:geo_location]['lon'])
      raise Discourse::InvalidParameters.new, I18n.t('location.errors.invalid')
    end

    if params &&
      params[:custom_fields] &&
      params[:custom_fields][:geo_location]
      result[:custom_fields][:geo_location] = params[:custom_fields][:geo_location]
    end

    result
  end

  DiscourseEvent.on(:user_updated) do |*params|
    user_id = params[0].id

    if SiteSetting.location_enabled
      Locations::UserLocationProcess.upsert(user_id)
    end
  end

  DiscourseEvent.on(:user_destroyed) do |*params|
    user_id = params[0].id

    Locations::UserLocationProcess.delete(user_id)
  end

  class ::Jobs::AnonymizeUser
    module LocationsEdits
      def make_anonymous
        super
        ::Locations::UserLocationProcess.delete(@user_id)
      end
    end
    prepend LocationsEdits
  end

  unless Rails.env.test?
    begin
      Locations::Geocode.set_config
    rescue
      Locations::Geocode.revert_to_default_provider
    end

    # To be removed
    if SiteSetting.location_geocoding_provider == 'mapzen'
      Locations::Geocode.revert_to_default_provider
    end
  end

  add_model_callback(SiteSetting, :before_save) do
    if name == 'location_geocoding_provider'
      Locations::Geocode.set_config(provider: value)
    end
    if name == 'location_geocoding_timeout'
      Locations::Geocode.set_config(timeout: value)
    end
  end

  add_to_class(:site, :country_codes) do
    @country_codes ||= Locations::Country.codes
  end

  add_to_serializer(:site, :country_codes, respect_plugin_enabled: false) { object.country_codes }

  require_dependency 'topic_query'
  class ::TopicQuery
    def list_map
      @options[:per_page] = SiteSetting.location_map_max_topics
      create_list(:map) do |topics|
        topics = topics.joins("INNER JOIN locations_topic
                               ON locations_topic.topic_id = topics.id")

        Locations::Map.sorted_list_filters.each do |filter|
          topics = filter[:block].call(topics, @options)
        end

        topics
      end
    end
  end

  Locations::Map.add_list_filter do |topics, options|
    if options[:category_id]
      category = Category.find(options[:category_id])
    end

    if SiteSetting.location_map_filter_closed || (options[:category_id] && category.custom_fields['location_map_filter_closed'])
      topics = topics.where(closed: false)
    end

    topics
  end

  DiscourseEvent.trigger(:locations_ready)
end

on(:custom_wizard_ready) do
  if defined?(CustomWizard) == 'constant' && CustomWizard.class == Module
    CustomWizard::Field.register('location', 'discourse-locations')
    CustomWizard::Action.register_callback(:before_create_topic) do |params, wizard, action, submission|
      if action['add_location']
        location = CustomWizard::Mapper.new(
          inputs: action['add_location'],
          data: submission&.fields_and_meta,
          user: wizard.user
        ).perform

        if location.present?
          location = Locations::Helper.parse_location(location)

          location_params = {}
          location_params['location'] = location
          location_params['has_geo_location'] = location['geo_location'].present?

          params[:topic_opts] ||= {}
          params[:topic_opts][:custom_fields] ||= {}
          params[:topic_opts][:custom_fields].merge!(location_params)
        end
      end

      params
    end
  end
end
