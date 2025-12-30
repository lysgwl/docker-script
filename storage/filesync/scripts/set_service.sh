#!/bin/bash

# 设置系统用户
set_service_user()
{
	print_log "TRACE" "设置系统用户"
	
	# 创建用户目录
	print_log "DEBUG" "正在创建用户目录"
	mkdir -p "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[install_dir]}" \
			 "${SYSTEM_CONFIG[update_dir]}" \
			 "${SYSTEM_CONFIG[config_dir]}" \
			 "${SYSTEM_CONFIG[data_dir]}" \
			 "${SYSTEM_CONFIG[usr_dir]}"
	
	# 设置目录拥有者
	print_log "DEBUG" "正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} \
			 "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[update_dir]}" \
			"${SYSTEM_CONFIG[config_dir]}" \
			"${SYSTEM_CONFIG[data_dir]}"
			
	chown "${user_config[user]}:${user_config[group]}" \
			"${SYSTEM_CONFIG[usr_dir]}"
			
	print_log "TRACE" "设置用户完成!"
}

# 设置系统配置
set_service_conf()
{
	print_log "TRACE" "设置系统配置文件"
	
	local target_dir="${SYSTEM_CONFIG[conf_dir]}"
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
	
		# nginx 配置
		local dest_dir="${SYSTEM_CONFIG[config_dir]}/nginx/extra/proxy-config"
		if [[ -d "$dest_dir" ]]; then
			if ! rsync -av --remove-source-files --include='*.conf' --exclude='*' "$target_dir"/ "$dest_dir"/ >/dev/null; then
				print_log "ERROR" "nginx 配置文件设置失败, 请检查!" >&2
				return 1
			fi
			
			# nginx server配置
			local target_file="${SYSTEM_CONFIG[config_dir]}/nginx/extra/www.conf"
			
			if [[ -f "$target_file" ]]; then
				local reference_content=$(cat <<'EOF'
root   html;
index  index.html index.htm player.html;
EOF
				)

				local new_content=$(cat <<'EOF'
proxy_pass http://filesync:8080;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
EOF
				)

				modify_nginx_location "$target_file" "/" "$reference_content" "$new_content" true
			fi
		fi
	fi

	return 0
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
			return 1
		fi
COMMENT_BLOCK

		# 设置 root 用户密码
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