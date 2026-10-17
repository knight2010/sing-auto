#!/bin/sh
set -e

# 1. 启动底层代理内核（如 sing-box，监听本地回环端口，假设端口为 8080）
PORT=${PORT:-8080}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

# 启动 sing-box 放在后台运行
sing-box run -c /etc/sing-box/config.json > /dev/null 2>&1 &

echo "========================================="
echo "sing-box 已在后台启动，监听端口: ${PORT}"

# 2. 判断是否传入了 ARGO_TOKEN
if [ -n "${ARGO_TOKEN}" ]; then
    echo "检测到 ARGO_TOKEN，正在使用固定 Named Tunnel 启动..."
    exec cloudflared tunnel run --token "${ARGO_TOKEN}"
else
    echo "未提供 ARGO_TOKEN，正在创建 Cloudflare 临时隧道 (Quick Tunnel)..."
    
    # 创建临时日志文件用于提取 trycloudflare 域名
    ARGO_LOG="/tmp/cloudflared.log"
    touch "${ARGO_LOG}"

    # 后台拉起临时隧道，将外部流量转发至容器本地的 8080 端口
    cloudflared tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate > "${ARGO_LOG}" 2>&1 &

    # 循环读取日志等待官方分配 trycloudflare 域名（最多等待 30 秒）
    echo "等待分配临时公网域名..."
    TUNNEL_DOMAIN=""
    for i in $(seq 1 30); do
        sleep 1
        TUNNEL_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "${ARGO_LOG}" | head -n 1)
        if [ -n "${TUNNEL_DOMAIN}" ]; then
            break
        fi
    done

    if [ -z "${TUNNEL_DOMAIN}" ]; then
        echo "[错误] 获取 Cloudflare 临时域名失败，请检查网络或输出日志："
        cat "${ARGO_LOG}"
        exit 1
    fi

    # 截取纯域名字符串（去掉前缀 https://）
    CLEAN_DOMAIN=$(echo "${TUNNEL_DOMAIN}" | sed 's#https://##')

    echo "-----------------------------------------"
    echo "临时隧道创建成功！"
    echo "公网域名: ${CLEAN_DOMAIN}"
    echo "节点配置信息:"
    echo "vless://${UUID}@${CLEAN_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CLEAN_DOMAIN}&path=%2F#Cloudflare-QuickTunnel"
    echo "-----------------------------------------"

    # 保持主进程前台运行，并将 cloudflared 日志持续输出到终端
    tail -f "${ARGO_LOG}"
fi
