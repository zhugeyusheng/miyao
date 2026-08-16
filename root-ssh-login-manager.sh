#!/usr/bin/env bash
# root-ssh-login-manager.sh
# 管理 root 用户的 SSH 密钥/密码登录方式。
set -Eeuo pipefail

SSH_DIR='/root/.ssh'
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
SSHD_MAIN='/etc/ssh/sshd_config'
SSHD_DIR='/etc/ssh/sshd_config.d'
SSHD_DROPIN="$SSHD_DIR/99-root-login-manager.conf"

blue='\033[1;34m'; green='\033[1;32m'; yellow='\033[1;33m'; red='\033[1;31m'; reset='\033[0m'
info() { printf "%b[信息]%b %s\n" "$blue" "$reset" "$*"; }
ok() { printf "%b[成功]%b %s\n" "$green" "$reset" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$yellow" "$reset" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "$red" "$reset" "$*" >&2; exit 1; }
pause() { read -r -p '按 Enter 返回菜单…' _; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请以 root 身份运行：sudo bash root-ssh-login-manager.sh'
}

cleanup() {
  [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f -- "$TMP_FILE"
  [[ -n "${VALID_FILE:-}" && -f "$VALID_FILE" ]] && rm -f -- "$VALID_FILE"
  return 0
}
trap cleanup EXIT

root_key_count() {
  [[ -f "$AUTHORIZED_KEYS" ]] || { printf '0'; return; }
  awk '
    $1 ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ && $2 ~ /^[A-Za-z0-9+/]+={0,3}$/ { count++ }
    END { print count+0 }
  ' "$AUTHORIZED_KEYS"
}

find_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN='/usr/sbin/sshd'
  else
    die '未找到 sshd，拒绝修改 SSH 配置以避免无法校验。'
  fi
}

restore_ssh_config() {
  if [[ -n "${DROPIN_BACKUP:-}" && -f "$DROPIN_BACKUP" ]]; then
    mv -f -- "$DROPIN_BACKUP" "$SSHD_DROPIN"
  else
    rm -f -- "$SSHD_DROPIN"
  fi
  if [[ -n "${MAIN_BACKUP:-}" && -f "$MAIN_BACKUP" ]]; then
    mv -f -- "$MAIN_BACKUP" "$SSHD_MAIN"
  fi
}

ensure_manager_include() {
  local include_line tmp
  include_line="Include $SSHD_DROPIN"
  MAIN_BACKUP=''
  grep -Fqx "$include_line" "$SSHD_MAIN" 2>/dev/null && return

  MAIN_BACKUP="${SSHD_MAIN}.bak.root-login-manager.$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$SSHD_MAIN" "$MAIN_BACKUP"
  tmp="$(mktemp "${SSHD_MAIN}.XXXXXX")"
  {
    printf '%s\n' '# Added by root-ssh-login-manager.sh; keep this line before other SSH options.'
    printf '%s\n' "$include_line"
    cat "$SSHD_MAIN"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$SSHD_MAIN"
  info "已备份并更新 $SSHD_MAIN，以确保管理配置优先加载。"
}

verify_root_auth_mode() {
  local mode="$1" effective permit password pubkey
  effective="$("$SSHD_BIN" -T -f "$SSHD_MAIN" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
  permit="$(printf '%s\n' "$effective" | awk '$1 == "permitrootlogin" {print $2; exit}')"
  password="$(printf '%s\n' "$effective" | awk '$1 == "passwordauthentication" {print $2; exit}')"
  pubkey="$(printf '%s\n' "$effective" | awk '$1 == "pubkeyauthentication" {print $2; exit}')"

  case "$mode" in
    key) [[ ( "$permit" == 'prohibit-password' || "$permit" == 'without-password' ) && "$password" == 'no' && "$pubkey" == 'yes' ]] ;;
    password) [[ "$permit" == 'yes' && "$password" == 'yes' && "$pubkey" == 'no' ]] ;;
  esac
}
write_root_auth_config() {
  local mode="$1" content tmp
  find_sshd
  [[ -f "$SSHD_MAIN" ]] || die "未找到 SSH 主配置：$SSHD_MAIN"
  mkdir -p -- "$SSHD_DIR"
  DROPIN_BACKUP=''
  [[ -f "$SSHD_DROPIN" ]] && DROPIN_BACKUP="${SSHD_DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
  [[ -n "$DROPIN_BACKUP" ]] && cp -p -- "$SSHD_DROPIN" "$DROPIN_BACKUP"

  case "$mode" in
    key)
      content=$'# Managed by root-ssh-login-manager.sh\n# Root: key login only. Root SSH password login is disabled.\nPermitRootLogin prohibit-password\nMatch User root\n    AuthenticationMethods publickey\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    PubkeyAuthentication yes\nMatch all\n'
      ;;
    password)
      content=$'# Managed by root-ssh-login-manager.sh\n# Root: password login only. Root public-key login is disabled.\nPermitRootLogin yes\nMatch User root\n    AuthenticationMethods any\n    PasswordAuthentication yes\n    KbdInteractiveAuthentication no\n    PubkeyAuthentication no\nMatch all\n'
      ;;
    *) die '内部错误：未知认证模式' ;;
  esac

  tmp="$(mktemp "${SSHD_DIR}/.root-login-manager.XXXXXX")"
  printf '%s' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$SSHD_DROPIN"
  ensure_manager_include

  if ! "$SSHD_BIN" -t -f "$SSHD_MAIN"; then
    warn '新的 SSH 配置未通过校验，已回滚。'
    restore_ssh_config
    die '未修改 SSH 服务配置'
  fi
  if ! verify_root_auth_mode "$mode"; then
    warn 'SSH 生效配置未达到“仅一种 root 登录方式”的要求，已回滚。'
    restore_ssh_config
    die '未修改 SSH 服务配置'
  fi

  if reload_sshd; then
    ok 'SSH 配置已生效。请使用新终端验证登录，当前会话不要关闭。'
  else
    warn '配置已经写入并通过 sshd -t 校验，但自动 reload 失败。请手动 reload/restart ssh 服务后再测试。'
  fi
}

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null && return 0
    systemctl reload sshd 2>/dev/null && return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null && return 0
    service sshd reload 2>/dev/null && return 0
  fi
  return 1
}
root_authorized_keys_file_enabled() {
  local files
  find_sshd
  files="$("$SSHD_BIN" -T -f "$SSHD_MAIN" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '/^authorizedkeysfile / { $1=""; sub(/^ /, ""); print }')"
  [[ "$files" =~ (^|[[:space:]])(\.ssh/authorized_keys|%h/\.ssh/authorized_keys)([[:space:]]|$) ]]
}

