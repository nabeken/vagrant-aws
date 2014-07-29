require "log4r"
require 'vagrant/util/retryable'
require 'vagrant-aws/util/timer'

module VagrantPlugins
  module AWS
    module Action
      # This runs the configured instance.
      class RunInstance
        include Vagrant::Util::Retryable

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant_aws::action::run_instance")
        end

        def call(env)
          # Initialize metrics if they haven't been
          env[:metrics] ||= {}

          # Get the region we're going to booting up in
          region = env[:machine].provider_config.region

          # Get the configs
          region_config         = env[:machine].provider_config.get_region_config(region)
          ami                   = region_config.ami
          availability_zone     = region_config.availability_zone
          instance_type         = region_config.instance_type
          keypair               = region_config.keypair_name
          private_ip_address    = region_config.private_ip_address
          security_groups       = region_config.security_groups
          subnet_id             = region_config.subnet_id
          tags                  = region_config.tags
          user_data             = region_config.user_data
          block_device_mapping  = region_config.block_device_mapping

          # If there is no keypair then warn the user
          if !keypair
            env[:ui].warn(I18n.t("vagrant_aws.launch_no_keypair"))
          end

          # If there is a subnet ID then warn the user
          if subnet_id
            env[:ui].warn(I18n.t("vagrant_aws.launch_vpc_warning"))
          end

          # Launch!
          env[:ui].info(I18n.t("vagrant_aws.launching_instance"))
          env[:ui].info(" -- Type: #{instance_type}")
          env[:ui].info(" -- AMI: #{ami}")
          env[:ui].info(" -- Region: #{region}")
          env[:ui].info(" -- Availability Zone: #{availability_zone}") if availability_zone
          env[:ui].info(" -- Keypair: #{keypair}") if keypair
          env[:ui].info(" -- Subnet ID: #{subnet_id}") if subnet_id
          env[:ui].info(" -- Private IP: #{private_ip_address}") if private_ip_address
          env[:ui].info(" -- User Data: yes") if user_data
          env[:ui].info(" -- Security Groups: #{security_groups.inspect}") if !security_groups.empty?
          env[:ui].info(" -- User Data: #{user_data}") if user_data
          env[:ui].info(" -- Block Device Mapping: #{block_device_mapping}") if block_device_mapping

          if region_config.spot_instance
            server = server_from_spot_request(env, region_config)
          else
            begin
              options = {
                :availability_zone  => availability_zone,
                :flavor_id          => instance_type,
                :image_id           => ami,
                :key_name           => keypair,
                :private_ip_address => private_ip_address,
                :subnet_id          => subnet_id,
                :tags               => tags,
                :user_data          => user_data,
                :block_device_mapping => block_device_mapping
              }
              if !security_groups.empty?
                security_group_key = options[:subnet_id].nil? ? :groups : :security_group_ids
                options[security_group_key] = security_groups
              end
              server = env[:aws_compute].servers.create(options)
            rescue Fog::Compute::AWS::NotFound => e
              # Invalid subnet doesn't have its own error so we catch and
              # check the error message here.
              if e.message =~ /subnet ID/
                raise Errors::FogError, :message => "Subnet ID not found: #{subnet_id}"
              end
              raise
            rescue Fog::Compute::AWS::Error => e
              raise Errors::FogError, :message => e.message
            end
          end

          if server
            # Immediately save the ID since it is created at this point.
            env[:machine].id = server.id
            # Wait for the instance to be ready first
            wait_server_ready(env, region_config, server)
          end
          @app.call(env)
        end

        def wait_server_ready(env, config, server)
          env[:metrics]["instance_ready_time"] = Util::Timer.time do
            tries = config.instance_ready_timeout / 2
            env[:ui].info(I18n.t("vagrant_aws.waiting_for_ready"))
            begin
              retryable(:on => Fog::Errors::TimeoutError, :tries => tries) do
                # If we're interrupted don't worry about waiting
                next if env[:interrupted]
                # Wait for the server to be ready
                server.wait_for(2) { ready? }
              end
            rescue Fog::Errors::TimeoutError
              # Delete the instance
              terminate(env)
              # Notify the user
              raise Errors::InstanceReadyTimeout, timeout: config.instance_ready_timeout
            end
          end
          @logger.info("Time to instance ready: #{env[:metrics]["instance_ready_time"]}")

          if !env[:interrupted]
            env[:metrics]["instance_ssh_time"] = Util::Timer.time do
              # Wait for SSH to be ready.
              env[:ui].info(I18n.t("vagrant_aws.waiting_for_ssh"))
              while true
                # If we're interrupted then just back out
                break if env[:interrupted]
                break if env[:machine].communicate.ready?
                sleep 2
              end
            end
            @logger.info("Time for SSH ready: #{env[:metrics]["instance_ssh_time"]}")
            # Ready and booted!
            env[:ui].info(I18n.t("vagrant_aws.ready"))
          end

          # Terminate the instance if we were interrupted
          terminate(env) if env[:interrupted]
        end

        # returns a fog server or nil
        def server_from_spot_request(env, config)
          # prepare request args
          options = {
            'InstanceCount'                                  => 1,
            'LaunchSpecification.KeyName'                    => config.keypair_name,
            'LaunchSpecification.Monitoring.Enabled'         => config.monitoring,
            'LaunchSpecification.Placement.AvailabilityZone' => config.availability_zone,
            # 'LaunchSpecification.EbsOptimized'               => config.ebs_optimized,
            'LaunchSpecification.UserData'                   => config.user_data,
            'LaunchSpecification.SubnetId'                   => config.subnet_id,
            'ValidUntil'                                     => config.spot_valid_until
          }
          security_group_key = config.subnet_id.nil? ? 'LaunchSpecification.SecurityGroup' : 'LaunchSpecification.SecurityGroupId'
          options[security_group_key] = config.security_groups
          options.delete_if { |key, value| value.nil? }

          env[:ui].info(I18n.t("vagrant_aws.launching_spot_instance"))
          env[:ui].info(" -- Price: #{config.spot_max_price}")
          env[:ui].info(" -- Valid until: #{config.spot_valid_until}") if config.spot_valid_until
          env[:ui].info(" -- Monitoring: #{config.monitoring}") if config.monitoring

          # create the spot instance
          spot_req = env[:aws_compute].request_spot_instances(
            config.ami,
            config.instance_type,
            config.spot_max_price,
            options).body["spotInstanceRequestSet"].first

          spot_request_id = spot_req["spotInstanceRequestId"]
          @logger.info("Spot request ID: #{spot_request_id}")
          env[:ui].info("Status: #{spot_req["state"]}")
          status_code = spot_req["state"]
          while true
            sleep 5 # TODO make it a param
            break if env[:interrupted]
            spot_req = env[:aws_compute].describe_spot_instance_requests(
              'spot-instance-request-id' => [spot_request_id]).body["spotInstanceRequestSet"].first

            # waiting for spot request ready
            next unless spot_req

            # display something whenever the status code changes
            if status_code != spot_req["state"]
              env[:ui].info("Status has been changed: #{spot_req["state"]}, reason: #{spot_req["fault"]["message"]}")
              status_code = spot_req["state"]
            end
            spot_state = spot_req["state"].to_sym
            case spot_state
            when :not_created, :open
              @logger.debug("Spot request #{spot_state} #{status_code}, waiting")
            when :active
              break; # :)
            when :closed, :cancelled, :failed
              @logger.error("Spot request #{spot_state} #{status_code}, aborting")
              break; # :(
            else
              @logger.debug("Unknown spot state #{spot_state} #{status_code}, waiting")
            end
          end
          # cancel the spot request but let the server go thru
          env[:aws_compute].cancel_spot_instance_requests(spot_request_id)
          # tries to return a server
          spot_req["instanceId"] ? env[:aws_compute].servers.get(spot_req["instanceId"]) : nil
        end

        def recover(env)
          return if env["vagrant.error"].is_a?(Vagrant::Errors::VagrantError)

          if env[:machine].provider.state.id != :not_created
            # Undo the import
            terminate(env)
          end
        end

        def terminate(env)
          destroy_env = env.dup
          destroy_env.delete(:interrupted)
          destroy_env[:config_validate] = false
          destroy_env[:force_confirm_destroy] = true
          env[:action_runner].run(Action.action_destroy, destroy_env)
        end
      end
    end
  end
end
