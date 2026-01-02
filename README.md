# Native Quay Container Registry Installation

This project provides scripts and documentation for installing the full Quay container registry **natively** on Fedora 43 (without containers or VMs).

## Overview

Quay is Red Hat's enterprise container registry. While typically deployed as containers, this project runs Quay as a native Python application with PostgreSQL and Valkey (Redis) backends.

**Note:** This is the full Quay installation with all features - not the simplified "mirror-registry" tool. Features include repository mirroring, organizations, teams, robot accounts, quota management, audit logging, and more.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     registry.gw.lo (LXC)                        │
│                       Fedora 43                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │   Quay Web UI   │    │  Quay Registry  │                    │
│  │    Port 80      │    │     API         │                    │
│  └────────┬────────┘    └────────┬────────┘                    │
│           │                      │                              │
│           └──────────┬───────────┘                              │
│                      │                                          │
│           ┌──────────▼──────────┐                              │
│           │       nginx         │                              │
│           │   (Reverse Proxy)   │                              │
│           │     Port 80         │                              │
│           └──────────┬──────────┘                              │
│                      │                                          │
│           ┌──────────▼──────────┐                              │
│           │      Gunicorn       │                              │
│           │   (WSGI Server)     │                              │
│           │   127.0.0.1:8080    │                              │
│           │   4 workers         │                              │
│           └──────────┬──────────┘                              │
│                      │                                          │
│    ┌─────────────────┼─────────────────┐                       │
│    │                 │                 │                        │
│    ▼                 ▼                 ▼                        │
│ ┌──────┐      ┌───────────┐    ┌─────────────┐                │
│ │Valkey│      │PostgreSQL │    │ Local       │                │
│ │:6379 │      │  :5432    │    │ Storage     │                │
│ │      │      │           │    │             │                │
│ │Cache │      │ quay DB   │    │/var/lib/quay│                │
│ │Queue │      │           │    │  /storage   │                │
│ └──────┘      └───────────┘    └─────────────┘                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Python Environment:
┌─────────────────────────────────────────┐
│  pyenv (Python 3.12.7)                  │
│  └── /opt/quay/venv (Virtual Env)       │
│       └── Quay + Dependencies           │
└─────────────────────────────────────────┘
```

### Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Quay | Latest (main) | Container registry application |
| Python | 3.12.7 (pyenv) | Runtime for Quay |
| PostgreSQL | 18.x | Database for registry metadata |
| Valkey | 8.x | Redis-compatible cache/queue |
| Gunicorn | 23.x | WSGI HTTP server |
| nginx | latest | Reverse proxy for static files |
| Node.js | 22.x | Frontend build toolchain |

### Directory Structure

```
/opt/quay/                  # Quay application
├── venv/                   # Python virtual environment
├── conf/
│   └── stack/
│       └── config.yaml     # Quay configuration (active)
├── static/                 # Built frontend assets
├── requirements.txt        # Python dependencies
└── web.py                  # WSGI entry point

/var/lib/quay/              # Quay data
├── config/
│   └── config.yaml         # Configuration backup
└── storage/                # Container image storage

/etc/systemd/system/
└── quay.service            # Systemd service unit

/etc/nginx/conf.d/
└── quay.conf               # nginx reverse proxy config

/root/.pyenv/               # pyenv installation
└── versions/3.12.7/        # Python 3.12.7
```

## Installation

### Prerequisites

- Fedora 43 (or compatible) system
- Root access
- Network connectivity for package downloads
- Adequate storage for container images

### Quick Start

```bash
# Copy script to target system
scp install-quay.sh root@registry.gw.lo:/root/

# Run installation
ssh root@registry.gw.lo "bash /root/install-quay.sh"
```

### Post-Installation

```bash
# Check service status
systemctl status quay nginx

# View logs
journalctl -u quay -f

