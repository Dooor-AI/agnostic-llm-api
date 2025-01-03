#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit
fi

# Environment Variables
APP_USER="llmuser"
APP_DIR="/opt/llm-app"
DOMAIN_NAME="llm-app.techreport.ai"  # Update to your domain
API_KEY="your_api_key_here"  # Update to your API key
EMAIL="blaureanosantos@gmail.com"    # Update to your email
HF_TOKEN="your_hf_token_here"  # Add this line

# List of models to download
MODELS=(
    "qwen2.5:32b"
    "nomic-embed-text:latest"
)

apt update && apt upgrade -y

# Remove conflicting certbot installations
pip uninstall certbot -y
pip3 uninstall certbot -y
pip uninstall zope.interface -y
pip3 uninstall zope.interface -y
pip uninstall zope.component -y
pip3 uninstall zope.component -y
apt remove --purge certbot -y

# Install necessary packages
apt install -y python3-pip python3-venv nginx snapd curl git

# Install and configure certbot
snap install core
snap refresh core
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

# Install Ollama
curl -O https://ollama.ai/install.sh
chmod +x install.sh
./install.sh

if ! command -v ollama &> /dev/null; then
    echo "Error: Ollama not installed correctly."
    exit 1
fi

# Create systemd service for Ollama
cat > /etc/systemd/system/ollama.service <<EOL
[Unit]
Description=Ollama Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable ollama.service
systemctl start ollama.service

if systemctl is-active --quiet ollama.service; then
    echo "Ollama is running."
else
    echo "Error initiating Ollama."
    exit 1
fi

# Create application user and directory
if id "$APP_USER" &>/dev/null; then
    echo "User $APP_USER already exists."
else
    useradd -m -s /bin/bash "$APP_USER"
fi

if [ -d "$APP_DIR" ]; then
    echo "Directory $APP_DIR already exists."
else
    mkdir -p "$APP_DIR"
    chown "$APP_USER":"$APP_USER" "$APP_DIR"
fi

# Clone or update application repository
if [ -d "$APP_DIR/.git" ]; then
    echo "Repository already cloned at $APP_DIR. Updating..."
    su - "$APP_USER" -c "
        cd $APP_DIR
        git pull
    "
else
    su - "$APP_USER" -c "
        git clone https://github.com/bruno353/agnostic-llm-api.git $APP_DIR
    "
fi

su - "$APP_USER" -c "
    cd $APP_DIR
    git fetch origin
    git reset --hard origin/main
"

# Install ffmpeg
apt update && apt install ffmpeg -y

# Install Rust (required for tiktoken)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env

# Setup Python virtual environment and install dependencies
su - "$APP_USER" -c "
    cd $APP_DIR
    python3 -m venv venv
    source venv/bin/activate
    pip install -U pip setuptools-rust
    pip install -r requirements.txt
"

# Create systemd service for the Flask app
cat > /etc/systemd/system/llm-app.service <<EOL
[Unit]
Description=LLM Python Flask Application Service
After=network.target ollama.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -w 4 -b 0.0.0.0:8080 --timeout 6000 app:app
Environment=API_KEY=$API_KEY
Environment=HF_TOKEN=$HF_TOKEN
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable llm-app.service
systemctl start llm-app.service

# Configure Nginx
if command -v ufw >/dev/null 2>&1; then
    ufw allow 'Nginx Full'
fi

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/llm-app.conf
rm -f /etc/nginx/sites-enabled/llm-app.conf

cat > /etc/nginx/sites-available/llm-app.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

ln -s /etc/nginx/sites-available/llm-app.conf /etc/nginx/sites-enabled/

nginx -t && systemctl restart nginx

if systemctl is-active --quiet nginx; then
    echo "Nginx is running."
else
    echo "Error starting Nginx."
    exit 1
fi

# Obtain SSL certificate with certbot
systemctl stop nginx
certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$EMAIL"
systemctl start nginx

# Configure Nginx with SSL
cat > /etc/nginx/sites-available/llm-app.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    client_max_body_size 10M;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
}
EOL

nginx -t && systemctl restart nginx

echo "Server setup completed successfully!"

# Function to download models
download_model() {
    local model=$1
    echo "Downloading model: $model"
    ollama pull $model
    if [ $? -eq 0 ]; then
        echo "Model $model downloaded successfully."
    else
        echo "Error downloading model $model."
    fi
}

# Download models
echo "Starting model downloads..."
for model in "${MODELS[@]}"; do
    download_model $model
done

# Verify models
echo "Verifying downloaded models..."
all_models_downloaded=true
for model in "${MODELS[@]}"; do
    if ! ollama list | grep -q "$model"; then
        echo "Model $model not found."
        all_models_downloaded=false
    fi
done

if $all_models_downloaded; then
    echo "All models downloaded successfully."
else
    echo "Some models failed to download. Please check manually."
fi
