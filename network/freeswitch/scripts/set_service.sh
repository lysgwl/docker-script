#!/bin/bash

# 安装服务
install_service_env()
{
	print_log "TRACE" "安装系统服务"
	local arg=$1
	
	if [ "$arg" = "init" ]; then
		apt update
		
		# 构建工具
		print_log "SECTION" "安装构建工具"
		
		# swig
		apt-get install -y --no-install-recommends autoconf automake bison build-essential cmake libspeex-dev libtool libtool-bin nasm pkg-config python3 python3-dev yasm || {
			print_log "ERROR" "构建工具安装失败, 请检查!"
			return 1
		}
		
		# 音频处理
		print_log "SECTION" "安装音频处理库"
		
		# libcodec2-dev libfftw3-dev libgsm1-dev (libavresample-dev)
		apt-get install -y --no-install-recommends libflac-dev libmp3lame-dev libmpg123-dev libogg-dev libogg-dev libopus-dev libsndfile1-dev libspeex-dev libspeexdsp-dev libswresample-dev libvorbis-dev || {
			print_log "ERROR" "音频处理库安装失败, 请检查!"
			return 1
		}
		
		# 视频处理
		print_log "SECTION" "安装视频处理库"
		
		# libavcodec-dev libavutil-dev libx264-dev libvpx-dev libyuv-dev
		apt-get install -y --no-install-recommends libavformat-dev libswscale-dev || {
			print_log "ERROR" "视频处理库安装失败, 请检查!"
			return 1
		}
		
		# 图片处理
		print_log "SECTION" "安装图片处理库"
		
		# libtiff5-dev
		apt-get install -y --no-install-recommends libjpeg-dev libtiff-dev || {
			print_log "ERROR" "图片处理库安装失败, 请检查!"
			return 1
		}
		
		# 数据库支持
		print_log "SECTION" "安装数据库支持库"
		
		# libpq-dev odbc-postgresql odbc-mysql libmysqlclient-dev
		apt-get install -y --no-install-recommends libdb-dev libgdbm-dev libpq-dev libsqlite3-dev unixodbc-dev || {
			print_log "ERROR" "数据库支持库安装失败, 请检查!"
			return 1
		}
		
		# 网络协议支持
		print_log "SECTION" "安装网络协议库"
		
		#  libsctp-dev libpcap-dev librabbitmq-dev libsrtp2-dev
		apt-get install -y --no-install-recommends libcurl4-openssl-dev libldns-dev libshout3-dev || {
			print_log "ERROR" "网络协议库安装失败, 请检查!"
			return 1
		}
		
		# 系统库
		print_log "SECTION" "安装系统基础库 "
		
		# libspandsp-dev (libtpl-dev)
		apt-get install -y --no-install-recommends erlang-dev libedit-dev libexpat1-dev liblua5.4-dev libncurses5-dev libpcre3-dev libssl-dev libxml2-dev lsb-release uuid-dev zlib1g-dev || {
			print_log "ERROR" "系统基础库安装失败, 请检查!"
			return 1
		}
	fi
	
	print_log "TRACE" "安装服务完成!"
	return 0
}

# 设置系统用户
set_service_user()
{
	print_log "TRACE" "设置系统用户"
	
	# 创建用户目录
	print_log "DEBUG" "正在创建用户目录"
	mkdir -p "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[install_dir]}" \
			 "${SYSTEM_CONFIG[config_dir]}" \
			 "${SYSTEM_CONFIG[data_dir]}"
	
	# 设置目录拥有者
	print_log "DEBUG" "正在设置目录拥有者(${USER_CONFIG[user]}:${USER_CONFIG[group]})"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
			"${SYSTEM_CONFIG[config_dir]}" \
			"${SYSTEM_CONFIG[data_dir]}"
	
	print_log "TRACE" "设置用户完成!"
}

# 设置服务
set_service_env()
{
	print_log "TRACE" "设置系统服务"
	local arg=$1
	
	# 设置系统用户
	set_service_user
	
	if [ "$arg" = "config" ]; then
		# 设置SSH服务
		local params=("${SSHD_CONFIG[port]}" "${SSHD_CONFIG[listen]}" "${SSHD_CONFIG[confile]}" "${SSHD_CONFIG[hostkey]}")
		
		if ! set_ssh_service "${params[@]}"; then
			print_log "ERROR" "设置 SSHD 服务失败, 请检查!"
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
	
	print_log "TRACE" "设置服务完成!"
	return 0
}

# 初始化服务
init_service()
{
	print_log "TRACE" "初始化系统服务"
	local arg=$1
	
	# 安装服务
	if ! install_service_env "${arg}"; then
		return 1
	fi
	
	# 设置服务
	if ! set_service_env "${arg}"; then
		return 1
	fi
	
	print_log "TRACE" "初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	print_log "TRACE" "运行系统服务"
	
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd >/dev/null 2>&1; then
		print_log "INFO" "正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${SSHD_CONFIG[logfile]}"

		# nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${SSHD_CONFIG[logfile]}"
	fi
	
	print_log "TRACE" "启动系统服务成功!"
}

# 停止服务
close_service()
{
	print_log "TRACE" "关闭系统服务"
	
	if pgrep -x "sshd" > /dev/null; then
		print_log "INFO" "sshd服务即将关闭中..."
		killall -q "sshd"
	fi
	
	print_log "TRACE" "关闭系统服务成功!"
}