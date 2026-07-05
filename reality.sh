#!/bin/bash

set -e

SERVICE_NAME="xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

DEFAULT_SNI="www.paypal.com"
DEFAULT_FP="chrome"
DEFAULT_NODE_NAME="VLESS-Reality"
RANDOM_PORT_MIN=10000
RANDOM_PORT_MAX=65535

clear
echo "======================================"
echo " VLESS + Reality + Vision + TCP 一键脚本"
echo " 随机端口范围：${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX}"
echo " 适用于 Ubuntu / Debian"
echo "======================================"
echo ""

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户执行"
  echo "示例：sudo bash reality.sh"
  exit 1
fi

check_system() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$ID"
  else
    echo "无法识别系统"
    exit 1
  fi

  case "$OS_NAME" in
    ubuntu|debian)
      echo "系统检测通过：$PRETTY_NAME"
      ;;
    *)
      echo "当前系统可能不是 Ubuntu / Debian，脚本仍会尝试继续安装"
      ;;
  esac
}

install_base_packages() {
  echo ""
  echo "正在安装基础依赖..."
  apt update -y
  apt install -y curl wget unzip socat cron ufw net-tools iproute2 procps openssl ca-certificates
}

install_xray() {
  echo ""
  echo "正在安装 / 更新 Xray Core..."

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if [ ! -f "$XRAY_BIN" ]; then
    echo "错误：Xray 安装失败，未找到 $XRAY_BIN"
    exit 1
  fi

  echo "Xray 安装完成：$($XRAY_BIN version | head -n 1)"
}

random_port() {
  while true; do
    PORT=$(shuf -i ${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX} -n 1)

    if ! ss -lntup | grep -q ":$PORT "; then
      echo "$PORT"
      return
    fi
  done
}

random_short_id() {
  openssl rand -hex 8
}

get_public_ip() {
  IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)

  if [ -z "$IP" ]; then
    IP=$(curl -4 -s --max-time 8 https://ipv4.icanhazip.com || true)
  fi

  if [ -z "$IP" ]; then
    IP=$(curl -4 -s --max-time 8 https://ifconfig.me || true)
  fi

  if [ -z "$IP" ]; then
    IP=$(hostname -I | awk '{print $1}')
  fi

  echo "$IP"
}

validate_port() {
  PORT_TO_CHECK="$1"

  if ! [[ "$PORT_TO_CHECK" =~ ^[0-9]+$ ]]; then
    echo "错误：端口必须是数字"
    exit 1
  fi

  if [ "$PORT_TO_CHECK" -lt 1 ] || [ "$PORT_TO_CHECK" -gt 65535 ]; then
    echo "错误：端口范围必须是 1-65535"
    exit 1
  fi

  if [ "$PORT_TO_CHECK" -lt 10000 ]; then
    echo "错误：端口不能低于 10000"
    exit 1
  fi

  if ss -lntup | grep -q ":$PORT_TO_CHECK "; then
    echo "错误：端口 $PORT_TO_CHECK 已被占用，请换一个端口"
    exit 1
  fi
}

open_firewall_port() {
  PORT_TO_OPEN="$1"

  echo ""
  echo "正在放行防火墙端口：$PORT_TO_OPEN/tcp"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT_TO_OPEN"/tcp >/dev/null 2>&1 || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$PORT_TO_OPEN" -j ACCEPT 2>/dev/null || true
  fi
}

generate_reality_keys() {
  echo ""
  echo "正在生成 Reality 密钥..."

  KEY_OUTPUT=$($XRAY_BIN x25519 2>/dev/null || true)

  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "^PrivateKey:" | awk '{print $2}')
  PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "PublicKey" | awk '{print $3}')

  if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "private" | sed 's/.*[: ]//g' | tr -d ' ')
  fi

  if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "public" | sed 's/.*[: ]//g' | tr -d ' ')
  fi

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "错误：Reality 密钥生成失败"
    echo "Xray 原始输出如下："
    echo "$KEY_OUTPUT"
    echo ""
    echo "请手动执行查看："
    echo "$XRAY_BIN x25519"
    exit 1
  fi

  echo "Reality 密钥生成成功"
}