# Access web UI
curl http://registry.gw.lo/
```

### Default Login

| Field | Value |
|-------|-------|
| URL | http://registry.gw.lo/ |
| Username | `admin` |
| Password | `admin123` |

**Change the password after first login.**

## Issues and Solutions

This section documents the compatibility issues encountered when installing Quay natively on Fedora 43 and how they were resolved.

### Issue 1: Python 3.14 Package Incompatibility

**Problem:** Fedora 43 ships with Python 3.14, but many Quay dependencies don't have pre-built wheels for Python 3.14, causing compilation failures.

**Affected packages:**
- pillow
- grpcio
- psycopg2
- lxml
- reportlab
- Various others

**Error example:**
```
ERROR: Failed to build 'pillow' when getting requirements to build wheel
```

**Solution:** Use pyenv to install Python 3.12.7, which has broad package compatibility:
```bash
PYTHON_CONFIGURE_OPTS="--disable-tk" pyenv install -s 3.12.7
pyenv global 3.12.7
```

---

### Issue 2: Tcl/Tk Build Failure with Python 3.12

**Problem:** When building Python 3.12 via pyenv on Fedora 43, the Tcl/Tk module fails to compile due to incompatibility between Fedora 43's newer Tcl libraries and Python's expected API.

**Error:**
```
*** Could not build the tkinter module
```

**Solution:** Disable Tkinter during Python build (not needed for Quay):
```bash
PYTHON_CONFIGURE_OPTS="--disable-tk" pyenv install -s 3.12.7
```

---

### Issue 3: Virtual Environment Uses Wrong Python

**Problem:** Even after installing Python 3.12.7 via pyenv, running `python -m venv` created a venv with the system Python 3.14.

**Evidence:**
```
/opt/quay/venv/lib64/python3.14/site-packages/...
```

**Solution:** Explicitly use pyenv's Python binary to create the venv:
```bash
$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python -m venv venv
```

---

### Issue 4: reportlab 3.6.13 Compilation Failure (C23 bool keyword)

**Problem:** Fedora 43's GCC defaults to C23 standard where `bool` is a reserved keyword. The reportlab 3.6.13 C extension uses `bool` as a variable name, causing compilation errors.

**Error:**
```c
src/rl_addons/renderPM/gt1/gt1-parset1.c:1606:13: error: 'bool' cannot be used here
    int bool;
        ^~~~
