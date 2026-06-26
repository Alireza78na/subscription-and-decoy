#!/bin/bash
# Script for Automated Installation of OpenResty Subscription & Decoy Project
# Architecture: Ubuntu/Debian

# فعال‌سازی حالت سخت‌گیرانه برای توقف اسکریپت در صورت بروز هرگونه خطای سیستمی
set -euo pipefail

# ==========================================
# Variables
# ==========================================
REPO_URL="https://github.com/alireza78na/subscription-and-decoy.git"
BACKUP_DIR="/root/openresty_backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR=$(mktemp -d)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==========================================
# Functions
# ==========================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_err "این اسکریپت باید با دسترسی Root اجرا شود."
    fi
}

install_dependencies() {
    log_info "در حال آپدیت مخازن و نصب پیش‌نیازهای اولیه..."
    apt-get update -y
    apt-get install -y --no-install-recommends wget curl gnupg ca-certificates lsb-release git openssl logrotate

    log_info "در حال بررسی و نصب OpenResty..."
    if ! command -v openresty &> /dev/null; then
        local DISTRO=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
        local CODENAME=$(lsb_release -sc)
        
        wget -qO - https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
        echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/${DISTRO} ${CODENAME} main" > /etc/apt/sources.list.d/openresty.list
        
        apt-get update -y
        apt-get install -y openresty openresty-opm
    else
        log_info "پکیج OpenResty از قبل نصب شده است."
    fi

    # حذف یا غیرفعال‌سازی Nginx پیش‌فرض برای جلوگیری از تداخل پورت ۸۰/۴۴۳
    if systemctl is-active --quiet nginx; then
        log_warn "Nginx پیش‌فرض در حال اجراست. در حال توقف و غیرفعال‌سازی برای جلوگیری از تداخل..."
        systemctl stop nginx
        systemctl disable nginx
    fi
}

create_directories() {
    log_info "در حال ایجاد ساختار دایرکتوری‌های مورد نیاز..."
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
    log_info "در حال بررسی گواهی‌های SSL..."
    # ایجاد گواهی موقت خودامضا برای جلوگیری از خطای OpenResty در صورت نبود سرتیفیکیت اصلی
    local CF_CERT="/root/cert/CF.fp-network.link"
    local LETS_CERT="/root/cert/lets.fp-network.link"

    if [ ! -f "$CF_CERT/fullchain.pem" ] || [ ! -f "$CF_CERT/privkey.pem" ]; then
        log_warn "سرتیفیکیت CF.fp-network.link یافت نشد. در حال ساخت گواهی موقت (Dummy)..."
        openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
            -keyout "$CF_CERT/privkey.pem" \
            -out "$CF_CERT/fullchain.pem" \
            -subj "/CN=p1.fp-network.link" 2>/dev/null
    fi

    if [ ! -f "$LETS_CERT/fullchain.pem" ] || [ ! -f "$LETS_CERT/privkey.pem" ]; then
        log_warn "سرتیفیکیت lets.fp-network.link یافت نشد. در حال ساخت گواهی موقت (Dummy)..."
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
        log_warn "فایل منبع $src یافت نشد، پرش از روی آن."
        return
    fi

    if [ -f "$dst" ]; then
        log_info "فایل $dst از قبل وجود دارد. در حال انتقال به پوشه Backup..."
        local relative_path=$(dirname "$dst")
        mkdir -p "$BACKUP_DIR$relative_path"
        cp -a "$dst" "$BACKUP_DIR$dst"
    fi

    cp -f "$src" "$dst"
    log_info "فایل $dst با موفقیت جایگذاری شد."
}

clone_and_deploy() {
    log_info "در حال کلون کردن مخزن گیت‌هاب..."
    git clone "$REPO_URL" "$TEMP_DIR"

    log_info "در حال استقرار فایل‌ها در مسیرهای سیستمی..."
    deploy_file "$TEMP_DIR/etc/logrotate.d/openresty" "/etc/logrotate.d/openresty"
    deploy_file "$TEMP_DIR/etc/openresty/config/subscription.json" "/etc/openresty/config/subscription.json"
    deploy_file "$TEMP_DIR/etc/openresty/lua/subscription_modifier.lua" "/etc/openresty/lua/subscription_modifier.lua"
    deploy_file "$TEMP_DIR/etc/openresty/nginx.conf" "/etc/openresty/nginx.conf"
    deploy_file "$TEMP_DIR/var/www/html/404.html" "/var/www/html/404.html"
    deploy_file "$TEMP_DIR/var/www/html/index.html" "/var/www/html/index.html"

    # پیوند (Symlink) کانفیگ انجینکس به مسیر پیش‌فرض OpenResty
    if [ -f "/usr/local/openresty/nginx/conf/nginx.conf" ]; then
        mv "/usr/local/openresty/nginx/conf/nginx.conf" "$BACKUP_DIR/nginx.conf.default.bak"
    fi
    ln -sf /etc/openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
}

configure_permissions() {
    log_info "در حال تنظیم دسترسی‌ها و Owner شیپ‌ها..."
    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html
    
    chown -R www-data:www-data /usr/local/openresty/nginx/logs
    chmod 755 /usr/local/openresty/nginx/logs

    chmod 644 /etc/logrotate.d/openresty
}

test_and_restart() {
    log_info "در حال تست پیکربندی OpenResty..."
    if openresty -t; then
        log_info "پیکربندی بدون خطا است. در حال راه‌اندازی مجدد سرویس..."
        systemctl enable openresty
        systemctl restart openresty
        log_info "نصب و راه‌اندازی با موفقیت به پایان رسید."
    else
        log_err "خطا در پیکربندی OpenResty. لطفاً ارورهای بالا را بررسی کنید."
    fi
}

cleanup() {
    log_info "در حال پاکسازی فایل‌های موقت..."
    rm -rf "$TEMP_DIR"
}

# ==========================================
# Main Execution Flow
# ==========================================
check_root
install_dependencies
create_directories
setup_dummy_ssl
clone_and_deploy
configure_permissions
test_and_restart
cleanup

log_info "در صورت نیاز به بررسی فایل‌های جایگزین‌شده، به دایرکتوری بکاپ مراجعه کنید: $BACKUP_DIR"
exit 0
