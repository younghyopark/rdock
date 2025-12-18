#!/bin/bash
set -e

#######################################
# rdock Deployment Script
# Deploys remote development environment with nginx, SSL, and basic auth
#######################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Get script directory (where server.py should be)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"

#######################################
# Configuration
#######################################
DOMAIN=""
USERNAME=""
TERMINAL_PORT=8890
VSCODE_PORT=8893
PYTHON_CMD=""
SKIP_SSL=false
SKIP_VSCODE=false
SERVICE_NAME="rdock"
BASE_PATH=""

usage() {
    echo "Usage: $0 -d DOMAIN -u USERNAME [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -d DOMAIN     Domain name (e.g., myserver.example.com)"
    echo "  -u USERNAME   Username for basic authentication"
    echo ""
    echo "Options:"
    echo "  -b PATH       Base URL path (e.g., /rdock). Default: / (root)"
    echo "  -p PORT       Port for terminal server (default: 8890)"
    echo "  -P PYTHON     Python executable path (auto-detected if not specified)"
    echo "  -s            Skip SSL setup (use self-signed or existing cert)"
    echo "  -c            Skip VS Code setup"
    echo "  -h            Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -d myserver.example.com -u admin"
    echo "  $0 -d myserver.example.com -u admin -b /rdock"
    exit 1
}

while getopts "d:u:b:p:P:sch" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        b) BASE_PATH="$OPTARG" ;;
        p) TERMINAL_PORT="$OPTARG" ;;
        P) PYTHON_CMD="$OPTARG" ;;
        s) SKIP_SSL=true ;;
        c) SKIP_VSCODE=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required arguments
if [ -z "$DOMAIN" ] || [ -z "$USERNAME" ]; then
    print_error "Domain and username are required"
    usage
fi

# Check if server.py exists
if [ ! -f "$SERVER_PY" ]; then
    print_error "server.py not found in $SCRIPT_DIR"
    exit 1
fi

echo "========================================"
echo "  rdock Deployment"
echo "========================================"
echo "Domain:    $DOMAIN"
echo "Base Path: ${BASE_PATH:-/}"
echo "Username:  $USERNAME"
echo "Terminal:  port $TERMINAL_PORT"
echo "VS Code:   port $VSCODE_PORT"
echo "========================================"
echo ""

#######################################
# Step 1: Detect Python
#######################################
echo "Step 1: Detecting Python environment..."

if [ -n "$PYTHON_CMD" ]; then
    if [ ! -x "$PYTHON_CMD" ]; then
        print_error "Specified Python not found: $PYTHON_CMD"
        exit 1
    fi
elif [ -f "$SCRIPT_DIR/.conda/bin/python" ]; then
    PYTHON_CMD="$SCRIPT_DIR/.conda/bin/python"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="$(which python3)"
elif command -v python &> /dev/null; then
    PYTHON_CMD="$(which python)"
else
    print_error "Python not found. Please install Python 3.8+ or specify with -P"
    exit 1
fi

print_status "Using Python: $PYTHON_CMD"

#######################################
# Step 2: Install Python dependencies
#######################################
echo ""
echo "Step 2: Installing Python dependencies..."

# Check if requirements.txt exists
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    $PYTHON_CMD -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
    print_status "Python dependencies installed from requirements.txt"
else
    $PYTHON_CMD -m pip install --quiet aiohttp
    print_status "aiohttp installed"
fi

#######################################
# Step 3: Install system packages
#######################################
echo ""
echo "Step 3: Installing system packages..."

if ! command -v nginx &> /dev/null; then
    sudo apt update
    sudo apt install -y nginx
    print_status "nginx installed"
else
    print_status "nginx already installed"
fi

if ! command -v certbot &> /dev/null; then
    sudo apt install -y certbot python3-certbot-nginx
    print_status "certbot installed"
else
    print_status "certbot already installed"
fi

if ! command -v htpasswd &> /dev/null; then
    sudo apt install -y apache2-utils
    print_status "apache2-utils installed"
else
    print_status "apache2-utils already installed"
fi

#######################################
# Step 3b: Install VS Code CLI (Official)
#######################################
if [ "$SKIP_VSCODE" = false ]; then
    echo ""
    echo "Step 3b: Installing VS Code CLI..."
    
    if [ ! -f /usr/local/bin/code-cli ]; then
        cd /tmp
        curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" -o vscode-cli.tar.gz
        tar -xzf vscode-cli.tar.gz
        sudo mv code /usr/local/bin/code-cli
        rm -f vscode-cli.tar.gz
        print_status "VS Code CLI installed"
    else
        print_status "VS Code CLI already installed"
    fi
fi

#######################################
# Step 4: Create nginx configuration
#######################################
echo ""
echo "Step 4: Configuring nginx..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
CURRENT_USER=$(whoami)

