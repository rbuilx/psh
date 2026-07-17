#!/usr/bin/env bash
# SSL certificate backup and restore tool for server/client.
# -b backs up, -r restores, and -f selects an archive.
set -euo pipefail

SSL_DIR="${DSBR_SSL_DIR:-/var/www/ssl}"
ACME_ROOT="${DSBR_ACME_ROOT:-/root/.acme.sh}"
BACKUP_DIR="${DSBR_BACKUP_DIR:-$PWD}"
ARCHIVE="${DSBR_ARCHIVE:-}"
TMP_DIR=""

die(){ echo "dsbr.sh: $*" >&2; exit 1; }
cleanup(){ [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_zip(){
  command -v zip >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zip >/dev/null 2>&1 && return 0
  fi
  die "missing command: zip; install zip and try again"
}

certificate_domain(){
  openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/^subject=CN=//p' | cut -d, -f1 | sed 's/^\*\.//' \
    | tr -cd 'A-Za-z0-9._-'
}

public_key_hash(){
  openssl x509 -in "$1" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

private_key_hash(){
  openssl pkey -in "$1" -pubout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

validate_pair(){
  local cert="$1" key="$2"
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 \
    || die "certificate is missing or expired"
  [[ -s "$key" ]] || die "private key is missing"
  [[ "$(public_key_hash "$cert")" == "$(private_key_hash "$key")" ]] \
    || die "certificate and private key do not match"
}

find_acme_dir(){
  local cert="$1" domain="$2" d hash matches=()
  hash=$(public_key_hash "$cert")
  for d in "$ACME_ROOT"/*_ecc; do
    [[ -d "$d" ]] || continue
    if [[ -s "$d/fullchain.cer" ]] && [[ "$(public_key_hash "$d/fullchain.cer")" == "$hash" ]]; then
      matches+=("$d")
    fi
  done
  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  if [[ -d "$ACME_ROOT/${domain}_ecc" ]]; then
    printf '%s\n' "$ACME_ROOT/${domain}_ecc"
    return 0
  fi
  [[ ${#matches[@]} -eq 0 ]] && die "could not match the deployed certificate to an ACME *_ecc directory"
  die "multiple ACME *_ecc directories match the deployed certificate"
}

backup(){
  local cert="$SSL_DIR/de_GWD.cer" key="$SSL_DIR/de_GWD.key" domain acme_dir output
  [[ -f "$cert" && -f "$key" ]] || die "certificate or private key not found in $SSL_DIR"
  domain=$(certificate_domain "$cert")
  [[ -n "$domain" ]] || die "could not read the domain from the certificate"
  acme_dir=$(find_acme_dir "$cert" "$domain")
  [[ -d "$SSL_DIR" ]] || die "SSL directory not found: $SSL_DIR"
  [[ -n "$ARCHIVE" ]] || ARCHIVE="$BACKUP_DIR/${domain}.zip"

  mkdir -p "$BACKUP_DIR"
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/root/.acme.sh" "$TMP_DIR/var/www"
  cp -a "$acme_dir" "$TMP_DIR/root/.acme.sh/"
  cp -a "$SSL_DIR" "$TMP_DIR/var/www/ssl"
  output="$TMP_DIR/archive.zip"
  (cd "$TMP_DIR" && zip -qr "$output" root var)
  install -m 0600 "$output" "$ARCHIVE"
  echo "Backup complete: $ARCHIVE"
  echo "ACME directory: $acme_dir"
}

validate_archive_paths(){
  local member
  while IFS= read -r member; do
    case "$member" in
      /*|../*|*/../*|*//* ) die "unsafe archive path: $member" ;;
    esac
  done < <(unzip -Z1 "$ARCHIVE")
}

restore(){
  local extract acme_dir cert key domain stamp current_backup old_ssl old_acme
  if [[ -z "$ARCHIVE" ]]; then
    mapfile -t candidates < <(find "$PWD" -maxdepth 1 -type f -name '*.zip' -print)
    [[ ${#candidates[@]} -eq 1 ]] || die "use -f when the current directory does not contain exactly one *.zip"
    ARCHIVE="${candidates[0]}"
  fi
  [[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
  TMP_DIR=$(mktemp -d)
  validate_archive_paths
  unzip -q "$ARCHIVE" -d "$TMP_DIR/extract"
  extract="$TMP_DIR/extract"
  [[ -d "$extract/root/.acme.sh" && -d "$extract/var/www/ssl" ]] \
    || die "archive must contain root/.acme.sh and var/www/ssl"

  mapfile -t acme_dirs < <(find "$extract/root/.acme.sh" -mindepth 1 -maxdepth 1 -type d -name '*_ecc' -print)
  [[ ${#acme_dirs[@]} -eq 1 ]] || die "archive must contain exactly one ACME *_ecc directory"
  acme_dir="${acme_dirs[0]}"
  cert="$extract/var/www/ssl/de_GWD.cer"
  key="$extract/var/www/ssl/de_GWD.key"
  [[ -f "$cert" && -f "$key" ]] || die "archive is missing de_GWD.cer or de_GWD.key"
  validate_pair "$cert" "$key"
  domain=$(certificate_domain "$cert")

  stamp=$(date +%Y%m%d%H%M%S)
  current_backup="$BACKUP_DIR/${domain}-before-$stamp"
  mkdir -p "$current_backup"
  [[ -d "$ACME_ROOT" ]] && cp -a "$ACME_ROOT" "$current_backup/acme.sh" || true
  [[ -d "$SSL_DIR" ]] && cp -a "$SSL_DIR" "$current_backup/ssl" || true

  old_ssl="$SSL_DIR"
  old_acme="$ACME_ROOT/$(basename "$acme_dir")"
  rm -rf "$old_ssl" "$old_acme"
  mkdir -p "$ACME_ROOT" "$(dirname "$SSL_DIR")"
  cp -a "$extract/var/www/ssl" "$SSL_DIR"
  cp -a "$acme_dir" "$ACME_ROOT/"
  chown -R root:root "$SSL_DIR" "$old_acme"
  chmod 0700 "$ACME_ROOT" "$old_acme"
  find "$SSL_DIR" -type f -name '*.key' -exec chmod 0600 {} +

  if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
    rm -rf "$old_ssl" "$old_acme"
    [[ -d "$current_backup/ssl" ]] && cp -a "$current_backup/ssl" "$old_ssl"
    [[ -d "$current_backup/acme.sh/$(basename "$old_acme")" ]] && cp -a "$current_backup/acme.sh/$(basename "$old_acme")" "$old_acme"
    die "nginx configuration test failed; the previous certificate was restored"
  fi
  systemctl is-active --quiet nginx && systemctl reload nginx || true
  echo "Restore complete: $SSL_DIR and $old_acme"
  echo "Previous certificate backup: $current_backup"
}

usage(){
  echo "Usage: $0 -b [-f archive] | $0 -r [-f archive]" >&2
  echo "Backup names use the certificate domain; restore auto-selects a single *.zip" >&2
  echo "Variables: DSBR_SSL_DIR DSBR_ACME_ROOT DSBR_BACKUP_DIR DSBR_ARCHIVE" >&2
  exit 2
}

mode=""
while getopts ":brf:h" opt; do
  case "$opt" in
    b) mode="backup" ;;
    r) mode="restore" ;;
    f) ARCHIVE="$OPTARG" ;;
    h) usage ;;
    :) die "option -$OPTARG requires an argument" ;;
    \?) usage ;;
  esac
done

require_root
need openssl
need unzip
case "$mode" in
  backup) need_zip; backup ;;
  restore) restore ;;
  *) usage ;;
esac
