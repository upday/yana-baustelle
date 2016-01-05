module Baustelle
  class StackTemplate
    def initialize(config)
      @config = config
    end

    def build(name, template: CloudFormation::Template.new)
      # Prepare VPC
      vpc = CloudFormation::VPC.apply(template, vpc_name: name,
                                      cidr_block: config.fetch('vpc').fetch('cidr'),
                                      subnets: config.fetch('vpc').fetch('subnets'))

      peer_vpcs = config.fetch('vpc').fetch('peers', {}).map do |name, peer_config|
        CloudFormation::PeerVPC.apply(template, vpc, name,
                                      peer_config)
      end

      template.resource "GlobalSecurityGroup",
                        Type: "AWS::EC2::SecurityGroup",
                        Properties: {
                          VpcId: vpc.id,
                          GroupDescription: "#{name} baustelle stack global Security Group",
                          SecurityGroupIngress: [
                            {IpProtocol: 'tcp', FromPort: 0, ToPort: 65535, CidrIp: '0.0.0.0/0'}
                          ]
                        }

      template.resource "ELBSecurityGroup",
                        Type: "AWS::EC2::SecurityGroup",
                        Properties: {
                          VpcId: vpc.id,
                          GroupDescription: "#{name} baustelle stack ELB Security Group",
                          SecurityGroupIngress: [
                            {IpProtocol: 'tcp', FromPort: 0, ToPort: 65535, CidrIp: '0.0.0.0/0'}
                          ]
                        }

      global_iam_role = CloudFormation::IAMRole.new('', {'describe_tags' => {
                                         'action' => 'ec2:DescribeTags'
                                       },
                                       'describe_instances' => {
                                         'action' => 'ec2:DescribeInstances'
                                       }
                                      }).apply(template)

      applications = Baustelle::Config.applications(config).map do |app_name|
        app = CloudFormation::Application.new(name, app_name)
        app.apply(template)
        app
      end

      # For every environemnt
      Baustelle::Config.environments(config).each do |env_name|
        env_config = Baustelle::Config.for_environment(config, env_name)

        # Create backends

        environment_backends = Hash.new { |h,k| h[k] = {} }

        (env_config['backends'] || {}).inject(environment_backends) do |acc, (type, backends)|
          backend_klass = Baustelle::Backend.const_get(type)

          backends.each do |backend_name, options|
            backend_full_name = [env_name, backend_name].join('_')
            acc[type][backend_name] = backend = backend_klass.new(backend_full_name, options, vpc: vpc)
            backend.build(template)
          end

          environment_backends
        end

        # Create applications
        applications.each do |app|
          app_config = Baustelle::Config.app_config(env_config, app.name)

          unless app_config.disabled?
            resource_name = CloudFormation::EBEnvironment.apply(template,
                                                                stack_name: name,
                                                                env_name: env_name,
                                                                app_ref: app.ref(template),
                                                                app_name: app.name,
                                                                vpc: vpc,
                                                                app_config: app_config,
                                                                env_config: env_config,
                                                                stack_configurations: env_config.fetch('stacks'),
                                                                backends: environment_backends,
                                                                base_iam_role: global_iam_role)

            if app_config.dns_name
              CloudFormation::Route53.apply(template,
                                            app_resource_name: resource_name,
                                            hosted_zone_name: app_config.raw['dns'].fetch('hosted_zone'),
                                            dns_name: app_config.dns_name,
                                            ttl: app_config.raw['dns'].fetch('ttl', 60))
            end
          end
        end
      end
      template
    end

    private

    attr_reader :config
  end
end
