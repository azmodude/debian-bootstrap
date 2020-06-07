# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure("2") do |config|
  config.vm.box = "geerlingguy/ubuntu2004"
   config.vm.provider "virtualbox" do |vb|
     disk_file = 'zfs.vdi'
     vb.memory = "2048"
     vb.cpus = 2
     unless File.exist?(disk_file)
       vb.customize ['createhd', '--filename', disk_file, '--size', 20 * 1024]
     end
#     vb.customize ['storagectl', :id, '--name', 'Custom Controller', '--add', 'sata']
     vb.customize ['storageattach', :id, '--storagectl', 'IDE Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_file]
##     vb.customize ["modifyvm", :id, "--firmware", "efi"]
  end
end
