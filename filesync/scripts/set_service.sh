#!/bin/bash

# root用户密码
readonly ROOT_PASSWORD="123456"

# 定义用户配置数组
declare -A user_config=(
	["user"]="${APP_USER:-root}"
	["group"]="${APP_GROUP:-root}"
	["uid"]="${APP_UID:-0}"
	["gid"]="${APP_GID:-0}"
)

# 定义SSHD配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)

readonly -A user_config
readonly -A sshd_config

# 设置系统用户
set_service_user()
{
	echo "[INFO] 设置系统用户..."
	
	# 创建用户目录
	#echo "[DEBUG] 正在创建用户目录"
	mkdir -p "${system_config[downloads_dir]}" \
			 "${system_config[install_dir]}" \
			 "${system_config[config_dir]}" \
			 "${system_config[data_dir]}" \
			 "${system_config[usr_dir]}"
	
	# 设置目录拥有者
	#echo "[DEBUG] 正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} \
			"${system_config[config_dir]}" \
			"${system_config[data_dir]}" \
			"${system_config[usr_dir]}"

	# 设置目录权限
	#echo "[DEBUG] 正在设置目录权限"
	chmod -R 755 "${system_config[config_dir]}" \
				 "${system_config[data_dir]}" \
				 "${system_config[usr_dir]}"
}

# 设置服务
set_service_env()
{
	local arg=$1
	echo "[INFO] 设置系统服务..."
	
	# 设置系统用户
	set_service_user
	
	if [ "$arg" = "config" ]; then
		# 设置SSH服务
		local params=("${sshd_config[port]}" "${sshd_config[listen]}" "${sshd_config[confile]}" "${sshd_config[hostkey]}")
		if ! set_ssh_service "${params[@]}"; then
			return 1
		fi
		
		# 设置root用户密码
		echo "root:$ROOT_PASSWORD" | chpasswd
	fi

	echo "[INFO] 设置服务完成!"
	return 0
}

# 初始化服务
init_service_env()
{
	local arg=$1
	echo "【初始化系统服务】"
	
	# 设置服务
	if ! set_service_env "$arg"; then
		return 1
	fi
	
	# nginx服务
	if ! init_nginx_env "$arg"; then
		return 1
	fi

	echo "[INFO] 初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	echo "【运行系统服务】"
	
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd > /dev/null; then
		echo "[INFO] 正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		chmod 0755 /run/sshd 2>/dev/null
		
		touch "${sshd_config[logfile]}"
		chmod 0600 "${sshd_config[logfile]}"
		
		#nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${sshd_config[logfile]}"
	fi
	
	# 启动 nginx 服务
	run_nginx_service
	
	echo "[INFO] 启动系统服务成功!"
}

# 停止服务
close_service()
{
	echo "【关闭系统服务】"
	
	if pgrep -x "sshd" > /dev/null; then
		echo "[INFO] sshd服务即将关闭中..."
		killall -q "sshd"
	fi
	
	# 关闭 nginx 服务
	close_nginx_service
	
	echo "[INFO] 关闭系统服务成功!"
}