# frozen_string_literal: true
require 'jenkins_api_client'

module Samson
  class Jenkins
    URL = ENV['JENKINS_URL']
    USERNAME = ENV['JENKINS_USERNAME']
    API_KEY = ENV['JENKINS_API_KEY']
    ERROR_COLUMN_LIMIT = 255
    JENKINS_BUILD_PARAMETRS_PREFIX = "SAMSON_"
    JENKINS_BUILD_PARAMETERS_DEFAULT_VALUE = ""
    JENKINS_JOB_DESC = [
      [
        "#### SAMSON DESCRIPTION STARTS ####",
        "Following text is generated by Samson. Please do not edit manually.",
        "This job is triggered from following Samson projects and stages:"
      ],
      [
        "Build Parameters starting with #{JENKINS_BUILD_PARAMETRS_PREFIX} are updated "\
        "automatically by Samson. Please disable automatic updating"\
        " of this jenkins job from the above mentioned samson projects "\
        "before manually editing build parameters or description.",
        "#### SAMSON DESCRIPTION ENDS ####"
      ]
    ].freeze
    JENKINS_BUILD_PARAMETERS = {
      "buildStartedBy": "Samson username of the person who started the deployment.",
      "originatedFrom": "Samson project + stage + commit hash from github tag",
      "commit": "Github commit hash of the change deployed.",
      "tag": "Github tags of the commit being deployed.",
      "deployUrl": "Samson url which triggered the current job.",
      "emails": "Emails of the committers, buddy and user for current deployment."\
                " Please see samson to exclude the committers email."
    }.freeze
    JENKINS_BUILD_PARAMETERS.with_indifferent_access

    attr_reader :job_name, :deploy

    def self.deployed!(deploy)
      return unless deploy.succeeded?
      deploy.stage.jenkins_job_names.to_s.strip.split(/, ?/).map do |job_name|
        job_id = new(job_name, deploy).build
        attributes = {name: job_name, deploy_id: deploy.id}
        if job_id.is_a?(Integer)
          attributes[:jenkins_job_id] = job_id
        else
          attributes[:status] = "STARTUP_ERROR"
          attributes[:error] = job_id.to_s.slice(0, ERROR_COLUMN_LIMIT)
        end
        JenkinsJob.create!(attributes)
      end
    end

    def initialize(job_name, deploy)
      @job_name = job_name
      @deploy = deploy
    end

    def jenkins_job_config
      conf = Rails.cache.fetch(job_name + "_conf", expires_in: 7.days, race_condition_ttl: 5.minute) do
        conf = client.job.get_config(job_name)
      end
      Nokogiri::XML(conf)
    end

    def configure_job_config
      conf = jenkins_job_config
      post_config = false
      exp_build_params = JENKINS_BUILD_PARAMETERS.keys
      present_build_params = get_build_params(conf).map(&:to_sym)
      missing_build_params = exp_build_params.to_set - present_build_params.to_set
      unless missing_build_params.empty?
        add_build_parameters(conf, missing_build_params)
        post_config = true
      end
      unless check_description(conf)
        add_job_description(conf)
        post_config = true
      end
      if post_config
        post_job_config(conf)
      end
    end

    def get_build_params(conf)
      params = conf.xpath("//parameterDefinitions").first
      params_array = []
      if params
        params.children.each do |param|
          if param.name == "hudson.model.StringParameterDefinition"
            param.children.each do |value|
              if value.name == "name" && value.content.starts_with?(JENKINS_BUILD_PARAMETRS_PREFIX)
                params_array.append(value.content.split(JENKINS_BUILD_PARAMETRS_PREFIX)[1])
              end
            end
          end
        end
      end
      params_array
    end

    def job_names_from_desc(content, idx)
      job_names = []
      while idx < content.size && content[idx] != JENKINS_JOB_DESC[1][-1]
        job_names.append(content[idx]) if content[idx].starts_with?('*')
        idx += 1
      end
      [idx, job_names]
    end

    def add_job_description(conf)
      dstart = JENKINS_JOB_DESC[0].join("\n") + "\n"
      dend = "\n" + JENKINS_JOB_DESC[1].join("\n")
      desc = conf.xpath("//description").first
      prev_content = []
      idx = 0
      job_names = []
      content = desc.content.split("\n").map(&:squish)
      job_name = '* ' + deploy.project.name + ' - ' + deploy.stage.name
      while idx < content.size
        if content[idx] == JENKINS_JOB_DESC[0][0]
          idx, job_names = job_names_from_desc(content, idx)
        else
          prev_content.append(content[idx])
        end
        idx += 1
      end
      unless job_names.include?(job_name)
        job_names.append(job_name)
      end
      desc.content = prev_content.join("\n") + "\n" + dstart + job_names.join("\n") + dend
    end

    def check_description(conf)
      job_name = '* ' + deploy.project.name + ' - ' + deploy.stage.name + "\n"
      desc = conf.xpath("//description").first.content
      desc.include?(JENKINS_JOB_DESC[0][0]) &&
      desc.include?(JENKINS_JOB_DESC[1][-1]) &&
      desc.include?(job_name)
    end

    def add_build_parameters(conf, missing_parameters)
      properties_ele = conf.xpath("//parameterDefinitions").first
      unless properties_ele
        conf.xpath("//properties").first.add_child('<hudson.model.'\
        'ParametersDefinitionProperty><parameterDefinitions></parameter'\
        'Definitions></hudson.model.ParametersDefinitionProperty>')
      end
      properties_ele = conf.xpath("//parameterDefinitions").first
      missing_parameters.each do |name|
        properties_ele.add_child("<hudson.model.StringParameterDefinition>"\
          "<name>%s</name><description>%s</description><defaultValue>%s</defaultValue>"\
          "</hudson.model.StringParameterDefinition>" %
          [
            JENKINS_BUILD_PARAMETRS_PREFIX + name.to_s,
            JENKINS_BUILD_PARAMETERS[name],
            JENKINS_BUILD_PARAMETERS_DEFAULT_VALUE
          ])
      end
    end

    def post_job_config(conf)
      client.job.post_config(job_name, conf.to_xml.to_s)
    end

    def build
      opts = {'build_start_timeout' => 60}
      originated_from = deploy.project.name + '_' + deploy.stage.name + '_' + deploy.reference
      build_params = {
        buildStartedBy: deploy.user.name,
        originatedFrom: originated_from,
        commit: deploy.job.commit,
        tag: deploy.job.tag,
        deployUrl: deploy.url,
        emails: notify_emails
      }
      if deploy.stage.jenkins_autoconfig_buildparams
        configure_job_config
        build_params = build_params.map { |k, v| [JENKINS_BUILD_PARAMETRS_PREFIX + k.to_s, v] }.to_h
      end
      client.job.build(job_name, build_params, opts).to_i
    rescue Timeout::Error => e
      "Jenkins '#{job_name}' build failed to start in a timely manner.  #{e.class} #{e}"
    rescue JenkinsApi::Exceptions::ApiException => e
      "Problem while waiting for '#{job_name}' to start.  #{e.class} #{e}"
    end

    def job_status(jenkins_job_id)
      response(jenkins_job_id)['result']
    end

    def job_url(jenkins_job_id)
      response(jenkins_job_id)['url']
    end

    private

    def response(jenkins_job_id)
      @response ||= begin
        client.job.get_build_details(job_name, jenkins_job_id)
      rescue JenkinsApi::Exceptions::NotFound => error
        { 'result' => error.message, 'url' => '#' }
      end
    end

    def client
      @@client ||= JenkinsApi::Client.new(server_url: URL, username: USERNAME, password: API_KEY).tap do |cli|
        cli.logger = Rails.logger
      end
    end

    def notify_emails
      emails = [deploy.user.email]
      if deploy.buddy
        emails.push(deploy.buddy.email)
      end
      if deploy.stage.jenkins_email_committers
        emails.concat(deploy.changeset.commits.map(&:author_email))
      end
      emails.map! { |x| Mail::Address.new(x) }
      if ENV["GOOGLE_DOMAIN"]
        emails.select! { |x| ("@" + x.domain).casecmp(ENV["GOOGLE_DOMAIN"]).zero? }
      end
      emails.map(&:address).uniq.join(",")
    end
  end
end
