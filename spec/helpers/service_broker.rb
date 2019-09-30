# frozen_string_literal: true
require 'helpers/service_broker_api'
require 'helpers/cf_cli'

module Helpers
  class ServiceBroker

    def initialize(args = {})
      api_args = args.reject { |k, _v| k == :api }
      @api = args.fetch(:api) { Helpers::ServiceBrokerApi.new(api_args) }
    end

    def provision_instance(service_name, plan_name)
      plan = service_plan(service_name, plan_name)
      api.provision_instance(plan)
    end

    def deprovision_instance(service_instance, service_name, plan_name)
      plan = service_plan(service_name, plan_name)
      api.deprovision_instance(service_instance, plan)
    end

    def bind_instance(service_instance, service_name, plan_name)
      plan = service_plan(service_name, plan_name)
      api.bind_instance(service_instance, plan)
    end

    def unbind_instance(service_instance, service_name, plan_name)
      plan = service_plan(service_name, plan_name)
      api.unbind_instance(service_instance, plan)
    end

    def service_plan(service_name, plan_name)
      api.catalog.service_plan(service_name, plan_name)
    end

    def catalog
      api.catalog
    end

    private

    attr_reader :api
  end
end