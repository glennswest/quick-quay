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
    postgresql-server postgresql-contrib nginx openssl \
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

echo "=== Patching web.py to enable v2 registry API ==="
cat > $QUAY_INSTALL/web.py << 'WEBPY'
from app import app as application
from endpoints.api import api_bp
from endpoints.bitbuckettrigger import bitbuckettrigger
from endpoints.githubtrigger import githubtrigger
from endpoints.gitlabtrigger import gitlabtrigger
from endpoints.keyserver import key_server
from endpoints.oauth.login import oauthlogin
from endpoints.oauth.robot_identity_federation import federation_bp
from endpoints.realtime import realtime
from endpoints.web import web
from endpoints.webhooks import webhooks
from endpoints.wellknown import wellknown
from endpoints.v2 import v2_bp
from endpoints.v1 import v1_bp

application.register_blueprint(web)
application.register_blueprint(githubtrigger, url_prefix="/oauth2")
application.register_blueprint(gitlabtrigger, url_prefix="/oauth2")
application.register_blueprint(oauthlogin, url_prefix="/oauth2")
application.register_blueprint(federation_bp, url_prefix="/oauth2")
application.register_blueprint(bitbuckettrigger, url_prefix="/oauth1")
application.register_blueprint(api_bp, url_prefix="/api")
application.register_blueprint(webhooks, url_prefix="/webhooks")
application.register_blueprint(realtime, url_prefix="/realtime")
application.register_blueprint(key_server, url_prefix="/keys")
application.register_blueprint(wellknown, url_prefix="/.well-known")
application.register_blueprint(v2_bp, url_prefix="/v2")
application.register_blueprint(v1_bp, url_prefix="/v1")
WEBPY

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

echo "=== Generating TLS certificates ==="
mkdir -p /certs
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /certs/registry.key -out /certs/registry.crt \
    -subj "/CN=registry.gw.lo" \
    -addext "subjectAltName=DNS:registry.gw.lo"
chmod 600 /certs/registry.key

echo "=== Generating secrets ==="
SECRET_KEY=$(openssl rand -hex 32)
DB_SECRET_KEY=$(openssl rand -hex 32)

echo "=== Creating Quay config ==="
mkdir -p $QUAY_ROOT/config
mkdir -p $QUAY_ROOT/storage
# Quay loads config from conf/stack/ directory
mkdir -p $QUAY_INSTALL/conf/stack

echo "=== Generating instance keys for JWT authentication ==="
cd $QUAY_INSTALL/conf
openssl genrsa -out quay.pem 2048
openssl rsa -in quay.pem -pubout -out quay.pub
# Key ID must not have trailing newline for proper JWT token matching
echo -n "quay-$(date +%s)" > quay.kid
chmod 600 quay.pem

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
PREFERRED_URL_SCHEME: https
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
FEATURE_LOG_EXPORTS: true
FEATURE_ACTION_LOG_ROTATION: true
INSTANCE_SERVICE_KEY_KID_LOCATION: /opt/quay/conf/quay.kid
INSTANCE_SERVICE_KEY_LOCATION: /opt/quay/conf/quay.pem
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

echo "=== Building React UI (beta) ==="
cd $QUAY_INSTALL/web
npm install
ASSET_PATH=/ REACT_QUAY_APP_API_URL=https://registry.gw.lo REACT_APP_QUAY_DOMAIN=registry.gw.lo \
    NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=3072" npm run build

echo "=== Patching endpoints for React UI support ==="
# Add /switch-to-old-ui endpoint and cookie-based UI switching to web.py
cd $QUAY_INSTALL
cat > /tmp/patch_web.py << 'PATCHEOF'
import re

with open('endpoints/web.py', 'r') as f:
    content = f.read()

# Add switch-to-old-ui endpoint before signin route
switch_endpoint = '''
@web.route("/switch-to-old-ui")
@no_cache
def switch_to_old_ui():
    from flask import redirect, make_response
    resp = make_response(redirect("/"))
    resp.set_cookie("patternfly", "", expires=0, path="/")
    return resp

'''

# Find the signin route and insert before it
if '/switch-to-old-ui' not in content:
    content = re.sub(
        r'(@web\.route\("/signin/"\))',
        switch_endpoint + r'\1',
        content
    )

# Modify index() to serve React UI based on patternfly cookie
old_index = '''@web.route("/", methods=["GET"], defaults={"path": ""})
@no_cache
def index(path, **kwargs):
    return render_page_template_with_routedata("index.html", **kwargs)'''

new_index = '''@web.route("/", methods=["GET"], defaults={"path": ""})
@no_cache
def index(path, **kwargs):
    from flask import request, send_from_directory
    # Check patternfly cookie for React UI preference
    patternfly_cookie = request.cookies.get("patternfly", "")
    use_react = patternfly_cookie in ["true", "react"]
    if not patternfly_cookie:
        use_react = app.config.get("DEFAULT_UI", "angular").lower() == "react"
    if use_react:
        return send_from_directory("/opt/quay/web/dist", "index.html")
    return render_page_template_with_routedata("index.html", **kwargs)'''

if 'patternfly_cookie' not in content:
    content = content.replace(old_index, new_index)

