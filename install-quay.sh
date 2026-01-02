#!/bin/bash
set -e

# Native Quay Mirror Registry Install Script for Fedora 43
# Uses pyenv to install compatible Python version
#
# Usage: bash install-quay.sh
#
# This script installs Quay registry natively (not in containers) on Fedora 43.
# It handles several compatibility issues with Fedora 43's newer toolchain.

PYTHON_VERSION="3.12.7"
NODE_VERSION="22"
QUAY_ROOT="/var/lib/quay"
QUAY_INSTALL="/opt/quay"
QUAY_PORT="80"

echo "=== Installing system dependencies ==="
dnf install -y \
    git curl gcc gcc-c++ make \
    postgresql-server postgresql-contrib nginx \
    openssl-devel libffi-devel zlib-devel bzip2-devel \
    readline-devel sqlite-devel xz-devel \
    libxml2-devel libxslt-devel openldap-devel \
    libjpeg-turbo-devel libwebp-devel freetype-devel \
    libpq-devel file-devel libuuid-devel

# Fedora 43 uses valkey (Redis fork) instead of redis
dnf install -y valkey || dnf install -y redis

echo "=== Installing Node.js ==="
dnf install -y nodejs npm || {
    curl -fsSL https://rpm.nodesource.com/setup_${NODE_VERSION}.x | bash -
    dnf install -y nodejs
}

echo "=== Installing pyenv ==="
if [ ! -d "$HOME/.pyenv" ]; then
    curl https://pyenv.run | bash
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

echo "=== Installing Python $PYTHON_VERSION ==="
# Build without tkinter (not needed for Quay, avoids Tcl compatibility issues on Fedora 43)
PYTHON_CONFIGURE_OPTS="--disable-tk" pyenv install -s $PYTHON_VERSION
pyenv global $PYTHON_VERSION

echo "=== Verifying Python version ==="
python --version

echo "=== Initializing PostgreSQL ==="
postgresql-setup --initdb || true
# Enable and start services (valkey on Fedora 43, redis on older)
systemctl enable postgresql
systemctl start postgresql
systemctl enable valkey 2>/dev/null || systemctl enable redis 2>/dev/null || true
systemctl start valkey 2>/dev/null || systemctl start redis 2>/dev/null || true

echo "=== Creating Quay database ==="
sudo -u postgres psql -c "CREATE USER quay WITH PASSWORD 'quaypass';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE quay OWNER quay;" 2>/dev/null || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE quay TO quay;" 2>/dev/null || true
# Enable pg_trgm extension for full-text search (requires postgresql-contrib)
sudo -u postgres psql -d quay -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" 2>/dev/null || true

# Update pg_hba.conf for local connections (IPv4 and IPv6)
# IMPORTANT: quay-specific rules must come BEFORE general "all all" rules
PG_HBA=$(sudo -u postgres psql -t -c "SHOW hba_file;" | tr -d ' ')
if ! grep -q "host.*quay.*quay.*md5" "$PG_HBA"; then
    # Insert quay rules before the general "all all" rules
    sed -i '/^host[[:space:]]*all[[:space:]]*all[[:space:]]*127.0.0.1/i host    quay    quay    127.0.0.1/32    md5' "$PG_HBA"
    sed -i '/^host[[:space:]]*all[[:space:]]*all[[:space:]]*::1/i host    quay    quay    ::1/128         md5' "$PG_HBA"
fi
systemctl reload postgresql

echo "=== Cloning Quay ==="
if [ ! -d "$QUAY_INSTALL" ]; then
    git clone --depth 1 https://github.com/quay/quay.git $QUAY_INSTALL
fi

echo "=== Creating Python virtual environment ==="
cd $QUAY_INSTALL
# Explicitly use pyenv's Python to create the venv (not system Python 3.14)
$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python -m venv venv
source venv/bin/activate
pip install --upgrade pip wheel setuptools

echo "=== Installing Quay dependencies ==="
# Fix reportlab version - 3.6.x fails to compile on Fedora 43 (GCC C23 bool keyword)
sed -i 's/reportlab==3.6.13/reportlab>=4.0/' requirements.txt
pip install --prefer-binary -r requirements.txt

# Upgrade xhtml2pdf for reportlab 4.x compatibility
pip install --upgrade xhtml2pdf

echo "=== Building frontend ==="
cd $QUAY_INSTALL
npm install
# Node.js 22 requires legacy OpenSSL provider for webpack
# Increase heap size for webpack build (requires ~3GB RAM)
NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=3072" npm run build

