#!/bin/bash
set -e 

domain=example.com
deploy_user=ubuntu
deploy_group=ubuntu

# Setup sudo to allow no-password sudo for "deploy" group and adding "deploy" user
if ! id -u $deploy_user > /dev/null 2>&1; then
  sudo groupadd -r $deploy_group
  sudo useradd -m -s /bin/bash $deploy_user
  sudo usermod -a -G $deploy_group $deploy_user
  sudo cp /etc/sudoers /etc/sudoers.orig
  echo "$deploy_group  ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/deploy
fi

# Installing SSH key
if [ ! -d "/home/$deploy_user/.ssh" ]
then
  sudo mkdir -p "/home/$deploy_user/.ssh"
  sudo chmod 700 "/home/$deploy_user/.ssh"
  sudo touch "/home/$deploy_user/.ssh/authorized_keys"
  sudo chmod 600 "/home/$deploy_user/.ssh/authorized_keys"
  sudo chown -R $deploy_user "/home/$deploy_user/.ssh"
  sudo usermod --shell /bin/bash $deploy_user
fi

if [ -f /tmp/golden-key.pub ]
then
  key=$(cat /tmp/golden-key.pub)
  if ! grep -qw "$key" "/home/$deploy_user/.ssh/authorized_keys" ;
  then
    sudo cat /tmp/golden-key.pub >> "/home/$deploy_user/.ssh/authorized_keys"
    sudo chown -R $deploy_user "/home/$deploy_user/.ssh"
  fi
fi

if [ "$EUID" -ne 0 ]
then 
  # If the current user is not root, then deploy user is current user
  deploy_user=$USER
fi
#test if running bash as a different user works
sudo -u $deploy_user bash -c : && RUNAS_DEPLOY="sudo -u $deploy_user"

if ! command -v jq &> /dev/null
then
  #sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get -y update 
  sudo apt-get -y install curl ca-certificates lsb-release ubuntu-keyring 
  sudo apt-get -y install build-essential python3 jq git nginx redis-tools postgresql-client
  sudo apt-get -y install fail2ban sysstat htop tree certbot python3-certbot-nginx mtr-tiny
  #sudo snap install trippy 
fi

# SETUP node

$RUNAS_DEPLOY bash<<'_'

if [ -z "$NVM_DIR" ]
then 
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
fi

if [[ $(type -t nvm) == function ]] ;
then
  echo "nvm is already installed, skipping..."
else 
  cd ~
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
  TEMP_FILE=$(mktemp tmp.XXXXXXXXXX)
  echo  'export NVM_DIR="$HOME/.nvm"' > $TEMP_FILE
  echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> $TEMP_FILE
  cat ~/.bashrc >> $TEMP_FILE && mv $TEMP_FILE ~/.bashrc 
  source ~/.bashrc
fi

if ! command -v node &> /dev/null
then
  # Installs the current lts. Replace this with the expected node version
  nvm install --lts
  npm install -g node-gyp

  npm install pm2@latest -g
  eval "$(pm2 startup | tail -n 1)"

  pm2 install pm2-logrotate
  #sudo pm2 logrotate -u user
  pm2 set pm2-logrotate:max_size 50M
  #pm2 set pm2-logrotate:compress true
fi
_
# END of $deploy_user

# Setup default limits
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.tcp_timestamps=1
ulimit -n 250000

# SETUP firewall
if  sudo ufw status | grep -qw inactive ;
then
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh
  sudo ufw allow http
  sudo ufw allow https
  sudo ufw --force enable
fi

# SETUP swap
if [ ! -f /swapfile ]
then
  #sudo fallocate -l 1G /swapfile
  sudo dd if=/dev/zero of=/swapfile bs=10240 count=$((2*104576))
  sudo chown root:root /swapfile 
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo "/swapfile               swap                    swap    sw        0 0" | sudo tee -a /etc/fstab
  sudo sysctl vm.swappiness=10
  #echo 10 > /proc/sys/vm/swappiness
  #add to /etc/sysctl.conf vm.swappiness=10
  sudo sed -i -e '/^#\?\(\s*vm.swappiness\s*=\s*\).*/{s//\110/;:a;n;ba;q}' -e '$avm.swappiness=10' /etc/sysctl.conf
fi

#sudo hostnamectl set-hostname "$domain"

# Setup nginx

target_file=/etc/nginx/sites-available/domain.conf
if [ ! -f $target_file ]
then
  echo "nginx file not found. creating"
  #copy nginx config/domain.conf into /etc/nginx/sites-available/
  sudo bash -c "cat > $target_file" <<-EOT_CONF
upstream nodejs_api_upstream {
    server 127.0.0.1:3000;
    #server 127.0.0.1:3001;
    keepalive 64;
}

server {
    listen 80;
    server_name _;
    #return 301 https://\$server_name\$request_uri;

    location / {
    	proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Real-IP \$remote_addr;
    	proxy_set_header Host \$http_host;
        
    	proxy_http_version 1.1;
    	proxy_set_header Upgrade \$http_upgrade;
    	proxy_set_header Connection "upgrade";
        
    	proxy_pass http://nodejs_api_upstream/;
    	proxy_redirect off;
    	proxy_read_timeout 240s;
    }
}

server {
    listen 443 ssl http2;
    
    server_name $domain;
    include snippets/self-signed.conf;
    include snippets/ssl-params.conf;
   
    location / {
    	proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Real-IP \$remote_addr;
    	proxy_set_header Host \$http_host;
        
    	proxy_http_version 1.1;
    	proxy_set_header Upgrade \$http_upgrade;
    	proxy_set_header Connection "upgrade";
        
    	proxy_pass http://nodejs_api_upstream/;
    	proxy_redirect off;
    	proxy_read_timeout 240s;
    }
}

EOT_CONF

  sudo bash -c "cat > /etc/nginx/sites-available/nginx-status.conf" <<-EOT_S_CONF

server {
  listen 80;
  server_name localhost;

  location /nginx_status {
    stub_status on;
    access_log  off;
    allow 127.0.0.1;
    deny all;
  }
}
EOT_S_CONF

  sudo rm /etc/nginx/sites-enabled/default
  sudo ln -s /etc/nginx/sites-available/domain.conf /etc/nginx/sites-enabled/domain.conf
  sudo ln -s /etc/nginx/sites-available/nginx-status.conf /etc/nginx/sites-enabled/nginx-status.conf

  # Self-Signed Certificate
  sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt -subj "/C=IN/O=Napses/OU=DevOps/CN=$domain"
  sudo openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 4096
  echo 'ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;' | sudo tee /etc/nginx/snippets/self-signed.conf 
  echo 'ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;'  | sudo tee -a /etc/nginx/snippets/self-signed.conf 
  #sudo bash -c cat << EOT_SSL  > /etc/nginx/snippets/ssl-params.conf
  sudo bash -c "cat >> /etc/nginx/snippets/ssl-params.conf" <<-EOT_SSL
ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/nginx/dhparam.pem; 
ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
#ssl_stapling on;
#ssl_stapling_verify on;
# Disable strict transport security for now. You can uncomment the following
# line if you understand the implications.
#add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
EOT_SSL

  #sudo certbot --nginx --agree-tos --redirect --hsts --staple-ocsp --key-type ecdsa --email "devops@$domain" -d "$domain" "www.$domain"

  sudo systemctl restart nginx
fi

# SETUP app

$RUNAS_DEPLOY bash<<'_'
if [ -z "$NVM_DIR" ]
then 
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
fi
# git clone and install the app
cd ~
pm2 save

_

