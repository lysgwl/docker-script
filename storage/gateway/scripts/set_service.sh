#!/bin/bash

# 设置配置文件
set_service_conf()
{
	print_log "INFO" "设置挂载配置文件"
	
	local target_dir="${system_config[conf_dir]}"
	local dest_dir="${system_config[config_dir]}"
	
	print_log "INFO" "源目录: $target_dir"
	print_log "INFO" "目标目录: $dest_dir"
	
	# 检查源目录是否存在且有内容
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		# 同步配置文件
		if [[ -d "$dest_dir" ]]; then
			if ! rsync -av --remove-source-files --include='*.json' --exclude='*' "$target_dir"/ "$dest_dir"/ >/dev/null; then
				print_log "ERROR" "挂载配置文件设置失败, 请检查!"
				return 1
			fi
		fi
	fi
	
	print_log "INFO" "配置文件同步完成"
	return 0
}

# 设置服务
set_service_env()
{
	local arg=$1
	print_log "INFO" "设置系统服务"
	
	# 设置配置文件
	if ! set_service_conf; then
		return 1
	fi
	
	print_log "INFO" "服务环境配置完成"
	return 0
}

# 初始化服务
init_service()
{
	print_log "INFO" "初始化系统服务"
	
	# 设置服务
	if ! set_service_env; then
		return 1
	fi
	
	print_log "INFO" "初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	echo "[INFO] 运行系统服务"
	
	echo "[INFO] 启动系统服务成功!"
}

# 停止服务
close_service()
{
	echo "[INFO] 关闭系统服务"
	
	echo "[INFO] 关闭系统服务成功!"
}