#!/usr/bin/env bash
set -e

if ! command -v VirtualBoxVM &> /dev/null
then
  sudo apt-get -y install software-properties-common
  #wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
  wget -O- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor --yes --output /usr/share/keyrings/oracle-virtualbox-2016.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
  sudo apt-get -y update
  sudo apt-get -y install vagrant virtualbox-7.0 #virtualbox-ext-pack

  wget https://download.virtualbox.org/virtualbox/7.0.14/Oracle_VM_VirtualBox_Extension_Pack-7.0.14.vbox-extpack
  sudo VBoxManage extpack install Oracle_VM_VirtualBox_Extension_Pack-7.0.14.vbox-extpack
  rm Oracle_VM_VirtualBox_Extension_Pack-7.0.14.vbox-extpack 
fi

if [ ! -f ./golden-key ]
then
  ssh-keygen -t ed25519 -C "devops@napses.com" -f ./golden-key -q -N "" 
fi