note: 'bool' is a keyword with '-std=c23' onwards
```

**Solution:** Update requirements.txt to use reportlab 4.x which provides pre-built wheels:
```bash
sed -i 's/reportlab==3.6.13/reportlab>=4.0/' requirements.txt
```

---

### Issue 5: xhtml2pdf Incompatibility with reportlab 4.x

**Problem:** After upgrading reportlab to 4.x, xhtml2pdf 0.2.6 fails because it imports `ShowBoundaryValue` which was removed in reportlab 4.

**Error:**
```python
ImportError: cannot import name 'ShowBoundaryValue' from 'reportlab.platypus.frames'
```

**Solution:** Upgrade xhtml2pdf to a version compatible with reportlab 4.x:
```bash
pip install --upgrade xhtml2pdf
```

---

### Issue 6: Redis vs Valkey Service Name

**Problem:** Fedora 43 replaced Redis with Valkey (a Redis fork). Scripts using `systemctl start redis` fail.

**Error:**
```
Unit redis.service not found.
```

**Solution:** Handle both service names with fallback:
```bash
systemctl enable valkey 2>/dev/null || systemctl enable redis 2>/dev/null || true
systemctl start valkey 2>/dev/null || systemctl start redis 2>/dev/null || true
```

---

### Issue 7: Quay TESTING Mode Warning

**Problem:** Quay logs show "TESTING: true" warnings even in production.

**Logs:**
```
🟡🟡🟡 Detected TESTING: true on startup
🟡🟡🟡 Quay starting in TESTING mode
```

**Solution:** Explicitly set `TESTING: false` in config.yaml:
```yaml
TESTING: false
AUTHENTICATION_TYPE: Database
...
```

---

### Issue 8: Gunicorn Doesn't Serve Static Files

**Problem:** Accessing the Quay web UI shows "Application unloaded" error because Gunicorn (WSGI server) doesn't serve static files - it only handles Python application requests.

**Error:**
```
The Quay application could not be loaded, which typically indicates an external
library could not be loaded (usually due to an ad blocker).
```

**Solution:** Add nginx as a reverse proxy to serve static files:
```nginx
server {
    listen 80;
    server_name registry.gw.lo;

    location /static/ {
        alias /opt/quay/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

### Issue 9: Frontend Not Built

**Problem:** The Quay git repository doesn't include pre-built frontend assets. The `/static/` directory is empty or missing.

**Solution:** Build the frontend using npm:
```bash
cd /opt/quay
npm install
npm run build
```

---

### Issue 10: Node.js 22 OpenSSL Error

**Problem:** Building the frontend with Node.js 22 fails due to OpenSSL changes affecting webpack.

**Error:**
```
Error: error:0308010C:digital envelope routines::unsupported
```

**Solution:** Use the legacy OpenSSL provider:
```bash
NODE_OPTIONS=--openssl-legacy-provider npm run build
```

---

### Issue 11: Config Directory Location

**Problem:** Setting `QUAY_CONFIG` environment variable doesn't work. Quay shows "Your configuration is not setup yet" even with valid config.yaml.

**Root cause:** Quay's `_init.py` loads config from `OVERRIDE_CONFIG_DIRECTORY = os.path.join(CONF_DIR, "stack/")`, not from the `QUAY_CONFIG` environment variable.

**Solution:** Place config.yaml in the correct directory:
```bash
mkdir -p /opt/quay/conf/stack
cp config.yaml /opt/quay/conf/stack/
```

---

### Issue 12: PostgreSQL IPv6 Authentication and Rule Order

**Problem:** Quay fails with "Ident authentication failed for user quay" when connecting to PostgreSQL.

**Error:**
```
peewee.OperationalError: connection to server at "localhost" (::1), port 5432 failed: FATAL:  Ident authentication failed for user "quay"
```

**Root cause:** Two issues:
1. PostgreSQL connects via IPv6 (::1) on dual-stack systems
2. `pg_hba.conf` rules are processed in order - the general `host all all` rules with `ident` auth were matching before the quay-specific `md5` rules

**Solution:** Insert quay-specific rules BEFORE the general "all all" rules:
```bash
# Insert before the IPv4 "all all" line
sed -i '/^host.*all.*all.*127.0.0.1/i host    quay    quay    127.0.0.1/32    md5' $PG_HBA
# Insert before the IPv6 "all all" line
sed -i '/^host.*all.*all.*::1/i host    quay    quay    ::1/128         md5' $PG_HBA
systemctl reload postgresql
```

The resulting order should be:
```
host    quay    quay    127.0.0.1/32    md5    # <- quay first
host    all     all     127.0.0.1/32    ident
host    quay    quay    ::1/128         md5    # <- quay first
host    all     all     ::1/128         ident
```

---

### Issue 13: Missing pg_trgm Extension

**Problem:** Database migrations fail with "operator class gin_trgm_ops does not exist".

**Error:**
```
psycopg2.errors.UndefinedObject: operator class "gin_trgm_ops" does not exist for access method "gin"
```

**Root cause:** Quay uses PostgreSQL full-text search with trigram indexes, which requires the `pg_trgm` extension from `postgresql-contrib`.

**Solution:** Install postgresql-contrib and enable the extension:
```bash
dnf install -y postgresql-contrib
sudo -u postgres psql -d quay -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
```

---

### Issue 14: Webpack Build Out of Memory

**Problem:** Frontend build fails with "JavaScript heap out of memory" error during webpack optimization phase.

**Error:**
```
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
```

**Root cause:** The webpack build requires more memory than Node.js allocates by default, especially during the TerserPlugin optimization phase.

**Solution:** Increase Node.js heap size and ensure system has at least 4GB RAM:
```bash
NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=3072" npm run build
```

---

### Issue 15: Docker Registry v2 API Not Registered

**Problem:** The Docker Registry v2 API endpoints (`/v2/`, `/v2/_catalog`, etc.) return 404 errors. Docker/Podman clients cannot push or pull images.

**Error:**
```
curl http://registry.gw.lo/v2/_catalog
404 Not Found
```

**Root cause:** The upstream `web.py` WSGI entrypoint does not register the `v2_bp` (Docker Registry v2 API) or `v1_bp` (legacy Docker v1 API) blueprints. Only the web UI and OAuth endpoints are registered.

**Solution:** Patch `web.py` to include the registry API blueprints:
```python
from endpoints.v2 import v2_bp
from endpoints.v1 import v1_bp

application.register_blueprint(v2_bp, url_prefix="/v2")
application.register_blueprint(v1_bp, url_prefix="/v1")
```

---

## Configuration

### Quay Configuration (`/opt/quay/conf/stack/config.yaml`)

Key settings:

| Setting | Value | Description |
|---------|-------|-------------|
| `SERVER_HOSTNAME` | registry.gw.lo | Registry hostname |
| `DB_URI` | postgresql://quay:quaypass@localhost/quay | Database connection |
| `FEATURE_USER_CREATION` | true | Allow user self-registration |
| `DISTRIBUTED_STORAGE_CONFIG` | LocalStorage | Use local filesystem |

### Systemd Service (`/etc/systemd/system/quay.service`)

```ini
[Unit]
Description=Quay Container Registry
After=network.target postgresql.service valkey.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/quay
ExecStart=/opt/quay/venv/bin/gunicorn -b 127.0.0.1:8080 -w 4 --timeout 300 web:application
Restart=always

[Install]
WantedBy=multi-user.target
```

### nginx Configuration (`/etc/nginx/conf.d/quay.conf`)

```nginx
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
```

## Management Commands

```bash
# Service management
systemctl start quay nginx
systemctl stop quay nginx
systemctl restart quay nginx
systemctl status quay nginx

# View logs
journalctl -u quay -f
journalctl -u nginx -f
journalctl -u quay --since "1 hour ago"

# Database access
sudo -u postgres psql quay

# Check storage usage
du -sh /var/lib/quay/storage/
```

## Troubleshooting

### Quay won't start

1. Check logs: `journalctl -u quay -n 100`
2. Verify PostgreSQL is running: `systemctl status postgresql`
3. Verify Valkey is running: `systemctl status valkey`
4. Check config syntax: `cat /opt/quay/conf/stack/config.yaml`

### "Configuration not setup" error

1. Verify config is in correct location: `ls -la /opt/quay/conf/stack/`
2. Check `SETUP_COMPLETE: true` is set in config.yaml
3. Restart Quay: `systemctl restart quay`

### Static files not loading

1. Verify nginx is running: `systemctl status nginx`
2. Check static files exist: `ls /opt/quay/static/`
3. Rebuild frontend if needed: `cd /opt/quay && NODE_OPTIONS=--openssl-legacy-provider npm run build`

### Database connection errors

```bash
# Test database connection
sudo -u postgres psql -c "SELECT 1"

# Check pg_hba.conf has md5 auth for quay user
sudo -u postgres psql -t -c "SHOW hba_file;"
```

### Python/pip issues

```bash
# Activate the correct Python environment
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# Verify Python version
python --version  # Should be 3.12.7

# Activate venv
cd /opt/quay
source venv/bin/activate
```

## Files

```
quay-native-install/
├── README.md           # This documentation
└── install-quay.sh     # Installation script
```

## Requirements

- **OS:** Fedora 43 (tested on LXC container)
- **RAM:** 4GB minimum (webpack frontend build requires ~3GB heap)
- **Storage:** 8GB for OS + additional for container images
- **Network:** Port 80 accessible

## License

Quay is licensed under the Apache License 2.0.
