# frozen_string_literal: true

require 'spec_helper'
require 'hako/application'
require 'hako/definition_loader'
require 'hako/loader'
require 'hako/schedulers/ecs'

RSpec.describe Hako::Schedulers::Ecs do
  let(:dry_run) { false }
  let(:tag) { 'latest' }
  let(:containers) { Hako::DefinitionLoader.new(app, dry_run: dry_run).load(tag) }
  let(:scripts) do
    app.yaml.fetch('scripts', []).map do |config|
      Hako::Loader.new(Hako::Scripts, 'hako/scripts').load(config.fetch('type')).new(app, config, dry_run: dry_run)
    end
  end
  let(:force) { false }
  let(:scheduler) do
    described_class.new(app.id, app.yaml['scheduler'], scripts: scripts, volumes: app.yaml.fetch('volumes', {}), force: force, dry_run: dry_run, timeout: nil)
  end
  let(:cluster_arn) { 'arn:aws:ecs:ap-northeast-1:012345678901:cluster/eagletmt' }
  let(:service_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:service/#{app.id}" }
  let(:logger) { Logger.new(logger_io) }
  let(:logger_io) { StringIO.new }

  let(:ecs_client) { double('Aws::ECS::Client') }

  before do
    allow(Hako).to receive(:logger).and_return(logger)
    allow(scheduler).to receive(:ecs_client).and_return(ecs_client)
  end

  describe '#deploy' do
    context 'when initial deployment' do
      let(:app) { Hako::Application.new(fixture_root.join('yaml', 'ecs.yml')) }
      let(:task_definition_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:task-definition/#{app.id}:1" }

      before do
        allow(ecs_client).to receive(:describe_services).with(cluster: 'eagletmt', services: [app.id]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [],
        )).once
        allow(ecs_client).to receive(:describe_task_definition).with(task_definition: app.id).and_raise(Aws::ECS::Errors::ClientException.new(nil, 'Unable to describe task definition')).once
      end

      it 'creates new service' do
        expect(ecs_client).to receive(:register_task_definition).with(
          family: app.id,
          task_role_arn: nil,
          container_definitions: [{
            name: 'app',
            image: 'busybox:latest',
            cpu: 32,
            memory: 64,
            memory_reservation: nil,
            links: [],
            port_mappings: [],
            essential: true,
            environment: [],
            docker_labels: { 'cc.wanko.hako.version' => Hako::VERSION },
            mount_points: [],
            command: nil,
            privileged: false,
            volumes_from: [],
            user: nil,
            log_configuration: nil,
          }],
          volumes: [],
        ).and_return(Aws::ECS::Types::RegisterTaskDefinitionResponse.new(
          task_definition: Aws::ECS::Types::TaskDefinition.new(
            task_definition_arn: task_definition_arn,
          ),
        )).once
        expect(ecs_client).to receive(:create_service).with(
          cluster: 'eagletmt',
          service_name: app.id,
          task_definition: task_definition_arn,
          desired_count: 0,
          role: 'ECSServiceRole',
          deployment_configuration: {
            maximum_percent: nil,
            minimum_healthy_percent: nil,
          },
          placement_constraints: [],
          placement_strategy: [],
        ).and_return(Aws::ECS::Types::CreateServiceResponse.new(
          service: Aws::ECS::Types::Service.new(
            placement_constraints: [],
            placement_strategy: [],
          ),
        )).once
        expect(ecs_client).to receive(:update_service).with(
          cluster: 'eagletmt',
          service: app.id,
          task_definition: task_definition_arn,
          desired_count: 1,
          deployment_configuration: {
            maximum_percent: nil,
            minimum_healthy_percent: nil,
          },
        ).and_return(Aws::ECS::Types::UpdateServiceResponse.new(
          service: Aws::ECS::Types::Service.new(
            cluster_arn: cluster_arn,
            service_arn: service_arn,
            events: [],
          ),
        )).once
        expect(ecs_client).to receive(:describe_services).with(cluster: cluster_arn, services: [service_arn]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(events: [], deployments: [Aws::ECS::Types::Deployment.new(status: 'PRIMARY', desired_count: 1, running_count: 1)])],
        )).once

        scheduler.deploy(containers)
        expect(logger_io.string).to include('Registered task definition')
        expect(logger_io.string).to include('Updated service')
        expect(logger_io.string).to include('Deployment completed')
      end
    end

    context 'when the same service is running' do
      let(:app) { Hako::Application.new(fixture_root.join('yaml', 'ecs.yml')) }
      let(:task_definition_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:task-definition/#{app.id}:1" }

      before do
        allow(ecs_client).to receive(:describe_services).with(cluster: 'eagletmt', services: [app.id]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(
            desired_count: 1,
            task_definition: task_definition_arn,
            events: [],
            deployment_configuration: {
              maximum_percent: nil,
              minimum_healthy_percent: nil,
            },
            placement_constraints: [],
            placement_strategy: [],
          )],
        )).once
        allow(ecs_client).to receive(:describe_task_definition).with(task_definition: app.id).and_return(Aws::ECS::Types::DescribeTaskDefinitionResponse.new(
          task_definition: Aws::ECS::Types::TaskDefinition.new(
            task_definition_arn: task_definition_arn,
            container_definitions: [
              Aws::ECS::Types::ContainerDefinition.new(
                name: 'app',
                image: 'busybox:latest',
                cpu: 32,
                memory: 64,
                links: [],
                port_mappings: [],
                environment: [],
                docker_labels: { 'cc.wanko.hako.version' => Hako::VERSION },
                mount_points: [],
                privileged: false,
                volumes_from: [],
              ),
            ],
            volumes: [],
          ),
        )).once
      end

      it 'does nothing' do
        scheduler.deploy(containers)
        expect(logger_io.string).to include("Task definition isn't changed")
        expect(logger_io.string).to include("Service isn't changed")
        expect(logger_io.string).to include('Deployment completed')
      end
    end

    context 'when the running service has different desired_count' do
      let(:app) { Hako::Application.new(fixture_root.join('yaml', 'ecs.yml')) }
      let(:task_definition_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:task-definition/#{app.id}:1" }

      before do
        allow(ecs_client).to receive(:describe_services).with(cluster: 'eagletmt', services: [app.id]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(
            desired_count: 0,
            task_definition: task_definition_arn,
            events: [],
            deployment_configuration: {
              maximum_percent: nil,
              minimum_healthy_percent: nil,
            },
            placement_constraints: [],
            placement_strategy: [],
          )],
        )).once
        allow(ecs_client).to receive(:describe_task_definition).with(task_definition: app.id).and_return(Aws::ECS::Types::DescribeTaskDefinitionResponse.new(
          task_definition: Aws::ECS::Types::TaskDefinition.new(
            task_definition_arn: task_definition_arn,
            container_definitions: [
              Aws::ECS::Types::ContainerDefinition.new(
                name: 'app',
                image: 'busybox:latest',
                cpu: 32,
                memory: 64,
                links: [],
                port_mappings: [],
                environment: [],
                docker_labels: { 'cc.wanko.hako.version' => Hako::VERSION },
                mount_points: [],
                privileged: false,
                volumes_from: [],
              ),
            ],
            volumes: [],
          ),
        )).once
      end

      it 'updates service' do
        expect(ecs_client).to receive(:update_service).with(
          cluster: 'eagletmt',
          service: app.id,
          task_definition: task_definition_arn,
          desired_count: 1,
          deployment_configuration: {
            maximum_percent: nil,
            minimum_healthy_percent: nil,
          },
        ).and_return(Aws::ECS::Types::UpdateServiceResponse.new(
          service: Aws::ECS::Types::Service.new(
            cluster_arn: cluster_arn,
            service_arn: service_arn,
            events: [],
          ),
        )).once
        expect(ecs_client).to receive(:describe_services).with(cluster: cluster_arn, services: [service_arn]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(events: [], deployments: [Aws::ECS::Types::Deployment.new(status: 'PRIMARY', desired_count: 1, running_count: 1)])],
        )).once
        scheduler.deploy(containers)
      end
    end

    context 'when ther running service has different task definition' do
      let(:app) { Hako::Application.new(fixture_root.join('yaml', 'ecs.yml')) }
      let(:running_task_definition_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:task-definition/#{app.id}:1" }
      let(:updated_task_definition_arn) { "arn:aws:ecs:ap-northeast-1:012345678901:task-definition/#{app.id}:2" }

      before do
        allow(ecs_client).to receive(:describe_services).with(cluster: 'eagletmt', services: [app.id]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(
            desired_count: 1,
            task_definition: running_task_definition_arn,
            events: [],
            deployment_configuration: {
              maximum_percent: nil,
              minimum_healthy_percent: nil,
            },
            placement_constraints: [],
            placement_strategy: [],
          )],
        )).once
        allow(ecs_client).to receive(:describe_task_definition).with(task_definition: app.id).and_return(Aws::ECS::Types::DescribeTaskDefinitionResponse.new(
          task_definition: Aws::ECS::Types::TaskDefinition.new(
            task_definition_arn: running_task_definition_arn,
            container_definitions: [
              Aws::ECS::Types::ContainerDefinition.new(
                name: 'app',
                image: 'busybox:latest',
                cpu: 32,
                memory: 1024, # different
                links: [],
                port_mappings: [],
                environment: [],
                docker_labels: { 'cc.wanko.hako.version' => Hako::VERSION },
                mount_points: [],
                privileged: false,
                volumes_from: [],
              ),
            ],
            volumes: [],
          ),
        )).once
      end
      it 'updates task definition and service' do
        expect(ecs_client).to receive(:register_task_definition).with(
          family: app.id,
          task_role_arn: nil,
          container_definitions: [{
            name: 'app',
            image: 'busybox:latest',
            cpu: 32,
            memory: 64,
            memory_reservation: nil,
            links: [],
            port_mappings: [],
            essential: true,
            environment: [],
            docker_labels: { 'cc.wanko.hako.version' => Hako::VERSION },
            mount_points: [],
            command: nil,
            privileged: false,
            volumes_from: [],
            user: nil,
            log_configuration: nil,
          }],
          volumes: [],
        ).and_return(Aws::ECS::Types::RegisterTaskDefinitionResponse.new(
          task_definition: Aws::ECS::Types::TaskDefinition.new(
            task_definition_arn: updated_task_definition_arn,
          ),
        )).once
        expect(ecs_client).to receive(:update_service).with(
          cluster: 'eagletmt',
          service: app.id,
          task_definition: updated_task_definition_arn,
          desired_count: 1,
          deployment_configuration: {
            maximum_percent: nil,
            minimum_healthy_percent: nil,
          },
        ).and_return(Aws::ECS::Types::UpdateServiceResponse.new(
          service: Aws::ECS::Types::Service.new(
            cluster_arn: cluster_arn,
            service_arn: service_arn,
            events: [],
          ),
        )).once
        expect(ecs_client).to receive(:describe_services).with(cluster: cluster_arn, services: [service_arn]).and_return(Aws::ECS::Types::DescribeServicesResponse.new(
          failures: [],
          services: [Aws::ECS::Types::Service.new(events: [], deployments: [Aws::ECS::Types::Deployment.new(status: 'PRIMARY', desired_count: 1, running_count: 1)])],
        )).once
        scheduler.deploy(containers)
      end
    end
  end
end
