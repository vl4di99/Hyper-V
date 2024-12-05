#!/usr/bin/env bash

# Copyright (c) 2024-2025, Dionisie-Vladut Lorincz
# Author: vl4di99
# https://github.com/vl4di99
# License: MIT
# Thanks to community-scripts and tteck for the prime parts of this script

echo "Checking if root user"
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

echo "Running as root. Proceeding with the installation..."
echo " Checking for an existing Nginx Proxy Manager installation..."
if [ -f /lib/systemd/system/npm.service ]; then
  echo "Nginx Proxy Manager is already installed. Proceeding with the update"
  if [ -f ./nginxProxyManager-update.sh ]; then
    bash ./nginxProxyManager-update.sh
  else
    echo "Update script was not found. Exiting..."
    exit 1
  fi
  exit 0
fi

echo "Installing Nginx Proxy Manager..."
echo "Installing Basic Dependencies..."
apt-get update
apt-get -y install sudo mc curl gnupg make gcc g++ ca-certificates apache2-utils logrotate build-essential git wget

echo "Installing Python Dependencies..."
apt-get -y install python3 python3-dev python3-pip python3-venv python3-cffi python3-certbot python3-certbot-dns-cloudflare
install_certbot_dns_multi
echo "Creating Python Virtual Environment..."
python3 -m venv /opt/certbot/
rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED
echo "Successfully installed and configured Python"

VERSION="$(awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release)"

echo "Installing Openresty"
wget -qO - https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/openresty-archive-keyring.gpg
echo -e "deb http://openresty.org/package/debian bullseye openresty" >/etc/apt/sources.list.d/openresty.list
apt-get update
apt-get -y install openresty
echo "Successfully installed Openresty"

echo "Installing Node.js"
bash <(curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh)
source ~/.bashrc
nvm install 16.20.2
ln -sf /root/.nvm/versions/node/v16.20.2/bin/node /usr/bin/node
echo "Successfully installed Node.js"

echo "Installing pnpm"
npm install -g pnpm@8.15
echo "Successfully installed pnpm"

RELEASE=$(curl -s https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest |
  grep "tag_name" |
  awk '{print substr($2, 3, length($2)-4) }')

echo "Downloading latest version of Nginx Proxy Manager (v${RELEASE})..."
wget -q https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v${RELEASE} -O - | tar -xz
cd ./nginx-proxy-manager-${RELEASE}
echo "Successfully downloaded latest version of Nginx Proxy Manager (v${RELEASE})"

echo "Setting up environment..."
ln -sf /usr/bin/python3 /usr/bin/python
ln -sf /usr/bin/certbot /opt/certbot/bin/certbot
ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
ln -sf /usr/local/openresty/nginx/ /etc/nginx
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" backend/package.json
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" frontend/package.json
sed -i 's+^daemon+#daemon+g' docker/rootfs/etc/nginx/nginx.conf
NGINX_CONFS=$(find "$(pwd)" -type f -name "*.conf")
for NGINX_CONF in $NGINX_CONFS; do
  sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "$NGINX_CONF"
done

mkdir -p /var/www/html /etc/nginx/logs
cp -r docker/rootfs/var/www/html/* /var/www/html/
cp -r docker/rootfs/etc/nginx/* /etc/nginx/
cp docker/rootfs/etc/letsencrypt.ini /etc/letsencrypt.ini
cp docker/rootfs/etc/logrotate.d/nginx-proxy-manager /etc/logrotate.d/nginx-proxy-manager
ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf
rm -f /etc/nginx/conf.d/dev.conf

mkdir -p /tmp/nginx/body \
  /run/nginx \
  /data/nginx \
  /data/custom_ssl \
  /data/logs \
  /data/access \
  /data/nginx/default_host \
  /data/nginx/default_www \
  /data/nginx/proxy_host \
  /data/nginx/redirection_host \
  /data/nginx/stream \
  /data/nginx/dead_host \
  /data/nginx/temp \
  /var/lib/nginx/cache/public \
  /var/lib/nginx/cache/private \
  /var/cache/nginx/proxy_temp

chmod -R 777 /var/cache/nginx
chown root /tmp/nginx

echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" >/etc/nginx/conf.d/include/resolvers.conf

if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" -keyout /data/nginx/dummykey.pem -out /data/nginx/dummycert.pem &>/dev/null
fi

mkdir -p /app/global /app/frontend/images
cp -r backend/* /app
cp -r global/* /app/global
echo "Environment setup complete"

echo "Building Frontend..."
cd frontend
pnpm install
pnpm upgrade
pnpm run build
cp -r dist/* /app/frontend
cp -r app-images/* /app/frontend/images
echo "Frontend build complete"

echo "Building Backend..."
rm -rf /app/config/default.json
if [ ! -f /app/config/production.json ]; then
  cat <<'EOF' >/app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
fi
cd /app
pnpm install
echo "Backend build complete"

echo "Setting up Service"
cat <<'EOF' >/lib/systemd/system/npm.service
[Unit]
Description=Nginx Proxy Manager
After=network.target
Wants=openresty.service

[Service]
Type=simple
Environment=NODE_ENV=production
ExecStartPre=-mkdir -p /tmp/nginx/body /data/letsencrypt-acme-challenge
ExecStart=/usr/bin/node index.js --abort_on_uncaught_exception --max_old_space_size=250
WorkingDirectory=/app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
echo "Successfully setup service"

echo "Starting Nginx Proxy Manager..."
sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf
sed -r -i 's/^([[:space:]]*)su npm npm/\1#su npm npm/g;' /etc/logrotate.d/nginx-proxy-manager
sed -i 's/include-system-site-packages = false/include-system-site-packages = true/g' /opt/certbot/pyvenv.cfg
systemctl enable -q --now openresty
systemctl enable -q --now npm
echo "Successfully started Nginx Proxy Manager"

echo "Performing cleanup..."
rm -rf ../nginx-proxy-manager-*
systemctl restart openresty
apt-get -y autoremove
apt-get -y autoclean
echo "Cleanup complete"

IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "The app is running on port 81. You can access it at http://${IP_ADDRESS}:81"
echo "The default credentials are:"
echo "Username: admin@example.com"
echo "Password: changeme"

# Install Certbot and detect if error occures
install_certbot_dns_multi() {
  echo "Attempting to install certbot-dns-multi..."
  pip3 install certbot-dns-multi 2>&1 | tee pip_output.log
  local exit_code=${PIPESTATUS[0]} # Get the exit code of the pip command

  # Check if the error is in the output
  if grep -q "externally-managed-environment" pip_output.log; then
    echo "Detected externally-managed-environment error. Command will run again with --break-system-packages option."
    pip3 install certbot-dns-multi --break-system-packages
  elif [ $exit_code -ne 0 ]; then
    echo "Error installing certbot-dns-multi. Exiting..."
    exit $exit_code
  else
    echo "Successfully installed certbot-dns-multi."
  fi

  rm -f pip_output.log
}