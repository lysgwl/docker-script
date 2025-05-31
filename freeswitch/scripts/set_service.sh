#!/bin/bash

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定义用户配置数组
declare -A user_config=(
	["uid"]="${PUID:-0}"
	["gid"]="${PGID:-0}"
	["user"]="${USERNAME:-root}"
	["group"]="${GROUPNAME:-root}"
)

# 定义 SSHD 配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)

readonly -A user_config
readonly -A sshd_config

# 安装服务
install_service_env()
{
	local arg=$1
	echo "[INFO] 安装系统服务"
	
	if [ "$arg" = "init" ]; then
		apt update
		
		# 构建工具
		echo "[INFO] === 安装构建工具 ==="
		
		# swig
		apt-get install -y --no-install-recommends autoconf automake bison build-essential cmake libspeex-dev libtool libtool-bin nasm pkg-config python3 python3-dev yasm || {
			echo "[ERROR] 构建工具安装失败,请检查!"
			return 1
		}
		
		# 音频处理
		echo "[INFO] === 安装音频处理库 ==="
		
		# libcodec2-dev libfftw3-dev libgsm1-dev (libavresample-dev)
		apt-get install -y --no-install-recommends libflac-dev libmp3lame-dev libmpg123-dev libogg-dev libogg-dev libopus-dev libsndfile1-dev libspeex-dev libspeexdsp-dev libswresample-dev libvorbis-dev || {
			echo "[ERROR] 音频处理库安装失败,请检查!"
			return 1
		}
		
		# 视频处理
		echo "[INFO] === 安装视频处理库 ==="
		# libavcodec-dev libavutil-dev libx264-dev libvpx-dev libyuv-dev
		apt-get install -y --no-install-recommends libavformat-dev libswscale-dev || {
			echo "[ERROR] 视频处理库安装失败,请检查!"
			return 1
		}
		
		# 图片处理
		echo "[INFO] === 安装图片处理库 ==="
		# libtiff5-dev
		apt-get install -y --no-install-recommends libjpeg-dev libtiff-dev || {
			echo "[ERROR] 图片处理库安装失败,请检查!"
			return 1
		}
		
		# 数据库支持
		echo "[INFO] === 安装数据库支持库 ==="
		
		# libpq-dev odbc-postgresql odbc-mysql libmysqlclient-dev
		apt-get install -y --no-install-recommends libdb-dev libgdbm-dev libpq-dev libsqlite3-dev unixodbc-dev || {
			echo "[ERROR] 数据库支持库安装失败,请检查!"
			return 1
		}
		
		# 网络协议支持
		echo "[INFO] === 安装网络协议库 ==="
		
		#  libsctp-dev libpcap-dev librabbitmq-dev libsrtp2-dev
		apt-get install -y --no-install-recommends libcurl4-openssl-dev libldns-dev libshout3-dev || {
			echo "[ERROR] 网络协议库安装失败,请检查!"
			return 1
		}
		
		# 系统库
		echo "[INFO] === 安装系统基础库 ==="
		
		# libspandsp-dev (libtpl-dev)
		apt-get install -y --no-install-recommends erlang-dev libedit-dev libexpat1-dev liblua5.4-dev libncurses5-dev libpcre3-dev libssl-dev libxml2-dev lsb-release uuid-dev zlib1g-dev || {
			echo "[ERROR] 系统基础库安装失败,请检查!"
			return 1
		}
	fi

	echo "[INFO] 安装服务完成!"
	return 0
}

# 设置系统用户
set_service_user()
{
	echo "[INFO] 设置系统用户"
	
	# 创建用户目录
	#echo "[DEBUG] 正在创建用户目录"
	mkdir -p "${system_config[downloads_dir]}" \
			 "${system_config[install_dir]}" \
			 "${system_config[config_dir]}" \
			 "${system_config[data_dir]}"
	
			 
	# 设置目录拥有者
	#echo "[DEBUG] 正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} \
			"${system_config[config_dir]}" \
			"${system_config[data_dir]}"
}

# 设置服务
set_service_env()
{
	local arg=$1
	echo "[INFO] 设置系统服务"
	
	# 设置系统用户
	set_service_user
	
	if [ "$arg" = "config" ]; then
		# 设置SSH服务
		local params=("${sshd_config[port]}" "${sshd_config[listen]}" "${sshd_config[confile]}" "${sshd_config[hostkey]}")
		if ! set_ssh_service "${params[@]}"; then
			return 1
		fi
		
		# 设置root用户密码
		echo "root:${ROOT_PASSWORD}" | chpasswd	
		
		# perl模块
		# export PERL5LIB=/usr/local/perl/lib/perl5
		echo "export PERL5LIB=/usr/local/perl/lib/perl5" >> ~/.bashrc
		
		#
		export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}
		echo "export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}" >> /etc/profile
		ldconfig
	fi

	echo "[INFO] 设置服务完成!"
	return 0
}

# 初始化服务
init_service()
{
	local arg=$1
	echo "[INFO] 初始化系统服务"
	
	# 安装服务
	if ! install_service_env "${arg}"; then
		return 1
	fi
	
	# 设置服务
	if ! set_service_env "${arg}"; then
		return 1
	fi
	
	echo "[INFO] 初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	echo "[INFO] 运行系统服务"
	
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd >/dev/null 2>&1; then
		echo "[INFO] 正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${sshd_config[logfile]}"

		# nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${sshd_config[logfile]}"
	fi
	
	echo "[INFO] 启动系统服务成功!"
}

# 停止服务
close_service()
{
	echo "[INFO] 关闭系统服务"
	
	if pgrep -x "sshd" > /dev/null; then
		echo "[INFO] sshd服务即将关闭中..."
		killall -q "sshd"
	fi
	
	echo "[INFO] 关闭系统服务成功!"
}