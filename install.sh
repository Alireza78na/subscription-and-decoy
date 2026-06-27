#!/bin/bash
# Script for Automated Installation and Update of OpenResty Subscription & Decoy Project
# Architecture: Ubuntu/Debian

set -euo pipefail

# ==========================================
# Variables
# ==========================================
REPO_URL="https://github.com/alireza78na/subscription-and-decoy.git"
BACKUP_DIR="/root/openresty_backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR=$(mktemp -d)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# ==========================================
# Functions
# ==========================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_update() { echo -e "${CYAN}[UPDATE]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_err "این اسکریپت باید با دسترسی Root اجرا شود."
    fi
}

check_status() {
    # بررسی می‌کنیم آیا نصب قبلی وجود دارد یا خیر
    if [ -f "/etc/openresty/nginx.conf" ] && command -v openresty &> /dev/null; then
        IS_UPDATE=true
        log_update "نصب قبلی تشخیص داده شد. اسکریپت در حالت آپدیت اجرا شده و فقط فایل‌ها جایگزین می‌شوند..."
    else
        IS_UPDATE=false
        log_info "نصب جدید تشخیص داده شد. در حال انجام کامل مراحل اولیه..."
    fi
}

install_dependencies() {
    log_info "در حال آپدیت مخازن و نصب پیش‌نیازهای اولیه..."
    apt-get update -y
    apt-get install -y --no-install-recommends wget curl gnupg ca-certificates lsb-release git openssl logrotate

    log_info "در حال بررسی و نصب OpenResty..."
    local DISTRO=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    local CODENAME=$(lsb_release -sc)
    
    wget -qO - https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
    echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/${DISTRO} ${CODENAME} main" > /etc/apt/sources.list.d/openresty.list
    
    apt-get update -y
    apt-get install -y openresty openresty-opm

    if systemctl is-active --quiet nginx; then
        log_warn "Nginx پیش‌فرض در حال اجراست. در حال توقف و غیرفعال‌سازی برای جلوگیری از تداخل..."
        systemctl stop nginx
        systemctl disable nginx
    fi
}

create_directories() {
    # این دستورات تنها در صورتی پوشه می‌سازند که وجود نداشته باشد
    mkdir -p /etc/openresty/config
    mkdir -p /etc/openresty/lua
    mkdir -p /var/www/html
    mkdir -p /usr/local/openresty/nginx/logs
    mkdir -p /var/log/openresty
    mkdir -p /root/cert/CF.fp-network.link
    mkdir -p /root/cert/lets.fp-network.link
    mkdir -p "$BACKUP_DIR"
}

setup_dummy_ssl() {
    local CF_CERT="/root/cert/CF.fp-network.link"
    local LETS_CERT="/root/cert/lets.fp-network.link"

    if [ ! -f "$CF_CERT/fullchain.pem" ] || [ ! -f "$CF_CERT/privkey.pem" ]; then
        log_info "ساخت گواهی موقت (Dummy) برای p1..."
        openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
            -keyout "$CF_CERT/privkey.pem" \
            -out "$CF_CERT/fullchain.pem" \
            -subj "/CN=p1.fp-network.link" 2>/dev/null
    fi

    if [ ! -f "$LETS_CERT/fullchain.pem" ] || [ ! -f "$LETS_CERT/privkey.pem" ]; then
        log_info "ساخت گواهی موقت (Dummy) برای s1..."
        openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
            -keyout "$LETS_CERT/privkey.pem" \
            -out "$LETS_CERT/fullchain.pem" \
            -subj "/CN=s1.fp-network.link" 2>/dev/null
    fi
}

deploy_file() {
    local src="$1"
    local dst="$2"
    
    if [ ! -f "$src" ]; then
        log_warn "فایل منبع $src در مخزن یافت نشد."
        return
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        local relative_path=$(dirname "$dst")
        mkdir -p "$BACKUP_DIR$relative_path"
        cp -a "$dst" "$BACKUP_DIR$dst"
        rm -f "$dst"
        log_update "نسخه قبلی $(basename "$dst") بکاپ گرفته شد و فایل جدید جایگزین گردید."
    else
        log_info "فایل جدید $(basename "$dst") ایجاد شد."
    fi

    cp -f "$src" "$dst"
}

clone_and_deploy() {
    log_info "در حال دریافت کدهای جدید از گیت‌هاب (Clone)..."
    git clone -q "$REPO_URL" "$TEMP_DIR"

    deploy_file "$TEMP_DIR/etc/logrotate.d/openresty" "/etc/logrotate.d/openresty"
    deploy_file "$TEMP_DIR/etc/openresty/config/subscription.json" "/etc/openresty/config/subscription.json"
    deploy_file "$TEMP_DIR/etc/openresty/lua/subscription_modifier.lua" "/etc/openresty/lua/subscription_modifier.lua"
    deploy_file "$TEMP_DIR/etc/openresty/nginx.conf" "/etc/openresty/nginx.conf"
    deploy_file "$TEMP_DIR/var/www/html/404.html" "/var/www/html/404.html"
    deploy_file "$TEMP_DIR/var/www/html/index.html" "/var/www/html/index.html"

    # مدیریت Symlink اصلی انجینکس بدون ایجاد حلقه بی‌نهایت
    if [ -e "/usr/local/openresty/nginx/conf/nginx.conf" ] || [ -L "/usr/local/openresty/nginx/conf/nginx.conf" ]; then
        mv -f "/usr/local/openresty/nginx/conf/nginx.conf" "$BACKUP_DIR/nginx.conf.default.bak" 2>/dev/null || true
    fi
    ln -sf /etc/openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
}

configure_permissions() {
    # اعمال مجدد دسترسی‌ها برای فایل‌های جدید کپی شده بسیار مهم است تا با خطای دسترسی روبرو نشویم
    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html
    
    chown -R www-data:www-data /usr/local/openresty/nginx/logs
    chmod 755 /usr/local/openresty/nginx/logs

    chmod 644 /etc/logrotate.d/openresty
}

test_and_restart() {
    log_info "در حال تست سلامت کانفیگ (Syntax Check)..."
    if openresty -t; then
        if [ "$IS_UPDATE" = true ]; then
            log_update "کانفیگ سالم است. در حال اعمال تغییرات روی انجینکس (Reload بدون قطعی)..."
            systemctl reload openresty
            log_update "فایل‌ها با موفقیت آپدیت شدند و تغییرات اعمال شد."
        else
            log_info "کانفیگ سالم است. در حال فعال‌سازی و استارت سرویس انجینکس..."
            systemctl enable openresty
            systemctl restart openresty
            log_info "نصب و راه‌اندازی اولیه با موفقیت به پایان رسید."
        fi
    else
        log_err "خطا در کانفیگ جدید! سرویس Restart/Reload نشد تا از قطعی جلوگیری شود. فایل‌ها را بررسی کنید."
    fi
}

cleanup() {
    rm -rf "$TEMP_DIR"
}

# ==========================================
# Main Execution Flow
# ==========================================
check_root
check_status

# شرطی شدن اجرای مراحل سنگین اولیه
if [ "$IS_UPDATE" = false ]; then
    install_dependencies
fi

create_directories

if [ "$IS_UPDATE" = false ]; then
    setup_dummy_ssl
fi

clone_and_deploy
configure_permissions
test_and_restart
cleanup

exit 0
