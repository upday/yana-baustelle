require 'ostruct'
require 'digest'

module Baustelle
  module CloudFormation
    module EBEnvironment
      extend self

      BACKEND_REGEX = %r{^backend\((?<type>[^:]+):(?<name>[^:]+):(?<property>[^:]+)\)$}
      APPLICATION_REF_REGEX = %r{^application\((?<name>[^:]+):(?<property>[^:]+)\)$}

      def apply(template, stack_name:, env_name:, app_ref:, app_name:, vpc:, app_config:,
                stack_configurations:, backends:, env_config:, base_iam_role:,
                chain_after: nil)
        env_hash = eb_env_name(stack_name, app_name, env_name)
        stack = solution_stack(template, app_config.raw.fetch('stack'),
                               stack_configurations: stack_configurations)

        eb_dns = application_dns_endpoint(template, stack_name, env_name, app_name)

        application_config = extrapolate_applications(extrapolate_backends(app_config.config,
                                                                           backends, template),
                                                      stack_name,
                                                      env_name,
                                                      env_config,
                                                      template)

        resource_name = "#{app_name}_env_#{env_name}".camelize

        iam_role = base_iam_role.inherit("#{app_name}_#{env_name}",
                                         extrapolate_backends(app_config.raw.fetch('iam_instance_profile', {}),
                                                              backends, template)).
                   apply(template)

        template.resource resource_name, {
                            Type: "AWS::ElasticBeanstalk::Environment",
                            Properties: {
                              ApplicationName: app_ref,
                              CNAMEPrefix: eb_dns,
                              EnvironmentName: env_hash,
                              SolutionStackName: stack.fetch(:name),
                              Tags: [
                                { 'Key' => 'FQN',         'Value' => "#{app_name}.#{env_name}.#{stack_name}" },
                                { 'Key' => 'Application', 'Value' => app_name },
                                { 'Key' => 'Stack',       'Value' => stack_name },
                                { 'Key' => 'Environment', 'Value' => env_name },
                              ],
                              OptionSettings: {
                                'aws:autoscaling:launchconfiguration' => {
                                  'EC2KeyName' => 'kitchen',
                                  'IamInstanceProfile' => template.ref(iam_role.instance_profile_name),
                                  'InstanceType' => app_config.raw.fetch('instance_type')
                                },
                                'aws:autoscaling:updatepolicy:rollingupdate' => {
                                  'RollingUpdateEnabled' => 'true',
                                  'RollingUpdateType' => 'Health'
                                },
                                'aws:autoscaling:asg' => {
                                  'MinSize' => app_config.raw.fetch('scale').fetch('min'),
                                  'MaxSize' => app_config.raw.fetch('scale').fetch('max')
                                },
                                'aws:ec2:vpc' => {
                                  'VPCId' => vpc.id,
                                  'Subnets' => template.join(',', *vpc.zone_identifier),
                                  'ELBSubnets' => template.join(',', *vpc.zone_identifier),
                                  'AssociatePublicIpAddress' => 'true',
                                  'ELBScheme' => app_config.elb_visibility
                                },
                                'aws:elasticbeanstalk:environment' => {
                                  'ServiceRole' => 'aws-elasticbeanstalk-service-role'
                                },
                                'aws:elasticbeanstalk:application' => {
                                  'Application Healthcheck URL' => '/health'
                                },
                                'aws:elasticbeanstalk:command' => {
                                  'BatchSize' => 50,
                                  'BatchSizeType' => 'Percentage'
                                },
                                'aws:elb:loadbalancer' => {
                                  'CrossZone' => true
                                },
                                'aws:elb:healthcheck' => {
                                  'Interval' => 5,
                                  'Timeout' => 4,
                                  'HealthyThreshold' => 2,
                                  'UnhealthyThreshold' => 2
                                },
                                'aws:elb:policies' => {
                                  'ConnectionDrainingEnabled' => true,
                                  'ConnectionDrainingTimeout' => 10,
                                },
                                'aws:elasticbeanstalk:healthreporting:system' => {
                                  'SystemType' => 'enhanced'
                                },
                                'aws:elasticbeanstalk:application:environment' => application_config
                              }.tap do |settings|
                                if ami = stack.fetch(:ami)
                                  settings['aws:autoscaling:launchconfiguration']['ImageId'] = ami
                                end

                                EBEnvironment.configure_elb_protocol(settings, app_config)
                              end.map do |namespace, options|
                                options.map do |key, value|
                                  {
                                    Namespace: namespace,
                                    OptionName: key.to_s,
                                    Value: value.is_a?(Hash) ? value : value.to_s
                                  }
                                end
                              end.flatten
                            }
                          }.tap { |res| res[:DependsOn] = chain_after if chain_after }
        template.ref(resource_name)
        resource_name
      end

      def eb_env_name(stack_name, app_name, env_name)
        "#{env_name}-#{Digest::SHA1.hexdigest([stack_name, app_name].join)[0,10]}"
      end

      def solution_stack(template, stack_name, stack_configurations:)
        stack = stack_configurations.fetch(stack_name)
        stack_name = stack_name.gsub('-', '_').gsub(/[^A-Z0-9_]/i, '').camelize
        ami_selector = nil

        if amis = stack['ami']
          amis.each do |region, ami|
            template.add_to_region_mapping "StackAMIs", region, stack_name, ami
          end

          ami_selector = template.find_in_regional_mapping("StackAMIs", stack_name)
        end

        {name: stack.fetch('solution'),
         ami: ami_selector}
      end

      def configure_elb_protocol(settings, app_config)
        # nothing to do if https is not desired (= HTTP), we rely on the default listener that is autogenerated by elasticbeanstalk
        return unless app_config.https?


        unless app_config.force_keep_http?
          # we only want https enabled. Therefore the default listener that is generated by elasticbeanstalk has to be disabled
          settings['aws:elb:listener:80'] = {
            'ListenerEnabled' => 'false'
          }
        end

        settings['aws:elb:listener:443'] = {
          'ListenerProtocol' => 'HTTPS',
          'InstanceProtocol' => 'HTTP',
          'InstancePort' => '80',
          'SSLCertificateId' => app_config.elb['ssl_certificate'],
          'PolicyNames' => 'SSL'  # matches with the policy name defined below
        }

        # AWS predefined SSL policy that only enables the SSL ciphers that are safe to use
        settings['aws:elb:policies:SSL'] = {
          'SSLReferencePolicy' => app_config.elb['ssl_reference_policy']
        }
      end

      def extrapolate_backends(config, backends, template)
        config.inject({}) do |acc, (key, value)|
          if value.is_a?(Hash)
            acc[key] = extrapolate_backends(value, backends, template)
          elsif backend = value.to_s.match(BACKEND_REGEX)
            backend_output = backends[backend[:type]][backend[:name]].
                             output(template)

            # TODO: more readable error message
            acc[key] = backend_output.fetch(backend[:property])
          else
            acc[key] = value
          end
          acc
        end
      end

      def extrapolate_applications(config, stack_name, env_name, env_config, template)
        config.inject({}) do |acc, (key, value)|
          if application = value.to_s.match(APPLICATION_REF_REGEX)
            app_config = Baustelle::Config.app_config(env_config, application[:name])
            hostname = app_config.dns_name ||
                       template.join('.',
                                     application_dns_endpoint(template, stack_name,
                                                              env_name,
                                                              application[:name]),
                                     'elasticbeanstalk.com')

            acc[key] = {
              'host' => hostname,
              'url' => template.join('', app_config.https? ? "https://" : "http://", hostname),
            }.fetch(application[:property])
          else
            acc[key] = value
          end
          acc
        end
      end

      def application_dns_endpoint(template, stack_name, env_name, app_name)
        template.join('-', stack_name,
                      template.ref('AWS::Region'),
                      "#{env_name}-#{app_name}".gsub('_', '-'))
      end
    end
  end
end
