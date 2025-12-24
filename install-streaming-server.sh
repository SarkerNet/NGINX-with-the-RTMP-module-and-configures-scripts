#!/bin/bash

# =========================================================
# Sarker Net - Ultimate Live Streaming Server Installer
# Features: Nginx, RTMP, HLS, DASH, FFMPEG Transcoding (ABS)
# =========================================================

# 1. Check for Root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Configuration Variables
NGINX_VER="1.24.0"
INSTALL_PATH="/usr/local/nginx"
WEB_ROOT="/var/www/html/stream"
HLS_PATH="${WEB_ROOT}/hls"
DASH_PATH="${WEB_ROOT}/dash"

echo "=== 1. Updating System & Installing Dependencies ==="
apt-get update -y
apt-get install -y build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev unzip git wget ffmpeg

echo "=== 2. Downloading Nginx & RTMP Module ==="
cd /tmp
# Download Nginx
if [ ! -d "nginx-${NGINX_VER}" ]; then
    wget https://nginx.org/download/nginx-${NGINX_VER}.tar.gz
    tar -zxvf nginx-${NGINX_VER}.tar.gz
fi

# Download RTMP Module
if [ ! -d "nginx-rtmp-module" ]; then
    git clone https://github.com/arut/nginx-rtmp-module.git
fi

echo "=== 3. Compiling Nginx ==="
cd nginx-${NGINX_VER}
./configure \
    --prefix=${INSTALL_PATH} \
    --with-http_ssl_module \
    --with-http_v2_module \
    --add-module=../nginx-rtmp-module \
    --with-cc-opt="-Wno-error" 

make
make install

echo "=== 4. Setting up Directories ==="
mkdir -p ${HLS_PATH}
mkdir -p ${DASH_PATH}
chmod -R 777 ${WEB_ROOT}

echo "=== 5. Creating Nginx Configuration (ABS/DASH/HLS) ==="
# Backup default config
mv ${INSTALL_PATH}/conf/nginx.conf ${INSTALL_PATH}/conf/nginx.conf.bak

cat > ${INSTALL_PATH}/conf/nginx.conf <<EOF
worker_processes  auto;

events {
    worker_connections  1024;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        # 1. INGEST APPLICATION (Send your stream here)
        # URL: rtmp://server-ip/src/streamkey
        application src {
            live on;
            
            # FFMPEG Transcoding for Adaptive Bitrate (ABS)
            # This takes the input and creates 3 variants: High, Mid, Low
            exec ffmpeg -i rtmp://localhost/src/\$name
              -c:a aac -b:a 128k -c:v libx264 -b:v 2500k -f flv -g 30 -r 30 -s 1920x1080 -preset superfast -tune zerolatency rtmp://localhost/show/\$name_hi
              -c:a aac -b:a 128k -c:v libx264 -b:v 1200k -f flv -g 30 -r 30 -s 1280x720 -preset superfast -tune zerolatency rtmp://localhost/show/\$name_mid
              -c:a aac -b:a 64k  -c:v libx264 -b:v 600k  -f flv -g 30 -r 30 -s 854x480  -preset superfast -tune zerolatency rtmp://localhost/show/\$name_low;
        }

        # 2. OUTPUT APPLICATION (Internal use for packaging)
        application show {
            live on;

            # HLS Settings
            hls on;
            hls_path ${HLS_PATH};
            hls_fragment 4;
            hls_playlist_length 60;
            
            # HLS Variant (Master Playlist for Adaptive Streaming)
            hls_variant _hi  BANDWIDTH=2628000,RESOLUTION=1920x1080; # 2500k video + 128k audio
            hls_variant _mid BANDWIDTH=1328000,RESOLUTION=1280x720;  # 1200k video + 128k audio
            hls_variant _low BANDWIDTH=664000,RESOLUTION=854x480;    # 600k video + 64k audio

            # DASH Settings
            dash on;
            dash_path ${DASH_PATH};
            dash_fragment 4;
            dash_playlist_length 60;
        }
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       80;
        server_name  localhost;

        # HLS Playback
        location /hls {
            # CORS setup
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length';

            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias ${HLS_PATH};
        }

        # DASH Playback
        location /dash {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length';

            types {
                application/dash+xml mpd;
                video/mp4 mp4;
            }
            alias ${DASH_PATH};
        }

        # Stat Page (Optional)
        location /stat {
            rtmp_stat all;
            rtmp_stat_stylesheet stat.xsl;
        }
        location /stat.xsl {
            root /tmp/nginx-rtmp-module;
        }

        location / {
             root html;
             index index.html index.htm;
        }
    }
}
EOF

echo "=== 6. Installing Systemd Service ==="
cat > /lib/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and RTMP Server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${INSTALL_PATH}/logs/nginx.pid
ExecStartPre=${INSTALL_PATH}/sbin/nginx -t
ExecStart=${INSTALL_PATH}/sbin/nginx
ExecReload=${INSTALL_PATH}/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Reload Daemon and Start
systemctl daemon-reload
systemctl enable nginx
systemctl start nginx

# Get IP Address
IP_ADDR=$(hostname -I | cut -d' ' -f1)

echo ""
echo "=========================================================="
echo "   INSTALLATION COMPLETE - Sarker Net Streaming Server    "
echo "=========================================================="
echo ""
echo "1. Stream Input (OBS/Encoder):"
echo "   RTMP URL: rtmp://$IP_ADDR/src"
echo "   Stream Key: mystream"
echo ""
echo "2. Playback URLs (Adaptive Bitrate):"
echo "   HLS Master: http://$IP_ADDR/hls/mystream.m3u8"
echo "   DASH Manifest: http://$IP_ADDR/dash/mystream.mpd"
echo ""
echo "   * Note: The master playlist automatically handles switching"
echo "     between 1080p, 720p, and 480p based on internet speed."
echo "=========================================================="