ssh_self_check() {
  local effective permit password pubkey key_files current_mode
  clear
  echo '================================================'
  echo '              Root SSH 登录状态自检'
  echo '================================================'
  find_sshd
  if "$SSHD_BIN" -t -f "$SSHD_MAIN"; then
    ok 'SSH 配置检查：通过'
  else
    warn 'SSH 配置检查：失败，请勿切换 root 登录方式。'
    pause
    return
  fi

  effective="$("$SSHD_BIN" -T -f "$SSHD_MAIN" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
  [[ -n "$effective" ]] || { warn '无法读取 root 的实际 SSH 配置。'; pause; return; }
  permit="$(printf '%s\n' "$effective" | awk '$1 == "permitrootlogin" {print $2; exit}')"
  password="$(printf '%s\n' "$effective" | awk '$1 == "passwordauthentication" {print $2; exit}')"
  pubkey="$(printf '%s\n' "$effective" | awk '$1 == "pubkeyauthentication" {print $2; exit}')"
  key_files="$(printf '%s\n' "$effective" | awk '/^authorizedkeysfile / { $1=""; sub(/^ /, ""); print; exit }')"

  if [[ ( "$permit" == 'prohibit-password' || "$permit" == 'without-password' ) && "$password" == 'no' && "$pubkey" == 'yes' ]]; then
    current_mode='root SSH 密钥登录'
  elif [[ "$permit" == 'yes' && "$password" == 'yes' && "$pubkey" == 'no' ]]; then
    current_mode='root SSH 密码登录'
  elif [[ "$permit" == 'no' ]]; then
    current_mode='root SSH 登录已禁止'
  else
    current_mode='root SSH 登录状态异常或未识别'
  fi

  echo "当前模式：$current_mode"
  echo "公钥文件位置：${key_files:-未读取到}"
  echo "有效 root 公钥数量：$(root_key_count)"

  if root_authorized_keys_file_enabled; then
    ok "SSH 会读取：$AUTHORIZED_KEYS"
  else
    warn "SSH 不会读取 $AUTHORIZED_KEYS；导入的密钥无法用于 root 登录。"
  fi
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    echo "文件权限：.ssh=$(stat -c '%a' "$SSH_DIR" 2>/dev/null || echo '未知')，authorized_keys=$(stat -c '%a' "$AUTHORIZED_KEYS" 2>/dev/null || echo '未知')"
  else
    echo '公钥文件：尚未创建'
  fi
  pause
}
import_github_keys() {
  local username keys_url added=0 key identity backup=''
  read -r -p '请输入 GitHub 用户名（不含 @）：' username
  username="${username#@}"
  [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || die 'GitHub 用户名格式无效'

  keys_url="https://github.com/${username}.keys"
  cleanup
  TMP_FILE="$(mktemp)"
  VALID_FILE="${TMP_FILE}.valid"
  info "正在获取：$keys_url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --silent --show-error --connect-timeout 10 --max-time 30 "$keys_url" -o "$TMP_FILE" || die '下载失败：请检查用户名或网络连接'
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$TMP_FILE" "$keys_url" || die '下载失败：请检查用户名或网络连接'
  else
    die '系统中未找到 curl 或 wget'
  fi

  : > "$VALID_FILE"
  while IFS= read -r key || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    [[ "$key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || continue
    if command -v ssh-keygen >/dev/null 2>&1; then
      printf '%s\n' "$key" | ssh-keygen -l -f - >/dev/null 2>&1 || continue
    fi
    printf '%s\n' "$key" >> "$VALID_FILE"
  done < "$TMP_FILE"
  mv -- "$VALID_FILE" "$TMP_FILE"
  VALID_FILE=''
  [[ -s "$TMP_FILE" ]] || die "GitHub 用户 $username 没有可用的公开 SSH 密钥"

  mkdir -p -- "$SSH_DIR"
  touch -- "$AUTHORIZED_KEYS"
  chmod 700 "$SSH_DIR"
  chmod 600 "$AUTHORIZED_KEYS"

  while IFS= read -r key; do
    identity="$(printf '%s\n' "$key" | awk '{print $1 " " $2}')"
    if awk -v wanted="$identity" 'NF >= 2 && ($1 " " $2) == wanted { found=1; exit } END { exit !found }' "$AUTHORIZED_KEYS"; then
      warn "已存在，跳过：$(printf '%s\n' "$key" | awk '{print $1 " " substr($2,1,16) "..."}')"
    else
      if ((added == 0)) && [[ -s "$AUTHORIZED_KEYS" ]]; then
        backup="${AUTHORIZED_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p -- "$AUTHORIZED_KEYS" "$backup"
        info "已备份旧公钥文件：$backup"
      fi
      printf '%s\n' "$key" >> "$AUTHORIZED_KEYS"
      ((added+=1))
    fi
  done < "$TMP_FILE"
  chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"
  ok "GitHub 公钥导入完成：新增 $added 条；当前共有 $(root_key_count) 条。"

  if (( $(root_key_count) > 0 )) && root_authorized_keys_file_enabled; then
    echo
    warn 'GitHub 公钥导入完成，正在自动切换为 root 仅密钥登录。'
    warn '请保留当前 SSH 会话，并立即用新的 SSH 终端测试密钥登录。'
    write_root_auth_config key
  else
    warn 'SSH 未确认读取 /root/.ssh/authorized_keys，因此没有禁止 root 密码登录。'
  fi
}

key_login_menu() {
  while true; do
    clear
    echo '================================================'
    echo '             Root 密钥登录管理'
    echo '================================================'
    echo "当前 root 公钥数量：$(root_key_count)"
    echo '------------------------------------------------'
    echo '1. 从 GitHub 导入已有公钥（导入后自动启用仅密钥登录）'
    echo '2. 查看 root 已授权公钥'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) import_github_keys; pause ;;
      2) [[ -f "$AUTHORIZED_KEYS" ]] && cat "$AUTHORIZED_KEYS" || info '暂无已授权公钥'; pause ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

password_login_menu() {
  clear
  echo '================================================'
  echo '             Root 密码登录管理'
  echo '================================================'
  warn '即将允许 root 使用 SSH 密码登录，并全局启用 PasswordAuthentication。'
  warn '密码登录存在暴力破解风险，请设置强密码并限制防火墙来源 IP。'
  if ! passwd root; then
    warn 'root 密码未设置，未改变 SSH 登录方式。'
    pause
    return
  fi
  write_root_auth_config password
  ok 'root 密码登录已启用。'
  pause
}

main_menu() {
  require_root
  while true; do
    clear
    echo '================================================'
    echo '        ____             __  ____  __  '
    echo '       / __ \\___  ____  / /_/ __ \\/ /_'
    echo '      / /_/ / _ \\/ __ \\/ __/ / / / __/'
    echo '     / _, _/  __/ / / / / /_/ /_/ / /_'
    echo '    /_/ |_|\\___/_/ /_/\\__/\\____/\\__/'
    echo '          Root SSH 登录方式一键管理'
    echo '================================================'
    echo '1. 用户 root：密钥登录'
    echo '2. 用户 root：密码登录（自动启用）'
    echo '3. 自检 root SSH 认证配置'
    echo '0. 退出'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) key_login_menu ;;
      2) password_login_menu ;;
      3) ssh_self_check ;;
      0) clear; exit 0 ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

main_menu
