#!/bin/bash
# =========================================================
#  dsbr.sh - Domain & SSL Backup / Restore Tool (Optimized)
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

MODE=""
FILE=""

usage() {
    echo -e "${BLUE}Usage:${PLAIN}"
    echo -e "  bash dsbr.sh -b [zip_name]   备份当前 SSL 证书及 ACME 配置 (默认以域名命名)"
    echo -e "  bash dsbr.sh -r -f [file]    恢复指定 zip 压缩包中的 SSL 证书"
    echo -e "  bash dsbr.sh -h              显示帮助信息"
    exit 1
}

# 命令行参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--backup)
            MODE="backup"
            shift
            ;;
        -r|--restore)
            MODE="restore"
            shift
            ;;
        -f|--file)
            FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$FILE" && "$MODE" == "backup" ]]; then
                FILE="$1"
            fi
            shift
            ;;
    esac
done

[[ -z "$MODE" ]] && usage

# ================= 备份逻辑 =================
do_backup() {
    local domain=""

    # 1. 优先从已有证书提取 CN (自动去除泛域名 *. 前缀)
    if [[ -f "/var/www/ssl/de_GWD.cer" ]]; then
        domain=$(openssl x509 -subject -noout -in /var/www/ssl/de_GWD.cer 2>/dev/null | grep -o 'CN = .*' | cut -d= -f2 | xargs | sed 's/^\*\.//')
    fi

    # 2. 备选：从 Nginx 配置文件提取
    if [[ -z "$domain" && -f "/etc/nginx/conf.d/default.conf" ]]; then
        domain=$(awk '/server_name/ {print $2; exit}' /etc/nginx/conf.d/default.conf 2>/dev/null | sed 's/[;]//g')
    fi

    # 3. 备选：从 .acme.sh 目录中提取
    if [[ -z "$domain" && -d "/root/.acme.sh" ]]; then
        domain=$(ls /root/.acme.sh 2>/dev/null | grep '_ecc' | head -n 1 | sed 's/_ecc$//' | sed 's/^\*\.//')
    fi

    # 4. 生成带 .zip 后缀的文件名
    local default_name="${domain:-ssl_backup}.zip"
    local target_file="${FILE:-$default_name}"
    
    # 确保扩展名有 .zip
    [[ "$target_file" != *.zip ]] && target_file="${target_file}.zip"

    echo -e "${BLUE}[+] 正在为域名 ${YELLOW}${domain:-未知}${BLUE} 打包 SSL 证书与 ACME 配置...${PLAIN}"
    
    if [[ ! -d "/var/www/ssl" && ! -d "/root/.acme.sh" ]]; then
        echo -e "${RED}[!] 错误：未找到 /var/www/ssl 或 /root/.acme.sh 目录！${PLAIN}"
        exit 1
    fi

    # 从根节点标准相对路径打包
    cd /
    zip -rq "/tmp/$target_file" var/www/ssl root/.acme.sh 2>/dev/null
    mv -f "/tmp/$target_file" "./$target_file"

    echo -e "${GREEN}[✓] 备份成功！已生成备份文件: ${YELLOW}$target_file${PLAIN}"
}

# ================= 恢复逻辑 =================
do_restore() {
    [[ -z "$FILE" ]] && { echo -e "${RED}[!] 错误：恢复模式下必须指定 -f 参数！${PLAIN}"; exit 1; }
    [[ ! -f "$FILE" ]] && { echo -e "${RED}[!] 错误：找不到文件 $FILE${PLAIN}"; exit 1; }

    echo -e "${BLUE}[+] 正在智能解析与恢复证书: ${YELLOW}$FILE${PLAIN}..."

    local tmp_dir="/tmp/dsbr_restore_$(date +%s)"
    mkdir -p "$tmp_dir"
    unzip -qo "$FILE" -d "$tmp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[!] 错误：无法解压 $FILE，文件格式不正确或损坏！${PLAIN}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    mkdir -p /var/www/ssl /root/.acme.sh

    # 1. 智能提取 .cer 和 .key 文件到 /var/www/ssl
    local cert_file key_file
    cert_file=$(find "$tmp_dir" -type f \( -name "de_GWD.cer" -o -name "fullchain.cer" -o -name "*.cer" -o -name "*.crt" \) | head -n 1)
    key_file=$(find "$tmp_dir" -type f \( -name "de_GWD.key" -o -name "*.key" \) | head -n 1)

    if [[ -n "$cert_file" && -n "$key_file" ]]; then
        cp -f "$cert_file" /var/www/ssl/de_GWD.cer
        cp -f "$key_file" /var/www/ssl/de_GWD.key
        chmod 644 /var/www/ssl/de_GWD.cer /var/www/ssl/de_GWD.key
        echo -e "${GREEN}[✓] 已成功智能提取并放置 SSL 证书及私钥 -> /var/www/ssl/${PLAIN}"
    else
        echo -e "${YELLOW}[!] 警告：未在压缩包中识别到有效的 .cer 或 .key 文件！${PLAIN}"
    fi

    # 2. 智能搜寻并还原 ACME 目录 (支持多层级放置)
    local acme_found=0
    find "$tmp_dir" -type d -name "*_ecc" 2>/dev/null | while read -r ecc_path; do
        cp -rf "$ecc_path" /root/.acme.sh/ 2>/dev/null
        acme_found=1
    done

    if find "$tmp_dir" -type d -name ".acme.sh" 2>/dev/null | grep -q ".acme.sh"; then
        cp -rf "$tmp_dir"/*/.acme.sh/* /root/.acme.sh/ 2>/dev/null || cp -rf "$tmp_dir"/.acme.sh/* /root/.acme.sh/ 2>/dev/null
        acme_found=1
    fi

    if [[ $acme_found -eq 1 ]]; then
        echo -e "${GREEN}[✓] 已成功还原 ACME 自动续期配置 -> /root/.acme.sh/${PLAIN}"
    fi

    rm -rf "$tmp_dir"

    # 3. 证书可用性校验与到期打印
    if [[ -f "/var/www/ssl/de_GWD.cer" ]]; then
        local expire_date cert_domain
        expire_date=$(openssl x509 -enddate -noout -in /var/www/ssl/de_GWD.cer 2>/dev/null | cut -d= -f2)
        cert_domain=$(openssl x509 -subject -noout -in /var/www/ssl/de_GWD.cer 2>/dev/null | grep -o 'CN = .*' | cut -d= -f2 | xargs)
        
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
        echo -e "${GREEN}证书域名 (CN): ${YELLOW}${cert_domain:-未知}${PLAIN}"
        echo -e "${GREEN}证书到期时间:  ${YELLOW}${expire_date:-未知}${PLAIN}"
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    fi

    # 4. 自动重载服务
    echo -e "${BLUE}[+] 正在重启 Nginx 与 Xray 服务...${PLAIN}"
    systemctl restart nginx 2>/dev/null && echo -e "${GREEN}[✓] Nginx 服务已成功重载${PLAIN}"
    systemctl restart vtrui 2>/dev/null && echo -e "${GREEN}[✓] Xray (vtrui) 服务已成功重载${PLAIN}"
    
    echo -e "${GREEN}🎉 SSL 证书与配置已完美恢复！${PLAIN}"
}

case "$MODE" in
    backup)
        do_backup
        ;;
    restore)
        do_restore
        ;;
esac
