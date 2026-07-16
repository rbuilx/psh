#!/usr/bin/env bash
set -euo pipefail

SSL_DIR="${DSBR_SSL_DIR:-/var/www/ssl}"
BACKUP_DIR="${DSBR_BACKUP_DIR:-$PWD}"
ARCHIVE="${DSBR_ARCHIVE:-}"
TMP_DIR=""

die(){ echo "dsbr.sh: $*" >&2; exit 1; }
cleanup(){ [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

archive_member(){
  local suffix="$1" member
  member=$(unzip -Z1 "$ARCHIVE" | awk -v s="$suffix" '$0 ~ "(^|/)" s "$" {print; exit}')
  [[ -n "$member" ]] || die "压缩包中找不到 $suffix"
  printf '%s\n' "$member"
}

validate_pair(){
  local cert="$1" key="$2"
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || die "证书不存在或已过期"
  openssl x509 -in "$cert" -pubkey -noout >"$TMP_DIR/cert.pub"
  openssl pkey -in "$key" -pubout >"$TMP_DIR/key.pub"
  cmp -s "$TMP_DIR/cert.pub" "$TMP_DIR/key.pub" || die "证书与私钥不匹配"
}

backup(){
  local output domain
  for file in de_GWD.cer de_GWD.key dhparam.pem; do
    [[ -f "$SSL_DIR/$file" ]] || die "找不到 $SSL_DIR/$file"
  done
  domain=$(openssl x509 -in "$SSL_DIR/de_GWD.cer" -noout -subject -nameopt RFC2253 | sed -n 's/^subject=CN=//p' | cut -d, -f1 | sed 's/^\*\.//' | tr -cd 'A-Za-z0-9._-')
  [[ -n "$domain" ]] || die "无法从证书读取域名"
  [[ -n "$ARCHIVE" ]] || ARCHIVE="$BACKUP_DIR/${domain}.zip"
  mkdir -p "$BACKUP_DIR"
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/vinx.eu.org_ecc"
  cp -a "$SSL_DIR/de_GWD.cer" "$SSL_DIR/de_GWD.key" "$SSL_DIR/dhparam.pem" "$TMP_DIR/vinx.eu.org_ecc/"
  output="$TMP_DIR/dsbr.zip"
  (cd "$TMP_DIR" && zip -qr "$output" vinx.eu.org_ecc)
  install -m 0600 "$output" "$ARCHIVE"
  echo "备份完成: $ARCHIVE"
}

restore(){
  local cert_member key_member dh_member stamp current_backup candidate_count
  if [[ -z "$ARCHIVE" ]]; then
    candidate_count=$(find "$PWD" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' ')
    if [[ "$candidate_count" == 1 ]]; then
      ARCHIVE=$(find "$PWD" -maxdepth 1 -type f -name '*.zip' -print -quit)
    else
      die "当前目录没有唯一的 *.zip，请使用 -f 指定备份文件"
    fi
  fi
  [[ -f "$ARCHIVE" ]] || die "找不到备份: $ARCHIVE"
  TMP_DIR=$(mktemp -d)
  cert_member=$(archive_member de_GWD.cer)
  key_member=$(archive_member de_GWD.key)
  dh_member=$(archive_member dhparam.pem)
  unzip -p "$ARCHIVE" "$cert_member" >"$TMP_DIR/de_GWD.cer"
  unzip -p "$ARCHIVE" "$key_member" >"$TMP_DIR/de_GWD.key"
  unzip -p "$ARCHIVE" "$dh_member" >"$TMP_DIR/dhparam.pem"
  validate_pair "$TMP_DIR/de_GWD.cer" "$TMP_DIR/de_GWD.key"

  mkdir -p "$SSL_DIR"
  stamp=$(date +%Y%m%d%H%M%S)
  current_backup="$BACKUP_DIR/de_GWD-before-$stamp"
  mkdir -p "$current_backup"
  for file in de_GWD.cer de_GWD.key dhparam.pem; do
    [[ -f "$SSL_DIR/$file" ]] && cp -a "$SSL_DIR/$file" "$current_backup/"
  done

  install -o root -g root -m 0644 "$TMP_DIR/de_GWD.cer" "$SSL_DIR/de_GWD.cer"
  install -o root -g root -m 0600 "$TMP_DIR/de_GWD.key" "$SSL_DIR/de_GWD.key"
  install -o root -g root -m 0644 "$TMP_DIR/dhparam.pem" "$SSL_DIR/dhparam.pem"

  if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
    for file in de_GWD.cer de_GWD.key dhparam.pem; do
      [[ -f "$current_backup/$file" ]] && cp -a "$current_backup/$file" "$SSL_DIR/$file"
    done
    chmod 0644 "$SSL_DIR/de_GWD.cer" "$SSL_DIR/dhparam.pem"
    chmod 0600 "$SSL_DIR/de_GWD.key"
    die "nginx 检查失败，已恢复旧证书"
  fi
  systemctl is-active --quiet nginx && systemctl reload nginx || true
  echo "恢复完成: $SSL_DIR"
  echo "旧证书备份: $current_backup"
}

usage(){
  echo "用法: $0 -b [-f 备份文件] | $0 -r [-f 指定证书压缩包]" >&2
  echo "-b 默认按证书 CN 生成 <域名>.zip；-r 当前目录仅有一个 *.zip 时自动选择" >&2
  echo "变量: DSBR_SSL_DIR DSBR_BACKUP_DIR DSBR_ARCHIVE" >&2
  exit 2
}

mode=""
while getopts ":brf:h" opt; do
  case "$opt" in
    b) mode="backup" ;;
    r) mode="restore" ;;
    f) ARCHIVE="$OPTARG" ;;
    h) usage ;;
    :) die "选项 -$OPTARG 需要参数" ;;
    \?) usage ;;
  esac
done

require_root
need openssl
need unzip
case "$mode" in
  backup) need zip; backup ;;
  restore) restore ;;
  *) usage ;;
esac
