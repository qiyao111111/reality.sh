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
echo " 支持：绿色二维码 + BBR + 上海时间 + IP地区自动命名"
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
    echo "错误：无法识别系统"
    exit 1
  fi

  case "$OS_NAME" in
    ubuntu|debian)
      echo "系统检测通过：$PRETTY_NAME"
      ;;
    *)
      echo "提醒：当前系统可能不是 Ubuntu / Debian，脚本仍会尝试继续安装"
      ;;
  esac
}

install_base_packages() {
  echo ""
  echo "正在安装基础依赖..."

  apt update -y
  apt install -y curl wget unzip socat cron ufw net-tools iproute2 procps openssl ca-certificates qrencode jq
}

set_shanghai_time() {
  echo ""
  echo "正在设置系统时区为 Asia/Shanghai..."

  timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
    systemctl restart systemd-timesyncd 2>/dev/null || true
  fi

  CURRENT_TIMEZONE=$(timedatectl 2>/dev/null | grep "Time zone" | awk -F': ' '{print $2}' || echo "unknown")
  CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")

  echo "当前时区：$CURRENT_TIMEZONE"
  echo "当前时间：$CURRENT_TIME"

  if timedatectl 2>/dev/null | grep -q "Asia/Shanghai"; then
    echo "上海时间设置成功"
  else
    echo "提醒：时区设置可能未成功，请手动检查：timedatectl"
  fi
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

sanitize_name() {
  echo "$1" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-'
}

get_ipinfo() {
  IPINFO_JSON=$(curl -4 -s --max-time 10 https://ipinfo.io/json || true)

  PUBLIC_IP=""
  IP_COUNTRY=""
  IP_REGION=""
  IP_CITY=""

  if command -v jq >/dev/null 2>&1 && [ -n "$IPINFO_JSON" ]; then
    PUBLIC_IP=$(echo "$IPINFO_JSON" | jq -r '.ip // empty')
    IP_COUNTRY=$(echo "$IPINFO_JSON" | jq -r '.country // empty')
    IP_REGION=$(echo "$IPINFO_JSON" | jq -r '.region // empty')
    IP_CITY=$(echo "$IPINFO_JSON" | jq -r '.city // empty')
  fi

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)
  fi

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -4 -s --max-time 8 https://ipv4.icanhazip.com || true)
  fi

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -4 -s --max-time 8 https://ifconfig.me || true)
  fi

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi

  IP_COUNTRY=${IP_COUNTRY:-UnknownCountry}
  IP_REGION=${IP_REGION:-UnknownRegion}
  IP_CITY=${IP_CITY:-UnknownCity}
}

generate_node_name_by_ipinfo() {
  get_ipinfo

  CLEAN_COUNTRY=$(sanitize_name "$IP_COUNTRY")
  CLEAN_REGION=$(sanitize_name "$IP_REGION")
  CLEAN_CITY=$(sanitize_name "$IP_CITY")

  IP_LAST_TWO=$(echo "$PUBLIC_IP" | awk -F'.' '{print $(NF-1)"."$NF}')

  if [ -z "$IP_LAST_TWO" ]; then
    IP_LAST_TWO="$PUBLIC_IP"
  fi

  AUTO_NODE_NAME="REALITY-${CLEAN_COUNTRY}-${CLEAN_CITY}-${IP_LAST_TWO}"

  if [ -z "$CLEAN_CITY" ] || [ "$CLEAN_CITY" = "UnknownCity" ]; then
    AUTO_NODE_NAME="REALITY-${CLEAN_COUNTRY}-${CLEAN_REGION}-${IP_LAST_TWO}"
  fi

  if [ -z "$AUTO_NODE_NAME" ]; then
    AUTO_NODE_NAME="$DEFAULT_NODE_NAME"
  fi
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

  echo "提醒：如果 VPS 云后台有安全组，也要手动放行 TCP $PORT_TO_OPEN"
}

enable_bbr() {
  echo ""
  echo "正在开启 BBR..."

  modprobe tcp_bbr 2>/dev/null || true

  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system >/dev/null 2>&1 || true

  CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
  CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)

  echo "当前拥塞控制算法：$CURRENT_CC"
  echo "当前队列算法：$CURRENT_QDISC"

  if [ "$CURRENT_CC" = "bbr" ]; then
    echo "BBR 已成功开启"
  else
    echo "提醒：BBR 未成功开启，可能是内核或 VPS 限制"
  fi
}

generate_uuid() {
  echo ""
  echo "正在生成 UUID..."

  UUID=$($XRAY_BIN uuid 2>&1 | tr -d '[:space:]')

  if [ -z "$UUID" ]; then
    echo "错误：UUID 生成失败"
    exit 1
  fi

  echo "UUID 生成成功"
}

generate_reality_keys() {
  echo ""
  echo "正在生成 Reality 密钥..."

  KEY_OUTPUT=$($XRAY_BIN x25519 2>&1 || true)

  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2; exit}')
  PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/ {print $2; exit}')

  PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "错误：Reality 密钥生成失败"
    echo ""
    echo "Xray 原始输出如下："
    echo "$KEY_OUTPUT"
    echo ""
    echo "解析结果："
    echo "PRIVATE_KEY=$PRIVATE_KEY"
    echo "PUBLIC_KEY=$PUBLIC_KEY"
    echo ""
    echo "请手动执行排查："
    echo "$XRAY_BIN x25519"
    exit 1
  fi

  echo "Reality 密钥生成成功"
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