with open('endpoints/web.py', 'w') as f:
    f.write(content)

print('Patched endpoints/web.py')
PATCHEOF
python /tmp/patch_web.py

# Patch React UI logout to clear cookie and return to Angular UI
cat > /tmp/patch_react.py << 'PATCHEOF'
import re

toolbar_file = '/opt/quay/web/src/components/header/HeaderToolbar.tsx'
with open(toolbar_file, 'r') as f:
    content = f.read()

# Replace the logout redirect to clear cookie and go to root
old_redirect = "window.location.href = '/signin';"
new_redirect = '''// Delete cookie completely to disable React UI
          document.cookie = "patternfly=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;";
          setTimeout(() => { window.location.href = '/'; }, 200);'''

if 'patternfly' not in content:
    content = content.replace(old_redirect, new_redirect)
    with open(toolbar_file, 'w') as f:
        f.write(content)
    print('Patched HeaderToolbar.tsx')
else:
    print('HeaderToolbar.tsx already patched')
PATCHEOF
python /tmp/patch_react.py

# Rebuild React UI with the patch
cd $QUAY_INSTALL/web
ASSET_PATH=/ REACT_QUAY_APP_API_URL=https://registry.gw.lo REACT_APP_QUAY_DOMAIN=registry.gw.lo \
    NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=3072" npm run build

echo "=== Configuring nginx ==="
cat > /etc/nginx/conf.d/quay.conf << 'EOF'
server {
    listen 80;
    server_name registry.gw.lo;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl;
    server_name registry.gw.lo;

    ssl_certificate /certs/registry.crt;
    ssl_certificate_key /certs/registry.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 8G;

    # React UI static assets (only main and vendor bundles at root)
    location = /main.bundle.js {
        root /opt/quay/web/dist;
        try_files $uri =404;
    }
    location = /vendor.bundle.js {
        root /opt/quay/web/dist;
        try_files $uri =404;
    }
    location = /main.css {
        root /opt/quay/web/dist;
        try_files $uri =404;
    }
    location = /vendor.css {
        root /opt/quay/web/dist;
        try_files $uri =404;
    }

    # React UI images/assets
    location /images/ {
        alias /opt/quay/web/dist/images/;
    }

    location /assets/ {
        alias /opt/quay/web/dist/assets/;
    }

    # Legacy static files (Angular)
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

echo "=== Creating storage location and registering service key ==="
PYTHONPATH=$QUAY_INSTALL python -c "
import json
import datetime
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
from jwkest.jwk import RSAKey
from app import app
from data import model
from data.database import configure, ImageStorageLocation

with app.app_context():
    configure(app.config)

    # Create 'default' storage location if it doesn't exist
    try:
        loc = ImageStorageLocation.get(ImageStorageLocation.name == 'default')
        print('Storage location default already exists')
    except ImageStorageLocation.DoesNotExist:
        ImageStorageLocation.create(name='default')
        print('Created storage location: default')

    # Read the service key files
    with open('/opt/quay/conf/quay.pem', 'rb') as f:
        private_key_pem = f.read()
    with open('/opt/quay/conf/quay.kid', 'r') as f:
        kid = f.read().strip()

    # Check if service key already exists
    existing = model.service_keys.get_service_key(kid, approved_only=False)
    if existing:
        print(f'Service key {kid} already exists')
    else:
        # Convert PEM to JWK
        private_key = serialization.load_pem_private_key(
            private_key_pem, password=None, backend=default_backend()
        )
        public_key = private_key.public_key()
        public_pem = public_key.public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo
        )
        rsa_key = RSAKey(use='sig')
        rsa_key.load_key(public_key)
        jwk = rsa_key.serialize(private=False)

        # Create and approve the service key
        expiration = datetime.datetime.utcnow() + datetime.timedelta(days=3650)
        key = model.service_keys.create_service_key(
            name='Quay Instance Key',
            kid=kid,
            service='quay',
            jwk=jwk,
            metadata={},
            expiration_date=expiration
        )
        model.service_keys.approve_service_key(kid, 'automatic', notes='Auto-approved during install')
        print(f'Created and approved service key: {kid}')
"

echo "=== Creating openshift organization ==="
PYTHONPATH=$QUAY_INSTALL python -c "
from app import app
from data import model
from data.database import configure

with app.app_context():
    configure(app.config)

    # Get admin user
    admin = model.user.get_user('admin')
    if not admin:
        print('Error: admin user not found')
        exit(1)

    # Check if openshift org already exists
    existing = model.organization.get_organization('openshift')
    if existing:
        print('Organization openshift already exists')
    else:
        org = model.organization.create_organization('openshift', 'openshift@registry.gw.lo', admin)
        print(f'Created organization: {org.username}')
"

echo "=== Starting services ==="
systemctl start quay
systemctl start nginx

# Wait for startup
sleep 5

# Verify
if curl -sk -o /dev/null -w '%{http_code}' https://localhost/ | grep -q 200; then
    echo ""
    echo "=== Installation Complete ==="
    echo "Quay is running on https://registry.gw.lo"
    echo "TLS certificate at /certs/registry.crt"
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