# Normalize base path (ensure it starts with / and doesn't end with /)
if [ -n "$BASE_PATH" ]; then
    # Ensure starts with /
    [[ "$BASE_PATH" != /* ]] && BASE_PATH="/$BASE_PATH"
    # Remove trailing slash
    BASE_PATH="${BASE_PATH%/}"
fi

# Determine location paths
TERMINAL_LOCATION="${BASE_PATH:-}/"
VSCODE_LOCATION_PATH="${BASE_PATH:-}/code/"

# Build VS Code location block if enabled
VSCODE_LOCATION=""
if [ "$SKIP_VSCODE" = false ]; then
    VSCODE_LOCATION="
    # Official VS Code Web
    location ${VSCODE_LOCATION_PATH} {
        proxy_pass http://127.0.0.1:$VSCODE_PORT/code/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Accept-Encoding gzip;
        
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }
"
fi

# Create initial HTTP-only config (certbot will add SSL)
sudo tee "$NGINX_CONF" > /dev/null << EOF
server {
    server_name $DOMAIN;

    # Basic Authentication
    auth_basic "Terminal Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
$VSCODE_LOCATION
    # Terminal
    location $TERMINAL_LOCATION {
        proxy_pass http://127.0.0.1:$TERMINAL_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # CRITICAL for WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Long timeout for WebSocket connections
        proxy_read_timeout 86400;
        proxy_connect_timeout 60;
    }

    listen 80;
}
EOF

# Enable site
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
print_status "nginx configured"

#######################################
# Step 5: Set up SSL with Let's Encrypt
#######################################
echo ""
echo "Step 5: Setting up SSL..."

if [ "$SKIP_SSL" = true ]; then
    print_warning "Skipping SSL setup (--skip-ssl flag)"
else
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    print_status "SSL certificate obtained and configured"
fi

#######################################
# Step 6: Set up basic authentication
#######################################
echo ""
echo "Step 6: Setting up basic authentication..."

if [ ! -f /etc/nginx/.htpasswd ]; then
    echo "Creating password for user: $USERNAME"
    sudo htpasswd -c /etc/nginx/.htpasswd "$USERNAME"
else
    echo "Adding/updating password for user: $USERNAME"
    sudo htpasswd /etc/nginx/.htpasswd "$USERNAME"
fi
print_status "Basic auth configured"

# Reload nginx to apply auth
sudo systemctl reload nginx

#######################################
# Step 7: Create systemd services
#######################################
echo ""
echo "Step 7: Creating systemd services..."

# Terminal service
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null << EOF
[Unit]
Description=rdock Remote Development Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$PYTHON_CMD $SERVER_PY
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
print_status "rdock service created and started"

# VS Code service
if [ "$SKIP_VSCODE" = false ]; then
    echo ""
    echo "Step 7b: Creating VS Code service..."
    
    sudo tee "/etc/systemd/system/vscode-web.service" > /dev/null << EOF
[Unit]
Description=VS Code Official Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=HOME=/home/$CURRENT_USER
ExecStart=/usr/local/bin/code-cli serve-web --host 127.0.0.1 --port $VSCODE_PORT --without-connection-token --accept-server-license-terms --server-base-path /code
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vscode-web
    sudo systemctl restart vscode-web
    print_status "VS Code service created and started"
fi

#######################################
# Step 8: Verify deployment
#######################################
echo ""
echo "Step 8: Verifying deployment..."

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_status "rdock service is running"
else
    print_error "rdock service failed to start. Check: sudo journalctl -u $SERVICE_NAME -f"
    exit 1
fi

# Test HTTP response
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$TERMINAL_PORT/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    print_status "rdock server responding"
else
    print_warning "Terminal server returned HTTP $HTTP_CODE (may be normal)"
fi

# Verify VS Code
if [ "$SKIP_VSCODE" = false ]; then
    if systemctl is-active --quiet "vscode-web"; then
        print_status "VS Code service is running"
    else
        print_warning "VS Code may not be running. Check: sudo journalctl -u vscode-web -f"
    fi
fi

#######################################
# Done!
#######################################
echo ""
echo "========================================"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo "========================================"
echo ""
echo "Access your services at:"
if [ "$SKIP_SSL" = true ]; then
    echo "  rdock:     http://$DOMAIN${TERMINAL_LOCATION}"
    if [ "$SKIP_VSCODE" = false ]; then
        echo "  VS Code:   http://$DOMAIN${VSCODE_LOCATION_PATH}"
    fi
else
    echo "  rdock:     https://$DOMAIN${TERMINAL_LOCATION}"
    if [ "$SKIP_VSCODE" = false ]; then
        echo "  VS Code:   https://$DOMAIN${VSCODE_LOCATION_PATH}"
    fi
fi
echo ""
echo "Credentials:"
echo "  Username: $USERNAME"
echo "  Password: (the one you just entered)"
echo ""
echo "Useful commands:"
echo "  View logs:       sudo journalctl -u $SERVICE_NAME -f"
echo "  Restart service: sudo systemctl restart $SERVICE_NAME"
if [ "$SKIP_VSCODE" = false ]; then
    echo "  VS Code logs:    sudo journalctl -u vscode-web -f"
    echo "  VS Code restart: sudo systemctl restart vscode-web"
fi
echo "  Add user:        sudo htpasswd /etc/nginx/.htpasswd newuser"
echo "  Renew SSL:       sudo certbot renew"
echo ""
echo "Terminal keyboard shortcuts:"
echo "  Ctrl+Shift+T    New tab"
echo "  Ctrl+Shift+W    Close tab"
echo "  Ctrl+Tab        Next tab"
echo "  Ctrl+Shift+Tab  Previous tab"
echo ""