show_qrcode() {
  QR_CONTENT="$1"

  if command -v qrencode >/dev/null 2>&1; then
    echo ""
    echo "请用手机代理软件扫码导入："
    echo ""

    echo -e "\033[32m"
    echo "$QR_CONTENT" | qrencode -t ANSIUTF8 -m 2
    echo -e "\033[0m"

    echo ""
    echo "如果二维码太大或显示不完整，请放大终端窗口后重新运行。"
  else
    echo "未安装 qrencode，无法显示二维码"
  fi
}

show_result() {
  get_ipinfo
  IP="$PUBLIC_IP"
  url_encode_node_name

  VLESS_URL="vless://$UUID@$IP:$VLESS_PORT?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=$SNI_DOMAIN&pbk=$PUBLIC_KEY&sid=$SHORT_ID&fp=$FINGERPRINT#$NODE_NAME_ENCODED"

  BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
  BBR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
  SYSTEM_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  SYSTEM_TIMEZONE=$(timedatectl 2>/dev/null | grep "Time zone" | awk -F': ' '{print $2}' || echo unknown)

  echo ""
  echo "======================================"
  echo " VLESS + Reality + Vision 安装完成"
  echo "======================================"
  echo "服务器 IP：$IP"
  echo "识别国家：$IP_COUNTRY"
  echo "识别地区：$IP_REGION"
  echo "识别城市：$IP_CITY"
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
  echo "BBR 拥塞控制：$BBR_CC"
  echo "BBR 队列算法：$BBR_QDISC"
  echo "系统时间：$SYSTEM_TIME"
  echo "系统时区：$SYSTEM_TIMEZONE"
  echo ""
  echo "VLESS 分享链接："
  echo "$VLESS_URL"
  echo ""
  echo "VLESS 绿色二维码："
  show_qrcode "$VLESS_URL"
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
  echo ""
  echo "重要提醒："
  echo "1. Reality + Vision + TCP 只需要放行 TCP 端口"
  echo "2. 如果客户端连不上，请检查 VPS 云后台安全组是否放行 TCP $VLESS_PORT"
  echo "3. 如果二维码不好扫，请放大终端窗口，或者复制 VLESS 分享链接导入"
  echo "4. 节点地区来自 ipinfo.io，仅供参考，最终以实际出口检测为准"
  echo "5. BBR 是网络优化，不是换线路；线路本身差，BBR 也救不了全部问题"
  echo "======================================"
}

install_reality() {
  check_system
  install_base_packages
  set_shanghai_time
  install_xray

  echo ""
  echo "请选择安装模式："
  echo "1) 自定义端口 / SNI / 指纹 / 节点名称"
  echo "2) 随机端口 / 默认 SNI / 自动节点名"
  echo ""

  read -p "请输入选项 [1/2]，默认 2: " MODE
  MODE=${MODE:-2}

  generate_node_name_by_ipinfo

  if [ "$MODE" = "1" ]; then
    read -p "请输入端口，必须 >=10000，例如 31566: " VLESS_PORT
    read -p "请输入 SNI 域名，默认 $DEFAULT_SNI: " SNI_DOMAIN
    read -p "请输入浏览器指纹，默认 $DEFAULT_FP: " FINGERPRINT
    read -p "请输入节点名称，默认 $AUTO_NODE_NAME: " NODE_NAME

    SNI_DOMAIN=${SNI_DOMAIN:-$DEFAULT_SNI}
    FINGERPRINT=${FINGERPRINT:-$DEFAULT_FP}
    NODE_NAME=${NODE_NAME:-$AUTO_NODE_NAME}
  else
    VLESS_PORT=$(random_port)
    SNI_DOMAIN="$DEFAULT_SNI"
    FINGERPRINT="$DEFAULT_FP"
    NODE_NAME="$AUTO_NODE_NAME"
  fi

  validate_port "$VLESS_PORT"

  generate_uuid
  generate_reality_keys

  SHORT_ID=$(random_short_id)

  write_xray_config
  test_xray_config
  open_firewall_port "$VLESS_PORT"
  enable_bbr
  start_xray
  show_result
}

show_status() {
  get_ipinfo

  echo "======================================"
  echo " Xray Reality 状态"
  echo "======================================"

  systemctl status "$SERVICE_NAME" --no-pager || true

  echo ""
  echo "IP 信息："
  echo "服务器 IP：$PUBLIC_IP"
  echo "识别国家：$IP_COUNTRY"
  echo "识别地区：$IP_REGION"
  echo "识别城市：$IP_CITY"

  echo ""
  echo "监听端口："
  ss -lntup | grep xray || true

  echo ""
  echo "BBR 状态："
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true

  echo ""
  echo "系统时间："
  date "+%Y-%m-%d %H:%M:%S"
  timedatectl 2>/dev/null | grep "Time zone" || true
  timedatectl 2>/dev/null | grep "System clock synchronized" || true
  timedatectl 2>/dev/null | grep "NTP service" || true

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
