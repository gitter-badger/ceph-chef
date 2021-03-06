#
# Author: Chris Jones <cjones303@bloomberg.net>
# Cookbook: ceph
# Recipe: mon
#
# Copyright 2015, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This recipe creates a monitor cluster
#
# You should never change the mon default path or
# the keyring path.
# Don't change the cluster name either
# Default path for mon data: /var/lib/ceph/mon/$cluster-$id/
#   which will be /var/lib/ceph/mon/ceph-`hostname`/
#   This path is used by upstart. If changed, upstart won't
#   start the monitor
# The keyring files are created using the following pattern:
#  /etc/ceph/$cluster.client.$name.keyring
#  e.g. /etc/ceph/ceph.client.admin.keyring
#  The bootstrap-osd and bootstrap-mds keyring are a bit
#  different and are created in
#  /var/lib/ceph/bootstrap-{osd,mds}/ceph.keyring

# IMPORTANT: The NTP or CHRONY recipe is not part of the lower level ceph cookbook but you must use an NTP
# server to keep your cluster in time sync. If time drift occurs then ceph will not work properly. This is
# true for any distributed system.

node.default['ceph']['is_mon'] = true

include_recipe 'ceph-chef'
include_recipe 'ceph-chef::mon_install'

service_type = node['ceph']['mon']['init_style']

# If not using rbd then this is not required but it's included anyway
directory '/var/lib/qemu' do
  owner 'root'
  group 'root'
  mode '0755'
  recursive true
  action :create
end

directory '/var/run/ceph' do
  owner 'root'
  group 'root'
  mode 00755
  recursive true
  action :create
end

directory "/var/lib/ceph/mon/#{node['ceph']['cluster']}-#{node['hostname']}" do
  owner 'root'
  group 'root'
  mode 00755
  recursive true
  action :create
end

# Create in a scratch area
keyring = "/etc/ceph/#{node['ceph']['cluster']}.mon.keyring"

# This will execute on other nodes besides the first mon node.
execute 'format ceph-mon-secret as keyring' do
  command lazy { "ceph-authtool --create-keyring #{keyring} --name=mon. --add-key=#{node['ceph']['monitor-secret']} --cap mon 'allow *'" }
  creates keyring
  only_if { ceph_chef_mon_secret }
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

# This should only run once to generate the mon key and then the command above should be executed on other nodes
execute 'generate ceph-mon-secret as keyring' do
  command lazy { "ceph-authtool --create-keyring #{keyring} --name=mon. --gen-key --cap mon 'allow *'" }
  creates keyring
  not_if { ceph_chef_mon_secret }
  notifies :create, 'ruby_block[save ceph_chef_mon_secret]', :immediately
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

# Part of monitor-secret calls above - Also, you can set node['ceph']['monitor-secret'] = ceph_chef_keygen()
# in a higher level recipe like the way ceph-chef does it in ceph-mon.rb
ruby_block 'save ceph_chef_mon_secret' do
  block do
    fetch = Mixlib::ShellOut.new("ceph-authtool #{keyring} --print-key --name=mon.")
    fetch.run_command
    key = fetch.stdout
    node.set['ceph']['monitor-secret'] = key.delete!("\n")
    node.save
  end
  action :nothing
end

# For now, make all mon nodes admin nodes
include_recipe 'ceph-chef::admin_client'

# Add admin key to monitor key and put a copy in the /var/lib/ceph/mon/... area
# Admin key is required on any host that may perform 'ceph' related calls such as 'ceph -s'
# In this case, all monitors have admin keys

execute 'make sure monitor key is in mon data' do
  command <<-EOH
    ceph-authtool #{keyring} --import-keyring /etc/ceph/#{node['ceph']['cluster']}.client.admin.keyring
  EOH
  not_if "grep -Fxq 'admin' #{keyring}"
end

execute 'ceph-mon mkfs' do
  command lazy { "ceph-mon --mkfs -i #{node['hostname']} --fsid #{node['ceph']['fsid-secret']} --keyring #{keyring}" }
  creates "/var/lib/ceph/mon/#{node['ceph']['cluster']}-#{node['hostname']}/keyring"
  not_if "test -f /var/lib/ceph/mon/#{node['ceph']['cluster']}-#{node['hostname']}/keyring"
end

ruby_block 'mon-finalize' do
  block do
    ['done', service_type].each do |ack|
      ::File.open("/var/lib/ceph/mon/#{node['ceph']['cluster']}-#{node['hostname']}/#{ack}", 'w').close
    end
  end
end
