#!/bin/bash

# root用户密码
readonly ROOT_PASSWORD="123456"

# 定义用户配置数组
declare -A user_config=(
	["user"]="${APP_USER:-appuser}"
    ["group"]="${APP_GROUP:-appgroup}"
    ["uid"]="${APP_UID:-1000}"
    ["gid"]="${APP_GID:-1000}"
)

# 定义SSHD配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-8022}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
)

readonly -A user_config
readonly -A sshd_config

# 安装服务
install_service_env()
{
	local arg=$1
	echo "[INFO] 安装系统服务..."
	
	case "$arg" in
		"init")
			# 编译选项
			apk add --no-cache build-base linux-headers pcre-dev zlib-dev openssl-dev libaio-dev
			;;
		"config")
			# ssh服务
			apk add --no-cache openssh openssh-server-pam shadow
			
			# 其他工具
			apk add --no-cache netcat-openbsd
			;;
	esac
	
	echo "[INFO] 安装服务完成!"
}

# 设置系统用户
set_service_user()
{
	echo "[INFO] 设置系统用户..."
	
	# 增加系统用户
	local params=("${user_config[user]}" "${user_config[group]}" "${user_config[uid]}" "${user_config[gid]}")
	if ! add_service_user "${params[@]}"; then
		return 1
	fi
	
	# 创建用户目录
	echo "[DEBUG] 正在创建用户目录"
	mkdir -p "${system_config[config_dir]}" "${system_config[data_dir]}" "${system_config[usr_dir]}"
	
	# 设置目录拥有者
	echo "[DEBUG] 正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} "${system_config[config_dir]}" "${system_config[data_dir]}" "${system_config[usr_dir]}"

	# 设置目录权限
	echo "[DEBUG] 正在设置目录权限"
	chmod -R 755 "${system_config[config_dir]}" "${system_config[data_dir]}" "${system_config[usr_dir]}"
	
	return 0
}

# 设置服务
set_service_env()
{
	local arg=$1
	echo "[INFO] 设置系统服务..."
	
	if [ "$arg" = "init" ]; then
		# 下载目录
		mkdir -p "${system_config[downloads_dir]}"
	
		# 安装目录
		mkdir -p "${system_config[install_dir]}"
		
	elif [ "$arg" = "config" ]; then
		# 设置SSH服务
		local params=("${sshd_config[port]}" "${sshd_config[listen]}" "${sshd_config[confile]}" "${sshd_config[hostkey]}")
		if ! set_ssh_service "${params[@]}"; then
			return 1
		fi
		
		# 设置root用户密码
		echo "root:${ROOT_PASSWORD}" | chpasswd
		
		# 设置系统用户
		if ! set_service_user; then
			return 1
		fi
	fi

	echo "[INFO] 设置服务完成!"
	return 0
}

# 初始化服务
init_service_env()
{
	local arg=$1
	echo "【初始化系统服务】"
	
	# 安装服务
	install_service_env "${arg}"
	
	# 设置服务
	if ! set_service_env "${arg}"; then
		return 1
	fi
	
	# nginx服务
	if ! init_nginx_env "${arg}"; then
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
		# exec /usr/sbin/sshd -D
		nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
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