generate_uuid() {
  echo ""
  echo "正在生成 UUID..."

  UUID=$($XRAY_BIN uuid)

  if [ -z "$UUID" ]; then
    echo "错误：UUID 生成失败"
    exit 1
  fi
}

backup_old_config() {
  if [ -f "$XRAY_CONFIG" ]; then
    BACKUP_FILE="${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$XRAY_CONFIG" "$BACKUP_FILE"
    echo "已备份旧配置：$BACKUP_FILE"
  fi
}

write_xray_config() {
  mkdir -p /usr/local/etc/xray

  backup_old_config

  echo ""
  echo "正在写入 Xray 配置..."

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "reality-user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI_DOMAIN:443",
          "xver": 0,
          "serverNames": [
            "$SNI_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

test_xray_config() {
  echo ""
  echo "正在检测 Xray 配置..."

  if "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; then
    echo "配置检测通过"
  else
    echo "错误：Xray 配置检测失败"
    exit 1
  fi
}

start_xray() {
  echo ""
  echo "正在启动 Xray..."

  systemctl restart "$SERVICE_NAME"
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true

  sleep 2

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Xray 启动成功"
  else
    echo "错误：Xray 启动失败，请查看日志："
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager
    exit 1
  fi
}

url_encode_node_name() {
  NODE_NAME_ENCODED=$(printf '%s' "$NODE_NAME" | sed 's/ /%20/g')
}

show_result() {
  IP=$(get_public_ip)
  url_encode_node_name

  VLESS_URL="vless://$UUID@$IP:$VLESS_PORT?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=$SNI_DOMAIN&pbk=$PUBLIC_KEY&sid=$SHORT_ID&fp=$FINGERPRINT#$NODE_NAME_ENCODED"

  echo ""
  echo "======================================"
  echo " VLESS + Reality + Vision 安装完成"
  echo "======================================"
  echo "服务器 IP：$IP"
  echo "端口：$VLESS_PORT"
  echo "UUID：$UUID"
  echo "协议：VLESS"
  echo "传输：TCP"
  echo "安全：Reality"
  echo "Flow：xtls-rprx-vision"
  echo "SNI：$SNI_DOMAIN"
  echo "Fingerprint：$FINGERPRINT"
  echo "Public Key：$PUBLIC_KEY"
  echo "Short ID：$SHORT_ID"
  echo "节点名称：$NODE_NAME"
  echo ""
  echo "VLESS 分享链接："
  echo "$VLESS_URL"
  echo ""
  echo "Shadowrocket 手动填写："
  echo "类型：VLESS"
  echo "服务器：$IP"
  echo "端口：$VLESS_PORT"
  echo "UUID：$UUID"
  echo "加密：none"
  echo "传输协议：TCP"
  echo "TLS / 安全：Reality"
  echo "Flow：xtls-rprx-vision"
  echo "SNI：$SNI_DOMAIN"
  echo "Public Key：$PUBLIC_KEY"
  echo "Short ID：$SHORT_ID"
  echo "Fingerprint：$FINGERPRINT"
  echo ""
  echo "Mihomo / Clash Meta 配置："
  echo "- name: $NODE_NAME"
  echo "  type: vless"
  echo "  server: $IP"
  echo "  port: $VLESS_PORT"
  echo "  uuid: $UUID"
  echo "  network: tcp"
  echo "  tls: true"
  echo "  udp: true"
  echo "  flow: xtls-rprx-vision"
  echo "  servername: $SNI_DOMAIN"
  echo "  client-fingerprint: $FINGERPRINT"
  echo "  reality-opts:"
  echo "    public-key: $PUBLIC_KEY"
  echo "    short-id: $SHORT_ID"
  echo ""
  echo "管理命令："
  echo "systemctl status xray"
  echo "systemctl restart xray"
  echo "systemctl stop xray"
  echo "journalctl -u xray -n 80 --no-pager"
  echo ""
  echo "配置文件：$XRAY_CONFIG"
  echo "开机自启：已开启"
  echo "======================================"
}

install_reality() {
  check_system
  install_base_packages
  install_xray

  echo ""
  echo "请选择安装模式："
  echo "1) 自定义端口 / SNI / 指纹 / 节点名称"
  echo "2) 随机端口 / 默认 SNI"
  echo ""

  read -p "请输入选项 [1/2]，默认 2: " MODE
  MODE=${MODE:-2}

  if [ "$MODE" = "1" ]; then
    read -p "请输入端口，必须 >=10000，例如 31566: " VLESS_PORT
    read -p "请输入 SNI 域名，默认 $DEFAULT_SNI: " SNI_DOMAIN
    read -p "请输入浏览器指纹，默认 $DEFAULT_FP: " FINGERPRINT
    read -p "请输入节点名称，默认 $DEFAULT_NODE_NAME: " NODE_NAME

    SNI_DOMAIN=${SNI_DOMAIN:-$DEFAULT_SNI}
    FINGERPRINT=${FINGERPRINT:-$DEFAULT_FP}
    NODE_NAME=${NODE_NAME:-$DEFAULT_NODE_NAME}
  else
    VLESS_PORT=$(random_port)
    SNI_DOMAIN="$DEFAULT_SNI"
    FINGERPRINT="$DEFAULT_FP"
    NODE_NAME="$DEFAULT_NODE_NAME"
  fi

  validate_port "$VLESS_PORT"

  generate_uuid
  generate_reality_keys
  SHORT_ID=$(random_short_id)

  write_xray_config
  test_xray_config
  open_firewall_port "$VLESS_PORT"
  start_xray
  show_result
}

show_status() {
  echo "======================================"
  echo " Xray Reality 状态"
  echo "======================================"

  systemctl status "$SERVICE_NAME" --no-pager || true

  echo ""
  echo "监听端口："
  ss -lntup | grep xray || true

  echo ""
  echo "最近日志："
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true

  echo ""
  echo "配置文件路径：$XRAY_CONFIG"
}

show_config() {
  echo "======================================"
  echo " 当前 Xray 配置文件"
  echo "======================================"

  if [ -f "$XRAY_CONFIG" ]; then
    cat "$XRAY_CONFIG"
  else
    echo "未找到 $XRAY_CONFIG"
  fi
}

restart_reality() {
  echo ""
  echo "正在重启 Xray..."

  systemctl restart "$SERVICE_NAME"

  sleep 2

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Xray 重启成功"
  else
    echo "Xray 重启失败"
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager
  fi
}

uninstall_reality() {
  echo "警告：即将卸载 Xray Reality"
  echo "这会删除 Xray 程序和配置文件"
  read -p "确认卸载吗？输入 y 确认: " CONFIRM

  if [ "$CONFIRM" != "y" ]; then
    echo "已取消卸载"
    exit 0
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true

  echo "Xray Reality 已卸载"
}

main_menu() {
  echo "请选择操作："
  echo "1) 安装 / 重装 VLESS + Reality + Vision"
  echo "2) 查看状态"
  echo "3) 查看配置"
  echo "4) 重启服务"
  echo "5) 卸载"
  echo ""

  read -p "请输入选项 [1/2/3/4/5]，默认 1: " ACTION
  ACTION=${ACTION:-1}

  case "$ACTION" in
    1)
      install_reality
      ;;
    2)
      show_status
      ;;
    3)
      show_config
      ;;
    4)
      restart_reality
      ;;
    5)
      uninstall_reality
      ;;
    *)
      echo "无效选项"
      exit 1
      ;;
  esac
}

main_menu
