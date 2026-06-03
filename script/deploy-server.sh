#!/usr/bin/env bash
#
# MISP 2.5 bare-metal deployment wrapper (Ubuntu 24.04)
#
# Runs the official installer: INSTALL/INSTALL.ubuntu2404.sh
# with interactive preflight (DNS, firewall, TLS, secrets)
#
# What this deploys (via the official script):
#   - Apache + PHP 8.3, MariaDB, Redis, Supervisor workers
#   - MISP core at /var/www/MISP (default)
#   - Self-signed TLS, or Let's Encrypt if requested before install
#
# Optional (same server, post core install):
#   - MISP-modules systemd service on 127.0.0.1:6666 (prompt at deploy time)
#
# Requirements:
#   - Fresh Ubuntu 24.04 LTS, run as root
#   - Outbound internet (apt, git clone in official installer)
#
# Usage:
#   sudo bash script/deploy-server.sh
#   sudo MISP_INSTALL_SCRIPT=/path/to/INSTALL.ubuntu2404.sh bash script/deploy-server.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MISP_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MISP_PATH="${MISP_PATH:-/var/www/MISP}"
MISP_INSTALL_SCRIPT="${MISP_INSTALL_SCRIPT:-${MISP_REPO_DIR}/INSTALL/INSTALL.ubuntu2404.sh}"
LE_SSL_DIR="/etc/ssl/misp-letsencrypt"
MISP_MODULES_SRC="${MISP_MODULES_SRC:-/usr/local/src/misp-modules}"
APACHE_USER="${APACHE_USER:-www-data}"
INSTALL_MODULES=false
MODULES_INSTALLED=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
generate_alnum_secret() {
    local length="${1:-32}"
    local secret=""
    # `head -c` closes the pipe while `tr` is still writing; with `set -o pipefail`
    # that makes `tr` exit 141 (SIGPIPE) and aborts the whole script on empty prompts.
    set +o pipefail
    secret="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$length")"
    set -o pipefail
    if [[ ${#secret} -ne "$length" ]]; then
        secret="$(openssl rand -hex "$(( (length + 1) / 2 ))" | head -c "$length")"
    fi
    if [[ ${#secret} -ne "$length" ]]; then
        echo "ERROR: failed to generate random secret." >&2
        return 1
    fi
    printf '%s' "$secret"
}

check_ubuntu_2404() {
    local version_id
    version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    if [[ "$version_id" != "24.04" ]]; then
        echo "ERROR: This deployment targets Ubuntu 24.04 LTS (found: ${version_id:-unknown})." >&2
        echo "       Upgrade the OS or use INSTALL/INSTALL.* for your distribution." >&2
        exit 1
    fi
}

issue_letsencrypt_cert() {
    local domain="$1"
    local email="$2"
    local include_www="$3"

    apt-get install -y certbot

    local certbot_domains=(-d "${domain}")
    [[ "$include_www" == true ]] && certbot_domains+=(-d "www.${domain}")

    local live_dir="/etc/letsencrypt/live/${domain}"
    if [[ -d "$live_dir" && -f "${live_dir}/fullchain.pem" ]]; then
        echo "  -> Certificate already exists for ${domain}; reusing."
    else
        echo "==> Requesting Let's Encrypt certificate (standalone; ports 80/443 must be free)..."
        certbot certonly --standalone --non-interactive --agree-tos \
            -m "${email}" \
            "${certbot_domains[@]}"
    fi

    mkdir -p "$LE_SSL_DIR"
    cp -f "${live_dir}/fullchain.pem" "${LE_SSL_DIR}/fullchain.pem"
    cp -f "${live_dir}/privkey.pem" "${LE_SSL_DIR}/privkey.pem"
    chmod 644 "${LE_SSL_DIR}/fullchain.pem"
    chmod 600 "${LE_SSL_DIR}/privkey.pem"
}

install_cert_renewal_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="${hook_dir}/misp-apache-reload.sh"
    mkdir -p "$hook_dir"
    cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
LE_SSL_DIR="/etc/ssl/misp-letsencrypt"
if [[ -z "${RENEWED_LINEAGE:-}" || ! -d "${RENEWED_LINEAGE}" ]]; then
    exit 0
fi
cp -f "${RENEWED_LINEAGE}/fullchain.pem" "${LE_SSL_DIR}/fullchain.pem"
cp -f "${RENEWED_LINEAGE}/privkey.pem" "${LE_SSL_DIR}/privkey.pem"
apache2ctl configtest
systemctl reload apache2
HOOK
    chmod +x "$hook"
}

install_misp_modules() {
    local modules_log="/var/log/misp_modules_install.log"
    local venv_pip="${MISP_PATH}/venv/bin/pip"
    local cake="${MISP_PATH}/app/Console/cake"
    local src_root="/usr/local/src"

    if [[ ! -x "$venv_pip" ]]; then
        echo "ERROR: MISP Python venv not found at ${MISP_PATH}/venv (run core install first)." >&2
        return 1
    fi

    if systemctl is-active --quiet misp-modules 2>/dev/null; then
        echo "  -> misp-modules service already running; refreshing install..."
    fi

    echo "==> Installing MISP-modules on this server (log: ${modules_log})..."

    (
    apt-get install -y \
        cmake libcaca-dev liblua5.3-dev libpq5 libjpeg-dev tesseract-ocr \
        libpoppler-cpp-dev imagemagick libopencv-dev zbar-tools libzbar0 libzbar-dev \
        libfuzzy-dev build-essential git

    mkdir -p "$src_root"
    cd "$src_root"

    if [[ -d "${MISP_MODULES_SRC}/.git" ]]; then
        echo "  -> Updating existing misp-modules clone..."
        git -C "${MISP_MODULES_SRC}" pull
    else
        rm -rf "${MISP_MODULES_SRC}"
        if [[ -n "${MISP_MODULES_TAG:-}" ]]; then
            git clone --depth 1 --branch "${MISP_MODULES_TAG}" \
                https://github.com/MISP/misp-modules.git "${MISP_MODULES_SRC}"
        else
            git clone --depth 1 https://github.com/MISP/misp-modules.git "${MISP_MODULES_SRC}"
        fi
    fi

    # faup / gtcaca (optional libs for some modules; non-fatal if build fails)
    for repo in faup gtcaca; do
        if [[ ! -d "${src_root}/${repo}/.git" ]]; then
            git clone --depth 1 "https://github.com/stricaud/${repo}.git" "${src_root}/${repo}" || {
                echo "WARN: failed to clone ${repo}; continuing."
                continue
            }
        fi
        chown -R "${APACHE_USER}:${APACHE_USER}" "${src_root}/${repo}" || true
        if [[ -d "${src_root}/${repo}" ]]; then
            mkdir -p "${src_root}/${repo}/build"
            (
                cd "${src_root}/${repo}/build"
                cmake .. && make && make install
            ) || echo "WARN: ${repo} build failed; some modules may be unavailable."
        fi
    done
    ldconfig 2>/dev/null || true

    cd "${MISP_MODULES_SRC}"
    chown -R "${APACHE_USER}:${APACHE_USER}" "${MISP_MODULES_SRC}"
    chgrp "${APACHE_USER}" . || true
    chmod g+w . || true

    sudo -u "${APACHE_USER}" "$venv_pip" install pillow
    sudo -u "${APACHE_USER}" "$venv_pip" install -I -r REQUIREMENTS
    sudo -u "${APACHE_USER}" "$venv_pip" install -I .
    sudo -u "${APACHE_USER}" "$venv_pip" install censys pyfaup || \
        echo "WARN: censys/pyfaup optional deps failed."

    cp -f "${MISP_MODULES_SRC}/etc/systemd/system/misp-modules.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable misp-modules
    systemctl restart misp-modules

    echo "  -> Waiting for misp-modules to start..."
    sleep 9
    if ! systemctl is-active --quiet misp-modules; then
        echo "ERROR: misp-modules failed to start. Check: journalctl -u misp-modules -n 50" >&2
        return 1
    fi

    echo "  -> misp-modules systemd service is active."
    ) 2>&1 | tee -a "$modules_log"

    local install_rc=${PIPESTATUS[0]}
    if (( install_rc != 0 )); then
        return "$install_rc"
    fi

    configure_misp_modules_settings
    MODULES_INSTALLED=true
    echo "  -> MISP-modules ready at http://127.0.0.1:6666"
}

configure_misp_modules_settings() {
    local cake="${MISP_PATH}/app/Console/cake"
    if [[ ! -x "$cake" ]]; then
        echo "WARN: cake CLI missing; configure modules URL in MISP UI manually." >&2
        return 0
    fi

    echo "==> Configuring MISP to use local misp-modules..."
    local settings=(
        "Plugin.Enrichment_services_enable:true"
        "Plugin.Enrichment_services_url:http://127.0.0.1"
        "Plugin.Enrichment_services_port:6666"
        "Plugin.Import_services_enable:true"
        "Plugin.Import_services_url:http://127.0.0.1"
        "Plugin.Import_services_port:6666"
        "Plugin.Export_services_enable:true"
        "Plugin.Export_services_url:http://127.0.0.1"
        "Plugin.Export_services_port:6666"
    )
    local entry key value
    for entry in "${settings[@]}"; do
        key="${entry%%:*}"
        value="${entry#*:}"
        sudo -u "${APACHE_USER}" "$cake" Admin setSetting "$key" "$value" || \
            echo "WARN: failed to set ${key}"
    done
}

fetch_admin_api_key() {
    local settings="/root/misp_settings.txt"
    local key=""

    if [[ -f "$settings" ]]; then
        key="$(grep -E '^- Admin API key:' "$settings" | sed 's/^- Admin API key: //' | tr -d '[:space:]')"
    fi

    if [[ ${#key} -ne 40 ]]; then
        echo "==> Could not read API key from ${settings}; generating via cake..."
        local out
        out="$(sudo -u "${APACHE_USER}" "${MISP_PATH}/app/Console/cake" User change_authkey admin@admin.test 2>&1)" || true
        key="$(echo "$out" | grep -oE '[A-Za-z0-9]{40}' | tail -n1)"
    fi

    if [[ ${#key} -ne 40 ]]; then
        echo "WARN: Admin API key not available. See /root/misp_settings.txt or MISP UI → Auth keys." >&2
        return 1
    fi
    echo "$key"
}

write_automation_env() {
    local api_key="$1"
    local env_file="/root/misp-automation.env"
    local insecure="false"

    if [[ -z "${PATH_TO_SSL_CERT}" ]]; then
        insecure="true"
    fi

    cat > "$env_file" <<ENV
# Source this file for PyMISP / misp-import (mode 600, root only)
#   set -a && source ${env_file} && set +a
MISP_URL=${MISP_BASEURL}
MISP_KEY=${api_key}
MISP_INSECURE=${insecure}
ENV
    chmod 600 "$env_file"
    echo "$env_file"
}

print_import_credentials() {
    local api_key="$1"
    local env_file="$2"

    echo
    echo "============================================================"
    echo " API key for import / automation (PyMISP, misp-import)"
    echo "============================================================"
    echo "  MISP_URL=${MISP_BASEURL}"
    echo "  MISP_KEY=${api_key}"
    if [[ -z "${PATH_TO_SSL_CERT}" ]]; then
        echo "  MISP_INSECURE=true    # self-signed TLS on this install"
    fi
    echo
    echo "  Saved to: ${env_file}"
    echo "    source ${env_file}"
    echo
    echo "  Detached import example:"
    echo "    set -a && source ${env_file} && set +a"
    echo "    nohup python3 /path/to/import_misp.py --source ./misp_export \\"
    echo "      > /var/log/misp-import.log 2>&1 &"
    echo "============================================================"
}

write_client_checklist() {
    local file="/root/misp-client-deploy-checklist.txt"
    local modules_line="- [ ] Install MISP-modules: docs/generic/misp-modules-debian.md"
    if [[ "$MODULES_INSTALLED" == true ]]; then
        modules_line="- [x] MISP-modules (systemd: misp-modules, http://127.0.0.1:6666)"
    fi

    cat > "$file" <<CHECKLIST
# MISP client server — deployment checklist
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Installed by official INSTALL.ubuntu2404.sh
- [x] MISP 2.5 core (${MISP_PATH})
- [x] Apache HTTPS vhost (ServerName: ${MISP_DOMAIN})
- [x] MariaDB database: misp
- [x] Redis + Supervisor background workers
- [x] Python venv + GPG key for the instance
${modules_line}

## Credentials
- URL:          ${MISP_BASEURL}
- Admin user:   admin@admin.test
- Admin pass:   /root/misp_settings.txt
- API import:   /root/misp-automation.env  (MISP_URL, MISP_KEY, MISP_INSECURE)

## Operator follow-up (recommended)
- [ ] Log in and change admin@admin.test email/password if needed
- [ ] Review MISP server settings (baseurl, org, contact email)
- [ ] Harden the host: https://github.com/MISP/MISP/blob/2.5/docs/generic/hardening.md
- [ ] Configure email (SMTP) for notifications
- [ ] Set up backups: INSTALL/misp-backup or your own DB/files backup

## Logs
- Install log: /var/log/misp_install.log
- Modules log: /var/log/misp_modules_install.log
- Apache:      /var/log/apache2/misp.local_*.log
- Modules svc: journalctl -u misp-modules

## Updates
- MISP: follow INSTALL/UPDATE.md or git pull + cake Admin runUpdates
- OS:   apt upgrade + reboot as needed
CHECKLIST
    chmod 600 "$file"
    echo "$file"
}

# ---------------------------------------------------------------------------
# Root / environment
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

check_ubuntu_2404

if [[ ! -f "$MISP_INSTALL_SCRIPT" ]]; then
    echo "ERROR: Official installer not found: ${MISP_INSTALL_SCRIPT}" >&2
    echo "       Clone MISP/MISP or set MISP_INSTALL_SCRIPT to INSTALL.ubuntu2404.sh" >&2
    exit 1
fi

if [[ -d "${MISP_PATH}/.git" ]]; then
    echo "WARN: ${MISP_PATH} already contains a MISP git checkout."
    echo "      The official installer will update it, not perform a pristine install."
    read -rp "Continue? [y/N]: " EXISTING_OK
    [[ "${EXISTING_OK,,}" == "y" || "${EXISTING_OK,,}" == "yes" ]] || exit 1
elif [[ -d "${MISP_PATH}" ]]; then
    echo "ERROR: ${MISP_PATH} exists but is not a MISP git repo. Remove or choose another MISP_PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " MISP 2.5 Bare-Metal Server Setup (Ubuntu 24.04)"
echo "============================================================"
echo " Official installer: ${MISP_INSTALL_SCRIPT}"
echo " MISP install path:  ${MISP_PATH}"
echo

read -rp "Domain name (leave blank for IP-based access): " MISP_DOMAIN
MISP_DOMAIN="${MISP_DOMAIN// /}"

HAS_DOMAIN=false
INCLUDE_WWW=false
SERVER_IPS="$(hostname -I)"
PRIMARY_IP="$(echo "$SERVER_IPS" | awk '{print $1}')"

if [[ -n "$MISP_DOMAIN" ]]; then
    HAS_DOMAIN=true

    echo "==> Verifying DNS for ${MISP_DOMAIN}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y dnsutils >/dev/null 2>&1 || true

    RESOLVED_IP="$(dig +short "$MISP_DOMAIN" A | tail -n1)"

    if [[ -z "$RESOLVED_IP" ]]; then
        echo "ERROR: ${MISP_DOMAIN} does not resolve to any IPv4 address." >&2
        echo "       Configure an A record pointing to this server, then re-run." >&2
        exit 1
    fi

    MATCHED=false
    for ip in $SERVER_IPS; do
        [[ "$ip" == "$RESOLVED_IP" ]] && MATCHED=true && break
    done

    if [[ "$MATCHED" != true ]]; then
        echo "WARN: ${MISP_DOMAIN} resolves to ${RESOLVED_IP}, not this host (${SERVER_IPS})."
        read -rp "Continue anyway? [y/N]: " DNS_CONTINUE
        [[ "${DNS_CONTINUE,,}" == "y" || "${DNS_CONTINUE,,}" == "yes" ]] || exit 1
    fi

    echo "  -> Domain: $MISP_DOMAIN"

    WWW_RESOLVED_IP="$(dig +short "www.${MISP_DOMAIN}" A | tail -n1)"
    if [[ -n "$WWW_RESOLVED_IP" ]]; then
        for ip in $SERVER_IPS; do
            if [[ "$ip" == "$WWW_RESOLVED_IP" ]]; then
                INCLUDE_WWW=true
                break
            fi
        done
        if [[ "$INCLUDE_WWW" == true ]]; then
            echo "  -> www.${MISP_DOMAIN} resolves here; will include in TLS cert."
            echo "     Note: Apache vhost uses ServerName ${MISP_DOMAIN} only; add ServerAlias manually if you need www."
        else
            echo "  -> www.${MISP_DOMAIN} resolves elsewhere; skipping in cert."
        fi
    fi
else
    echo "  -> No domain. Using server IP with a self-signed certificate."

    read -ra IP_ARRAY <<< "$SERVER_IPS"
    IP_COUNT=${#IP_ARRAY[@]}

    if (( IP_COUNT == 0 )); then
        echo "ERROR: No IPv4 addresses detected." >&2
        exit 1
    elif (( IP_COUNT == 1 )); then
        PRIMARY_IP="${IP_ARRAY[0]}"
        echo "  -> Detected server IP: ${PRIMARY_IP}"
        read -rp "     Use https://${PRIMARY_IP} as MISP base URL? [Y/n]: " IP_CONFIRM
        IP_CONFIRM="${IP_CONFIRM,,}"
        IP_CONFIRM="${IP_CONFIRM:-y}"
        if [[ "$IP_CONFIRM" != "y" && "$IP_CONFIRM" != "yes" ]]; then
            echo "Aborted." >&2
            exit 1
        fi
    else
        echo "  -> Multiple IPs detected:"
        for i in "${!IP_ARRAY[@]}"; do
            printf "       [%d] %s\n" "$((i+1))" "${IP_ARRAY[$i]}"
        done
        while :; do
            read -rp "     Choose IP [1-${IP_COUNT}]: " IP_CHOICE
            if [[ "$IP_CHOICE" =~ ^[0-9]+$ ]] && (( IP_CHOICE >= 1 && IP_CHOICE <= IP_COUNT )); then
                PRIMARY_IP="${IP_ARRAY[$((IP_CHOICE-1))]}"
                break
            fi
        done
        echo "  -> Selected: ${PRIMARY_IP}"
    fi
    MISP_DOMAIN="${PRIMARY_IP}"
fi

if [[ "$HAS_DOMAIN" == true ]]; then
    MISP_BASEURL="https://${MISP_DOMAIN}"
else
    MISP_BASEURL="https://${MISP_DOMAIN}"
fi

read -rp "MISP admin password (empty = auto-generate): " PASSWORD
if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(generate_alnum_secret 24)"
    echo "  -> Generated admin password."
else
    read -rsp "Confirm admin password: " PASSWORD_CONFIRM
    echo
    [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || { echo "Passwords do not match." >&2; exit 1; }
fi

read -rsp "MariaDB password for user 'misp' (empty = auto-generate): " DBPASSWORD_MISP
echo
if [[ -z "$DBPASSWORD_MISP" ]]; then
    DBPASSWORD_MISP="$(generate_alnum_secret 32)"
    echo "  -> Generated MySQL application password."
fi

read -rsp "MariaDB root password (empty = Ubuntu default / empty): " DBPASSWORD_ADMIN
echo

read -rsp "GPG passphrase (empty = auto-generate): " GPG_PASSPHRASE
echo
if [[ -z "$GPG_PASSPHRASE" ]]; then
    GPG_PASSPHRASE="$(generate_alnum_secret 32)"
    echo "  -> Generated GPG passphrase."
fi

GPG_EMAIL_ADDRESS="admin@admin.test"
read -rp "GPG / MISP contact email [${GPG_EMAIL_ADDRESS}]: " GPG_EMAIL_INPUT
GPG_EMAIL_ADDRESS="${GPG_EMAIL_INPUT:-$GPG_EMAIL_ADDRESS}"

read -rp "Install ssdeep support (slower build)? [y/N]: " INSTALL_SSDEEP_ANS
INSTALL_SSDEEP_ANS="${INSTALL_SSDEEP_ANS,,}"
INSTALL_SSDEEP="n"
[[ "$INSTALL_SSDEEP_ANS" == "y" || "$INSTALL_SSDEEP_ANS" == "yes" ]] && INSTALL_SSDEEP="y"

PATH_TO_SSL_CERT=""
PATH_TO_SSL_KEY=""

if [[ "$HAS_DOMAIN" == true ]]; then
    read -rp "Issue Let's Encrypt certificate before install? [Y/n]: " ISSUE_CERT
    ISSUE_CERT="${ISSUE_CERT,,}"
    ISSUE_CERT="${ISSUE_CERT:-y}"

    read -rp "Let's Encrypt registration email [admin@${MISP_DOMAIN}]: " LE_EMAIL
    LE_EMAIL="${LE_EMAIL:-admin@${MISP_DOMAIN}}"
else
    ISSUE_CERT="n"
    LE_EMAIL=""
fi

read -rp "Install MISP-modules on this server (enrichment/import/export)? [y/N]: " INSTALL_MODULES_ANS
INSTALL_MODULES_ANS="${INSTALL_MODULES_ANS,,}"
[[ "$INSTALL_MODULES_ANS" == "y" || "$INSTALL_MODULES_ANS" == "yes" ]] && INSTALL_MODULES=true

if [[ "$INSTALL_MODULES" == true ]]; then
    read -rp "MISP-modules git tag/branch (empty = default branch): " MISP_MODULES_TAG
    MISP_MODULES_TAG="${MISP_MODULES_TAG// /}"
    echo "  -> Adds ~10–30 min build time (faup, pip deps, opencv, etc.)."
fi

# ---------------------------------------------------------------------------
# Preflight: UFW, swap, TLS (before official installer binds ports)
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

echo
echo "==> Configuring UFW..."
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

TOTAL_MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
SWAP_TOTAL_KB="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
if (( TOTAL_MEM_KB < 4 * 1024 * 1024 )) && (( SWAP_TOTAL_KB == 0 )); then
    echo "==> Low memory and no swap; creating 2G swapfile..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile 2>/dev/null || true
    grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if [[ "$HAS_DOMAIN" == true ]] && [[ "$ISSUE_CERT" == "y" || "$ISSUE_CERT" == "yes" ]]; then
    issue_letsencrypt_cert "$MISP_DOMAIN" "$LE_EMAIL" "$INCLUDE_WWW" || {
        echo "WARN: Let's Encrypt failed; official installer will use a self-signed certificate." >&2
        PATH_TO_SSL_CERT=""
        PATH_TO_SSL_KEY=""
    }
    if [[ -f "${LE_SSL_DIR}/fullchain.pem" ]]; then
        PATH_TO_SSL_CERT="${LE_SSL_DIR}/fullchain.pem"
        PATH_TO_SSL_KEY="${LE_SSL_DIR}/privkey.pem"
        install_cert_renewal_hook
    fi
fi

# ---------------------------------------------------------------------------
# Run official MISP installer
# ---------------------------------------------------------------------------
echo
echo "==> Starting official MISP installer (this may take 15–45 minutes)..."
echo "    Full log: /var/log/misp_install.log"
echo

export PASSWORD
export MISP_DOMAIN
export MISP_BASEURL
export MISP_PATH
export PATH_TO_SSL_CERT
export PATH_TO_SSL_KEY
export INSTALL_SSDEEP
export GPG_EMAIL_ADDRESS
export GPG_PASSPHRASE
export DBPASSWORD_MISP
export DBPASSWORD_ADMIN
export OPENSSL_CN="${MISP_DOMAIN}"

bash "$MISP_INSTALL_SCRIPT"

# ---------------------------------------------------------------------------
# Optional: MISP-modules (same server)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_MODULES" == true ]]; then
    echo
    install_misp_modules || {
        echo "ERROR: MISP-modules installation failed. See /var/log/misp_modules_install.log" >&2
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Post-install: API key for detached import scripts
# ---------------------------------------------------------------------------
ADMIN_API_KEY=""
AUTOMATION_ENV=""
if ADMIN_API_KEY="$(fetch_admin_api_key)"; then
    AUTOMATION_ENV="$(write_automation_env "$ADMIN_API_KEY")"
fi

CHECKLIST_FILE="$(write_client_checklist)"

echo
echo "============================================================"
echo " MISP deployment complete."
echo "  URL:        ${MISP_BASEURL}"
echo "  Admin:      admin@admin.test"
echo "  Secrets:    /root/misp_settings.txt"
if [[ -n "$AUTOMATION_ENV" ]]; then
    echo "  Import env: ${AUTOMATION_ENV}"
fi
echo "  Checklist:  ${CHECKLIST_FILE}"
echo "  Install log: /var/log/misp_install.log"
if [[ "$MODULES_INSTALLED" == true ]]; then
    echo "  Modules:    misp-modules.service (http://127.0.0.1:6666)"
    echo "  Modules log: /var/log/misp_modules_install.log"
fi
echo "============================================================"

if [[ -n "$ADMIN_API_KEY" && -n "$AUTOMATION_ENV" ]]; then
    print_import_credentials "$ADMIN_API_KEY" "$AUTOMATION_ENV"
fi

if [[ "$INSTALL_MODULES" != true ]]; then
    echo
    echo "MISP-modules were not installed. PyMISP/API import still works."
    echo "To add modules later: https://github.com/MISP/MISP/blob/2.5/docs/generic/misp-modules-debian.md"
fi
