# frozen_string_literal: true

require 'yaml'
require 'pry'
require 'open3'
require 'helpers/utilities'

BOSH_CLI = ENV.fetch('BOSH_V2_CLI', 'bosh')
MANIFEST_PATH = ENV.fetch('BOSH_MANIFEST')

module Helpers
  class ExecuteError < StandardError
  end

  class Bosh2
    include Utilities

    def initialize
      @bosh_cli = "#{BOSH_CLI} -n"
      @ssh_gw_args = "--gw-user=#{ENV.fetch('JUMPBOX_USERNAME')} --gw-host=#{ENV.fetch('JUMPBOX_HOST')} --gw-private-key=#{ENV.fetch('JUMPBOX_PRIVATE_KEY_PATH')}"

      version = execute_successfully("#{@bosh_cli} --version")
      raise 'BOSH CLI >= v2 required' if version.start_with?('version 1.')
    end

    def execute_successfully(command)
      stdout, stderr, status = Open3.capture3(command)

      unless status.success?
        raise ExecuteError, "command, #{command}, output: #{stdout} failed with: #{stderr}"
      end

      stdout
    end

    def execute_with_error(command)
      Open3.capture3(command)
    end

    def deploy(deployment, manifest = MANIFEST_PATH)
      execute_successfully("#{@bosh_cli} -d #{deployment} deploy #{manifest}")
    end

    def redeploy(deployment)
      deployed_manifest = manifest(deployment)
      yield deployed_manifest
      Tempfile.open('manifest.yml') do |manifest_file|
        manifest_file.write(deployed_manifest.to_yaml)
        manifest_file.flush
        deploy(deployment, manifest_file.path)
      end
    end

    def manifest(deployment)
      manifest = execute_successfully("#{@bosh_cli} -d #{deployment} manifest")
      YAML.safe_load(manifest)
    end

    def recreate(deployment, instance)
      execute_successfully("#{@bosh_cli} -d #{deployment} recreate #{instance}")
    end

    def start(deployment, instance)
      execute_successfully("#{@bosh_cli} -d #{deployment} start #{instance}")
    end

    def stop(deployment, instance)
      execute_successfully("#{@bosh_cli} -d #{deployment} stop #{instance}")
    end

    def ssh(deployment, instance, command)
      output = execute_successfully("#{@bosh_cli} -d #{deployment} --json ssh --command='#{command}' #{@ssh_gw_args} #{instance}")
      extract_stdout(output)
    end

    def ssh_with_error(deployment, instance, command)
      stdout, stderr, status = execute_with_error("#{@bosh_cli} -d #{deployment} --json ssh --command='#{command}' #{@ssh_gw_args} #{instance}")
      [extract_stdout(stdout), stderr, status]
    end

    def scp(deployment, instance, local_path, remote_path)
      execute_successfully("#{@bosh_cli} -d #{deployment} scp #{@ssh_gw_args} #{local_path} #{instance}:#{remote_path}")
    end

    def log_files(deployment, instance)
      tmpdir = Dir.tmpdir
      execute_successfully("#{@bosh_cli} -d #{deployment} logs --dir=#{tmpdir} #{@ssh_gw_args} #{instance}")

      tarball = Dir[File.join(tmpdir, deployment.to_s + '.' + instance.to_s + '*.tgz')].last
      output = execute_successfully("tar -tf #{tarball}")
      lines = output.split(/\n+/)
      file_paths = lines.map {|f| Pathname.new(f)}
      file_paths.select {|f| f.extname == '.log'}
    end

    def instance(deployment, host)
      output = execute_successfully("#{@bosh_cli} -d #{deployment} instances --json")

      result = JSON.parse(output)
      table = result.fetch('Tables').first
      rows = table.fetch('Rows')
      match = rows.find {|row| row.fetch('ips') == host}
      return nil if match.nil?

      match.fetch('instance')
    end

    def wait_for_process_start(deployment, instance, process_name)
      18.times do
        sleep 5
        monit_output, = ssh_with_error(
          deployment,
          instance,
          "sudo /var/vcap/bosh/bin/monit summary | grep #{process_name} | grep running")
        return true unless monit_output.strip.empty?
      end

      puts "Process #{process_name} did not start within 90 seconds"
      false
    end

    def wait_for_process_stop(deployment, instance, process_name)
      12.times do
        puts "Waiting for #{process_name} to stop"
        sleep 5

        monit_output, = ssh_with_error(
          deployment,
          instance,
          %(sudo /var/vcap/bosh/bin/monit summary | grep #{process_name} | grep "not monitored"))

        return true unless monit_output.strip.empty?
      end

      puts "Process #{process_name} did not stop within 60 seconds"
      false
    end

    def eventually_contains_shutdown_log(deployment, instance, prestop_timestamp)
      12.times do
        vm_log = ssh(deployment, instance, 'sudo cat /var/vcap/sys/log/cf-redis-broker/cf-redis-broker.stdout.log')
        contains_expected_shutdown_log = drop_log_lines_before(prestop_timestamp, vm_log).any? do |line|
          line.include?('Starting Redis Broker shutdown')
        end

        return true if contains_expected_shutdown_log
        sleep 5
      end

      puts 'Broker did not log shutdown within 60 seconds'
      false
    end

    private

    def extract_stdout(raw_output)
      result = JSON.parse(raw_output)
      stdout = []

      blocks = result.fetch('Blocks')
      blocks.each_with_index do |line, index|
        stdout << blocks[index + 1].rstrip if line.include? 'stdout |'
      end

      stdout.join("\n")
    end
  end
end