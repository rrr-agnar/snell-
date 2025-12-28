#!/bin/bash

# ================= 基础变量 =================
CORE_FILE="/etc/proxy-core"
INFO_FILE="/root/proxy-info.txt"
SING_DIR="/etc/sing-box"
XRAY_DIR="/usr/local/etc/xray"
SSL_DIR="/etc/ssl"
IP=$(curl -s https://api64.ipify.org || curl -s ipinfo.io/ip)

# 颜色定义
green='\033[0;32m'
plain='\033[0m'

# ================= 通用工具函数 =================
pause(){ read -rp "按回车继续..." p; }

ask_port(){
  read -rp "请输入端口 (回车随机): " p
  if [ -z "$p" ]; then
    p=$(shuf -i 20000-60000 -n 1)
  fi
  echo "$p"
}

ask_uuid(){
  read -rp "请输入UUID (回车自动): " u
  [ -z "$u" ] && u=$(cat /proc/sys/kernel/random/uuid)
  echo "$u"
}

# ================= 核心安装逻辑 =================
install_base(){
  apt update -y && apt install -y curl wget unzip tar openssl
}

# 自动化生成 sing-box Reality 配置 (核心补充)
gen_singbox_reality_conf(){
  local port=$1; local uuid=$2; local priv=$3; local pub=$4; local sni=$5
  cat > $SING_DIR/config.json <<EOF
{
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": $port,
    "users": [{"uuid": "$uuid"}],
    "tls": {
      "enabled": true,
      "server_name": "$sni",
      "reality": {
        "enabled": true,
        "handshake": { "server": "$sni", "server_port": 443 },
        "private_key": "$priv",
        "short_id": ["$(openssl rand -hex 4)"]
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
}

# ================= 协议部署 =================
deploy_reality(){
  echo -e "${green}正在配置 Reality (推荐)...${plain}"
  local port=$(ask_port)
  local uuid=$(ask_uuid)
  read -rp "目标域名 (回车默认 www.microsoft.com): " sni
  [ -z "$sni" ] && sni="www.microsoft.com"
  
  # 生成密钥对
  local keys=$(sing-box generate reality-keypair)
  local priv=$(echo "$keys" | awk '/Private key:/ {print $3}')
  local pub=$(echo "$keys" | awk '/Public key:/ {print $3}')

  CORE=$(cat $CORE_FILE)
  if [ "$CORE" = "sing-box" ]; then
    gen_singbox_reality_conf "$port" "$uuid" "$priv" "$pub" "$sni"
  else
    # 这里可以添加 Xray 的 Reality 配置写入逻辑
    echo "Xray Reality 配置写入待补充..."
  fi

  cat >$INFO_FILE <<EOF
协议: Reality (VLESS)
地址: $IP
端口: $port
UUID: $uuid
SNI: $sni
PublicKey: $pub
链接: vless://$uuid@$IP:$port?security=reality&sni=$sni&pbk=$pub&fp=chrome&type=grpc#Reality_Node
EOF
}

# ================= 主菜单 =================
show_menu(){
  clear
  echo "====================================="
  echo "      Sing-box/Xray 远程一键面板"
  echo "====================================="
  echo "1. 安装 Sing-box 内核"
  echo "2. 安装 Xray 内核"
  echo "3. 部署 Reality 节点 (回车即刻生成)"
  echo "4. 查看当前节点信息"
  echo "5. 启动/重启服务"
  echo "0. 退出"
  echo "====================================="
}

while true; do
  show_menu
  read -rp "请选择: " opt
  case $opt in
    1)
      install_base
      # 简化的安装逻辑
      bash <(curl -Ls https://raw.githubusercontent.com/SagerNet/sing-box/main/install.sh)
      mkdir -p $SING_DIR
      echo "sing-box" > $CORE_FILE
      pause ;;
    2)
      install_base
      bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
      echo "xray" > $CORE_FILE
      pause ;;
    3)
      if [ ! -f $CORE_FILE ]; then echo "请先安装内核！"; pause; continue; fi
      deploy_reality
      echo -e "${green}部署完成！信息已保存在 $INFO_FILE${plain}"
      cat $INFO_FILE
      pause ;;
    4)
      [ -f $INFO_FILE ] && cat $INFO_FILE || echo "暂无节点信息"
      pause ;;
    5)
      CORE=$(cat $CORE_FILE)
      systemctl restart $CORE && echo "$CORE 已启动"
      pause ;;
    0) exit 0 ;;
  esac
done