echo "=== Generating secrets ==="
SECRET_KEY=$(openssl rand -hex 32)
DB_SECRET_KEY=$(openssl rand -hex 32)

echo "=== Creating Quay config ==="
mkdir -p $QUAY_ROOT/config
mkdir -p $QUAY_ROOT/storage
# Quay loads config from conf/stack/ directory
mkdir -p $QUAY_INSTALL/conf/stack

cat > $QUAY_INSTALL/conf/stack/config.yaml << EOF
TESTING: false
AUTHENTICATION_TYPE: Database
BUILDLOGS_REDIS:
    host: localhost
    port: 6379
DATABASE_SECRET_KEY: "${DB_SECRET_KEY}"
DB_URI: postgresql://quay:quaypass@localhost/quay
DEFAULT_TAG_EXPIRATION: 2w
DISTRIBUTED_STORAGE_CONFIG:
    default:
        - LocalStorage
        - storage_path: /var/lib/quay/storage
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
DISTRIBUTED_STORAGE_PREFERENCE:
    - default
FEATURE_BUILD_SUPPORT: false
FEATURE_DIRECT_LOGIN: true
FEATURE_MAILING: false
FEATURE_REQUIRE_TEAM_INVITE: true
FEATURE_SECURITY_NOTIFICATIONS: false
FEATURE_USER_CREATION: true
PREFERRED_URL_SCHEME: http
REGISTRY_TITLE: Quay Container Registry
REGISTRY_TITLE_SHORT: Quay
SECRET_KEY: "${SECRET_KEY}"
SERVER_HOSTNAME: registry.gw.lo
SETUP_COMPLETE: true
SUPER_USERS:
    - admin
TAG_EXPIRATION_OPTIONS:
    - 0s
    - 1d
    - 1w
    - 2w
    - 4w
USER_EVENTS_REDIS:
    host: localhost
    port: 6379
EOF

# Keep a copy in QUAY_ROOT for reference
cp $QUAY_INSTALL/conf/stack/config.yaml $QUAY_ROOT/config/config.yaml

echo "=== Creating systemd service ==="
cat > /etc/systemd/system/quay.service << EOF
[Unit]
Description=Quay Container Registry
After=network.target postgresql.service valkey.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=$QUAY_INSTALL
ExecStart=$QUAY_INSTALL/venv/bin/gunicorn -b 127.0.0.1:8080 -w 4 --timeout 300 web:application
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "=== Configuring nginx ==="
cat > /etc/nginx/conf.d/quay.conf << 'EOF'
server {
    listen 80;
    server_name registry.gw.lo;

    client_max_body_size 8G;

    location /static/ {
        alias /opt/quay/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

# Remove default nginx config if exists
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

systemctl daemon-reload
systemctl enable quay
systemctl enable nginx

echo "=== Running database migrations ==="
cd $QUAY_INSTALL
source venv/bin/activate
PYTHONPATH=$QUAY_INSTALL alembic upgrade head

echo "=== Creating admin user ==="
PYTHONPATH=$QUAY_INSTALL python -c "
from app import app
from data import model
from data.database import configure

with app.app_context():
    configure(app.config)
    try:
        user = model.user.create_user('admin', 'admin123', 'admin@registry.gw.lo')
        user.verified = True
        user.save()
        print(f'Created admin user: {user.username}')
    except Exception as e:
        print(f'Admin user may already exist: {e}')
"
# Ensure admin user is verified (in case user already existed)
sudo -u postgres psql -d quay -c "UPDATE \"user\" SET verified = true WHERE username = 'admin';" 2>/dev/null || true

echo "=== Starting services ==="
systemctl start quay
systemctl start nginx

# Wait for startup
sleep 5

# Verify
if curl -s -o /dev/null -w '%{http_code}' http://localhost:${QUAY_PORT}/ | grep -q 200; then
    echo ""
    echo "=== Installation Complete ==="
    echo "Quay is running on http://registry.gw.lo"
    echo ""
    echo "Default login:"
    echo "  Username: admin"
    echo "  Password: admin123"
    echo ""
    echo "Check status: systemctl status quay nginx"
    echo "View logs: journalctl -u quay -f"
else
    echo ""
    echo "=== Installation may have issues ==="
    echo "Check logs: journalctl -u quay -f"
    echo "Check nginx: journalctl -u nginx -f"
fi
