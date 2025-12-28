#!/bin/bash

### ===== 基础变量 =====
CORE_FILE="/etc/proxy-core"
INFO_FILE="/root/proxy-info.txt"
SING_DIR="/etc/sing-box"
XRAY_DIR="/usr/local/etc/xray"
IP=$(curl -s ipinfo.io/ip)

### ===== 通用函数 =====
pause(){ read -rp "按回车继续..."; }

ask_yes_no(){
  read -rp "$1 (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

port_used(){
  ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

ask_port(){
  while true; do
    read -rp "请输入端口 (留空自动生成): " p
    if [ -z "$p" ]; then
      while true; do
        p=$(shuf -i 20000-60000 -n 1)
        port_used "$p" || break
      done
      echo "$p"; return
    fi
    if port_used "$p"; then
      echo "端口被占用"
    else
      echo "$p"; return
    fi
  done
}

ask_uuid(){
  read -rp "请输入 UUID (留空自动生成): " u
  [ -z "$u" ] && u=$(cat /proc/sys/kernel/random/uuid)
  echo "$u"
}

gen_reality_key(){
  private=$(openssl rand -base64 32)
  public=$(echo -n "$private" | sha256sum | awk '{print $1}')
  echo "$private|$public"
}

install_base(){
  apt update -y
  apt install -y curl wget unzip tar socat nano openssl
}

### ===== 内核安装 =====
install_singbox(){
  install_base
  ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4)
  wget -q https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-amd64.tar.gz
  tar -xzf sing-box-*.tar.gz
  mv sing-box-*/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
  mkdir -p $SING_DIR

cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c $SING_DIR/config.json
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  echo "sing-box" > $CORE_FILE
}

install_xray(){
  install_base
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  systemctl enable xray
  echo "xray" > $CORE_FILE
}

### ===== 协议安装 =====
install_vless(){
  port=$(ask_port)
  uuid=$(ask_uuid)

  CORE=$(cat $CORE_FILE)
  if [ "$CORE" = "sing-box" ]; then
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"vless","listen":"::","listen_port":$port,
  "users":[{"uuid":"$uuid"}]
 }],
 "outbounds":[{"type":"direct"}]
}
EOF
  else
cat >$XRAY_DIR/config.json <<EOF
{
 "inbounds":[{
  "port":$port,"protocol":"vless",
  "settings":{"clients":[{"id":"$uuid"}]}
 }],
 "outbounds":[{"protocol":"freedom"}]
}
EOF
  fi

cat >$INFO_FILE <<EOF
[VLESS]
vless://$uuid@$IP:$port?encryption=none#VLESS
EOF
}

install_reality(){
  port=$(ask_port)
  uuid=$(ask_uuid)

  read -rp "SNI 域名 (默认 www.cloudflare.com): " sni
  [ -z "$sni" ] && sni="www.cloudflare.com"

  keypair=$(gen_reality_key)
  private=${keypair%%|*}
  public=${keypair##*|}

  CORE=$(cat $CORE_FILE)
  if [ "$CORE" = "sing-box" ]; then
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"vless","listen":"::","listen_port":$port,
  "users":[{"uuid":"$uuid","flow":"xtls-rprx-vision"}],
  "tls":{"enabled":true,"reality":{
    "enabled":true,
    "handshake":{"server":"$sni","server_port":443},
    "private_key":"$private"
  }}
 }]
}
EOF
  else
cat >$XRAY_DIR/config.json <<EOF
{
 "inbounds":[{
  "port":$port,"protocol":"vless",
  "settings":{"clients":[{"id":"$uuid","flow":"xtls-rprx-vision"}]},
  "streamSettings":{"security":"reality","realitySettings":{
    "dest":"$sni:443","privateKey":"$private"
  }}
 }]
}
EOF
  fi

cat >$INFO_FILE <<EOF
[VLESS Reality]
vless://$uuid@$IP:$port?security=reality&sni=$sni&pbk=$public&fp=chrome#Reality
EOF
}

install_hysteria2(){
  port=$(ask_port)
  read -rp "密码 (留空自动生成): " pw
  [ -z "$pw" ] && pw=$(openssl rand -hex 8)

cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"hysteria2","listen":"::","listen_port":$port,
  "users":[{"password":"$pw"}]
 }]
}
EOF

cat >$INFO_FILE <<EOF
[Hysteria2]
hy2://$pw@$IP:$port
EOF
}

### ===== 菜单 =====
choose_core(){
  clear
  echo "1. sing-box"
  echo "2. xray"
  read -rp "选择内核: " c
  [ "$c" = "1" ] && install_singbox
  [ "$c" = "2" ] && install_xray
}

choose_proto(){
  CORE=$(cat $CORE_FILE)
  clear
  echo "1. VLESS"
  echo "2. VLESS Reality"
  [ "$CORE" = "sing-box" ] && echo "3. Hysteria2"
  read -rp "选择协议: " p
  case $p in
    1) install_vless ;;
    2) install_reality ;;
    3) [ "$CORE" = "sing-box" ] && install_hysteria2 ;;
  esac
}

### ===== 主循环 =====
while true; do
clear
echo "========== 内置代理面板 =========="
echo "1. 安装协议"
echo "2. 查看节点信息"
echo "3. 启动服务"
echo "4. 卸载"
echo "0. 退出"
read -rp "选择: " n

case $n in
  1) choose_core; choose_proto; systemctl restart $(cat $CORE_FILE); pause ;;
  2) cat $INFO_FILE; pause ;;
  3) systemctl restart $(cat $CORE_FILE); pause ;;
  4) systemctl stop sing-box xray; rm -rf $SING_DIR $XRAY_DIR $INFO_FILE; pause ;;
  0) exit ;;
esac
done
