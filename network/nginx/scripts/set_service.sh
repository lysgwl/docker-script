#!/bin/bash

# 设置系统用户
set_service_user()
{
	print_log "TRACE" "设置系统用户"
	
	# 创建用户目录
	print_log "DEBUG" "正在创建用户目录"
	mkdir -p "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[install_dir]}" \
			 "${SYSTEM_CONFIG[config_dir]}" \
			 "${SYSTEM_CONFIG[data_dir]}" \
			 "${SYSTEM_CONFIG[usr_dir]}"
			 
	# 设置目录拥有者
	print_log "DEBUG" "正在设置目录拥有者(${USER_CONFIG[user]}:${USER_CONFIG[group]})"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
			"${SYSTEM_CONFIG[config_dir]}" \
			"${SYSTEM_CONFIG[data_dir]}"
			
	chown "${USER_CONFIG[user]}:${USER_CONFIG[group]}" \
			"${SYSTEM_CONFIG[usr_dir]}"
			
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
: <<'COMMENT_BLOCK'	
		# 设置SSH服务
		local params=("${SSHD_CONFIG[port]}" "${SSHD_CONFIG[listen]}" "${SSHD_CONFIG[confile]}" "${SSHD_CONFIG[hostkey]}")
		
		if ! set_ssh_service "${params[@]}"; then
			print_log "ERROR" "设置 SSHD 服务失败, 请检查!"
			return 1
		fi
COMMENT_BLOCK
		
		# 设置root用户密码
		echo "root:$ROOT_PASSWORD" | chpasswd
	fi

	print_log "TRACE" "设置服务完成!"
	return 0
}

# 初始化服务
init_service()
{
	print_log "TRACE" "初始化系统服务"
	local arg=$1
	
	# 设置服务
	if ! set_service_env "$arg"; then
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
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd > /dev/null; then
		print_log "INFO" "正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${SSHD_CONFIG[logfile]}"

		#nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
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