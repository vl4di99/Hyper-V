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
echo "Installing Basic Dependencies..."
apt-get update
apt-get install -y build-essential cargo git gnupg make sudo

echo "Installing Node.js..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs
npm i -g yarn

echo "Installing Rust"
curl -fsSL https://sh.rustup.rs -o rustup-init.sh
bash rustup-init.sh -y --profile minimal
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.cargo/bin:$PATH"
rm rustup-init.sh
cargo install monolith

echo "Installing PostgreSQL..."
apt-get install -y postgresql
DB_NAME=linkwardendb
DB_USER=linkwarden
DB_PASS="$(openssl rand -base64 18 | tr -d '/' | cut -c1-13)"
SECRET_KEY="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC';"
{
  echo "Linkwarden-Credentials"
  echo "Linkwarden Database User: $DB_USER"
  echo "Linkwarden Database Password: $DB_PASS"
  echo "Linkwarden Database Name: $DB_NAME"
  echo "Linkwarden Secret: $SECRET_KEY"
} >>~/linkwarden.creds

echo "Installing Linkwarden..."
cd /opt
RELEASE=$(curl -fsSL https://api.github.com/repos/linkwarden/linkwarden/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
curl -fsSL "https://github.com/linkwarden/linkwarden/archive/refs/tags/${RELEASE}.zip" -o $(basename "https://github.com/linkwarden/linkwarden/archive/refs/tags/${RELEASE}.zip")
unzip -q ${RELEASE}.zip
mv linkwarden-${RELEASE:1} /opt/linkwarden
cd /opt/linkwarden
yarn
npx playwright install-deps
yarn playwright install
IP=$(hostname -I | awk '{print $1}')
env_path="/opt/linkwarden/.env"
echo " 
NEXTAUTH_SECRET=${SECRET_KEY}
NEXTAUTH_URL=http://${IP}:3000
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
" >$env_path
yarn build
yarn prisma migrate deploy
echo "${RELEASE}" > /opt/linkwarden_version.txt

echo "Creating service..."
cat <<EOF >/etc/systemd/system/linkwarden.service
[Unit]
Description=Linkwarden Service
After=network.target

[Service]
Type=exec
Environment=PATH=$PATH
WorkingDirectory=/opt/linkwarden
ExecStart=/usr/bin/yarn start

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now linkwarden
rm -rf /opt/${RELEASE}.zip

sudo apt-get -y autoremove
sudo apt-get -y autoclean

echo "Linkwarden has been installed successfully."
echo "The app is running on port 3000. You can access it at http://${IP}:3000"

echo "The default credentials are:"
echo "Username: admin@example.com"
echo "Password: changeme"

exit 0
