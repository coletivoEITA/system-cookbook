# encoding: UTF-8
#
# Cookbook Name:: system
# Provider:: hostname
#
# Copyright 2012-2015, Chris Fordham
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# represents Chef
class Chef
  # include the HostInfo and GetIP libraries
  class Recipe
    include HostInfo
    include GetIP
  end
end

action :set do
  # first, ensure lower case for each piece
  new_resource.short_hostname.downcase! if new_resource.short_hostname
  new_resource.domain_name.downcase! if new_resource.domain_name

  # logically build the fqdn depending on how the user specified
  short_hostname = new_resource.hostname.split('.').first
  short_hostname = new_resource.short_hostname if new_resource.short_hostname
  if new_resource.domain_name
    domain_name = new_resource.domain_name
  else
    if new_resource.hostname.split('.').count >= 2
      domain_name = new_resource.hostname.split('.')[1..-1].join('.')
    else
      # fallback domain name to 'localdomain' to complete a valid FQDN
      domain_name = node['system']['domain_name']
    end
  end

  # piece together the fqdn
  fqdn = "#{short_hostname}.#{domain_name}".downcase
  ::Chef::Log.debug "FQDN determined to be: #{fqdn}"

  # https://tickets.opscode.com/browse/OHAI-389
  # http://lists.opscode.com/sympa/arc/chef/2014-10/msg00092.html
  node.automatic_attrs['fqdn'] = fqdn
  node.automatic_attrs['hostname'] = new_resource.short_hostname

  if platform_family?('mac_os_x')
    execute 'set configd parameter: HostName' do
      command "scutil --set HostName #{fqdn}"
      not_if { Mixlib::ShellOut.new('scutil --get HostName').run_command.stdout.strip == fqdn }
      notifies :create, 'ruby_block[show host info]', :delayed
    end

    shorthost_params = %w(ComputerName LocalHostName)
    shorthost_params.each do |param|
      execute "set configd parameter: #{param}" do
        command "scutil --set #{param} #{new_resource.short_hostname}"
        not_if { Mixlib::ShellOut.new("scutil --get #{param}").run_command.stdout.strip == new_resource.short_hostname }
        notifies :create, 'ruby_block[show host info]', :delayed
      end
    end

    smb_params = %w(NetBIOSName Workgroup)
    smb_params.each do |param|
      execute "set configd parameter: #{param}" do
        command "defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server #{param} #{node['system']['netbios_name']}"
        not_if { Mixlib::ShellOut.new("defaults read /Library/Preferences/SystemConfiguration/com.apple.smb.server #{param}").run_command.stdout.strip == node['system']['netbios_name'] }
        notifies :create, 'ruby_block[show host info]', :delayed
      end
    end
  end

  # http://www.debian.org/doc/manuals/debian-reference/ch05.en.html#_the_hostname_resolution
  if node['system']['permanent_ip']
    # remove 127.0.0.1 from /etc/hosts when using permanent IP
    hostsfile_entry '127.0.1.1' do
      action :remove
    end
    hostsfile_entry '127.0.0.1' do
      hostname 'localhost.localdomain'
      aliases ['localhost']
    end
    hostsfile_entry GetIP.local do
      hostname lazy { fqdn }
      aliases [new_resource.short_hostname]
    end
  else
    hostsfile_entry GetIP.local do
      hostname lazy { fqdn }
      aliases [new_resource.short_hostname]
      action :remove
    end
    hostsfile_entry '127.0.1.1' do
      hostname lazy { fqdn }
      aliases [new_resource.short_hostname]
      only_if { platform_family?('debian') }
    end
    hostsfile_entry '127.0.0.1' do
      hostname lazy { fqdn }
      aliases [new_resource.short_hostname, 'localhost.localdomain', 'localhost']
      not_if { platform_family?('debian') }
    end
  end

  # add in/ensure this default host for mac_os_x
  hostsfile_entry '255.255.255.255' do
    hostname 'broadcasthost'
    only_if { platform_family?('mac_os_x') }
  end

  # the following are desirable for IPv6 capable hosts
  ipv6_hosts = [
    { ip: '::1', name: 'localhost6.localdomain6',
      aliases: %w(localhost6 ip6-localhost ip6-loopback) },
    { ip: 'fe00::0', name: 'ip6-localnet' },
    { ip: 'ff00::0', name: 'ip6-mcastprefix' },
    { ip: 'ff02::1', name: 'ip6-allnodes' },
    { ip: 'ff02::2', name: 'ip6-allrouters' }
  ]

  # we'll keep ipv6 stock for os x
  if platform_family?('mac_os_x')
    ipv6_hosts.select { |h| h[:ip] == '::1' }[0][:name] = 'localhost'
    ipv6_hosts.select { |h| h[:ip] == '::1' }[0][:aliases] = nil
    ipv6_hosts = [ipv6_hosts.slice(1 - 1)]
  end

  # add the ipv6 hosts to /etc/hosts
  ipv6_hosts.each do |host|
    hostsfile_entry host[:ip] do
      hostname host[:name]
      aliases host[:aliases] if host[:aliases]
      priority 5
    end
  end

  # additional static hosts provided by attribute (if any)
  node['system']['static_hosts'].each do |ip, host|
    hostsfile_entry ip do
      hostname host
      priority 6
    end
  end

  # (re)start the hostname[.sh] service on debian-based distros
  if platform_family?('debian')
    case node['platform']
    when 'debian'
      service_name = 'hostname.sh'
      service_supports = {
        start: true,
        restart: false,
        status: false,
        reload: false
      }
      service_provider = ::Chef::Provider::Service::Init::Debian
    when 'ubuntu'
      service_name = 'hostname'
      service_supports = {
        start: true,
        restart: true,
        status: false,
        reload: true
      }
      service_provider = ::Chef::Provider::Service::Upstart
    end

    service service_name do
      supports service_supports
      provider service_provider
      action :nothing
    end
  end

  # http://www.rackspace.com/knowledge_center/article/centos-hostname-change
  service 'network' do
    only_if { platform_family?('rhel') }
    only_if { node['platform_version'] < '7.0' }
  end

  # we want to physically set the hostname in the compile phase
  # as early as possible, just in case (although its not actually needed)
  execute 'run hostname' do
    command "hostname #{fqdn}"
    action :nothing
    not_if { Mixlib::ShellOut.new('hostname -f').run_command.stdout.strip == fqdn }
  end.run_action(:run)

  # let's not manage the entire file because its shared
  ruby_block 'update network sysconfig' do
    block do
      fe = ::Chef::Util::FileEdit.new('/etc/sysconfig/network')
      fe.search_file_replace_line(/HOSTNAME\=/, "HOSTNAME=#{fqdn}")
      fe.write_file
    end
    only_if { platform_family?('rhel') }
    only_if { node['platform_version'] < '7.0' }
    not_if { ::File.readlines('/etc/sysconfig/network').grep(/HOSTNAME=#{fqdn}/).any? }
    notifies :restart, 'service[network]', :delayed
  end

  ruby_block 'show hostnamectl' do
    block do
      ::Chef::Log.info('== hostnamectl ==')
      ::Chef::Log.info(HostInfo.hostnamectl)
    end
    action :nothing
    only_if "bash -c 'type -P hostnamectl'"
  end

  # https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux/7/html/Networking_Guide/sec_Configuring_Host_Names_Using_hostnamectl.html
  # hostnamectl is used by other distributions too
  execute 'run hostnamectl' do
    command "hostnamectl set-hostname #{fqdn}"
    only_if "bash -c 'type -P hostnamectl'"
    not_if { Mixlib::ShellOut.new('hostname -f').run_command.stdout.strip == fqdn }
    notifies :create, 'ruby_block[show hostnamectl]', :delayed
  end

  # run domainname command if available
  execute 'run domainname' do
    command "domainname #{new_resource.domain_name}"
    only_if "bash -c 'type -P domainname'"
    action :nothing
  end

  # Show the new host/node information
  ruby_block 'show host info' do
    block do
      ::Chef::Log.info('== New host/node information ==')
      ::Chef::Log.info("Hostname: #{HostInfo.hostname == '' ? '<none>' : HostInfo.hostname}")
      ::Chef::Log.info("Network node hostname: #{HostInfo.network_node == '' ? '<none>' : HostInfo.network_node}")
      ::Chef::Log.info("Alias names of host: #{HostInfo.host_aliases == '' ? '<none>' : HostInfo.host_aliases}")
      ::Chef::Log.info("Short host name (cut from first dot of hostname): #{HostInfo.short_name == '' ? '<none>' : HostInfo.short_name}")
      ::Chef::Log.info("Domain of hostname: #{HostInfo.domain_name == '' ? '<none>' : HostInfo.domain_name}")
      ::Chef::Log.info("FQDN of host: #{HostInfo.fqdn == '' ? '<none>' : HostInfo.fqdn}")
      ::Chef::Log.info("IP address(es) for the hostname: #{HostInfo.host_ip == '' ? '<none>' : HostInfo.host_ip}")
      ::Chef::Log.info("Current FQDN in node object: #{node['fqdn']}")
      ::Chef::Log.info("Apple SMB Server: #{HostInfo.apple_smb_server}") if node['platform'] == 'mac_os_x'
    end
    action :nothing
  end

  file '/etc/hostname' do
    owner 'root'
    group 'root'
    mode 0755
    content "#{fqdn}\n"
    action :create
    notifies :start, resources("service[#{service_name}]"), :immediately if platform?('debian')
    notifies :restart, resources("service[#{service_name}]"), :immediately if platform?('ubuntu')
    notifies :create, 'ruby_block[update network sysconfig]', :immediately
    notifies :run, 'execute[run domainname]', :immediately
    notifies :run, 'execute[run hostname]', :immediately
    notifies :create, 'ruby_block[show host info]', :delayed
    not_if { node['platform'] == 'mac_os_x' }
  end

  # covers cases where a dhcp client has manually
  # set the hostname (such as with the hostname command)
  # and /etc/hostname has not changed
  # this can be the the case with ec2 ebs start
  execute "ensure hostname sync'd" do
    command "hostname #{fqdn}"
    not_if { Mixlib::ShellOut.new('hostname -f').run_command.stdout.strip == fqdn }
  end

  # rightscale support: rightlink CLI tools, rs_tag
  execute 'set rightscale server hostname tag' do
    command "rs_tag --add 'node:hostname=#{fqdn}'"
    only_if "bash -c 'type -P rs_tag'"
  end

  new_resource.updated_by_last_action(true)
end # close action :set
