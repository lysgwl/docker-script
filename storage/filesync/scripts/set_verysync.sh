#!/bin/bash

# 下载 verysync 安装包
download_verysync()
{
	logger "INFO" "[verysync] 下载服务安装包" >&2
	
	local downloads_dir=$1
	local name="verysync"
	
	local url="https://www.verysync.com/download.php?platform=linux-amd64"
	local json_config=$(jq -n \
		--arg type "static" \
		--arg name "$name" \
		--arg url "$url" \
		'{
			type: $type,
			name: $name,
			url: $url
		}')
		
	# 调用下载函数
	local latest_file
	if ! latest_file=$(download_package "$json_config" "$downloads_dir"); then
		logger "ERROR" "[verysync] 下载服务文件失败" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 verysync 环境
install_verysync_env()
{
	logger "INFO" "[verysync] 安装服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/verysync"
	if [[ "$arg" = "init" ]]; then
		if [[ ! -d "$target_path" ]]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "verysync" "$downloads_dir" download_verysync "*.sig") || {
				logger "ERROR" "[verysync] 获取服务安装包失败"
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				logger "ERROR" "[verysync] 安装服务失败"
				return 2
			}
					
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [[ "$arg" = "config" ]]; then
		if [[ ! -d "${verysync_cfg[sys_path]}" || ! -e "${verysync_cfg[bin_file]}" ]]; then
			local install_dir=$(dirname "${verysync_cfg[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				logger "ERROR" "[verysync] 安装服务失败"
				return 2
			}
			
			# 创建符号链接
			install_binary "${verysync_cfg[bin_file]}" "" "${verysync_cfg[symlink_file]}" || {
				logger "ERROR" "[verysync] 创建服务符号链接失败"
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	logger "INFO" "[verysync] 服务安装完成"
}

# 设置 verysync 用户
set_verysync_user()
{
	logger "INFO" "[verysync] 设置服务用户权限"
	
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	# 获取配置路径
	local sys_path="${verysync_cfg[sys_path]}"
	local etc_path="${verysync_cfg[etc_path]}"
	local data_path="${verysync_cfg[data_path]}"
	
	# 设置目录权限
	for dir in "$sys_path" "$etc_path" "$data_path"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[syncthing] 目录 $dir 变量为空"
			return 1
		fi
		
		chown -R "$user:$group" "$dir" 2>/dev/null || {
			logger "ERROR" "[syncthing] 设置目录权限失败: $dir"
			return 2
		}
	done
	
	# 获取PID文件
	local pid_file=$(get_service_pid_file "verysync")
	if [[ -n "$pid_file" ]]; then
		chown "$user:$group" "$pid_file" 2>/dev/null || true
		chmod 666 "$pid_file" 2>/dev/null || true
	fi
	
	logger "INFO" "[verysync] 服务权限完成"
}

# 设置 verysync 配置文件
set_verysync_conf()
{
	logger "INFO" "[verysync] 设置服务配置文件"
	
	local etc_path="${verysync_cfg[etc_path]}"
	local data_path="${verysync_cfg[data_path]}"
	local bin_file="${verysync_cfg[bin_file]}"
	local passwd="${verysync_cfg[passwd]}"
	
	# 检查可执行文件
	if [[ ! -f "$bin_file" ]]; then
		logger "ERROR" "[verysync] 可执行文件不存在: $bin_file"
		return 1
	fi
	
	# 生成配置
	local gen_cmd=(
			"$bin_file" generate
			"--config=$etc_path"
			"--gui-user=admin"
			"--gui-password=$passwd"
		)
		
	if ! "${gen_cmd[@]}"; then
			logger "ERROR" "[verysync] 配置文件生成失败"
			return 2
	fi
	
	logger "INFO" "[verysync] 服务配置完成"
}

# 设置 verysync 路径
set_verysync_paths()
{
	logger "INFO" "[verysync] 设置服务环境目录"
	
	# 获取配置路径
	local sys_path="${verysync_cfg[sys_path]}"
	local etc_path="${verysync_cfg[etc_path]}"
	local data_path="${verysync_cfg[data_path]}"
	
	# 获取PID文件
	local pid_file=$(get_service_pid_file "verysync")
	
	# 创建目录
	for dir in "$sys_path" "$etc_path" "$data_path"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[verysync] 目录 $dir 变量为空"
			return 1
		fi
		
		if ! mkdir -p "$dir"; then
			logger "ERROR" "[verysync] 目录创建失败: $dir"
			return 2
		fi
	done
	
	# 创建文件
	for file in "$pid_file"; do
		if [[ -z "$file" ]]; then
			logger "ERROR" "[verysync] 文件 $file 路径为空"
			return 1
		fi
		
		local parent=$(dirname "$file")
		if ! mkdir -p "$parent"; then
			logger "ERROR" "[verysync] 父目录创建失败: $parent"
			return 1
		fi
		
		if ! touch "$file"; then
			logger "ERROR" "[verysync] 文件创建失败: $file"
			return 3
		fi
	done
	
	logger "INFO" "[verysync] 设置目录完成"
}

# 设置 verysync 环境
set_verysync_env()
{
	logger "INFO" "[verysync] 设置服务环境"
	
	if [[ "$1" = "config" ]]; then
		# 创建环境目录
		if ! set_verysync_paths; then
			logger "ERROR" "[verysync] 设置环境路径失败"
			return 1
		fi
		
		# 设置 verysync 配置文件
		if ! set_verysync_conf; then
			logger "ERROR" "[verysync] 设置服务配置文件失败"
			return 2
		fi
		
		# 设置 verysync 用户
		if ! set_verysync_user; then
			logger "ERROR" "[verysync] 设置服务用户权限失败"
			return 3
		fi
	fi
	
	logger "INFO" "[verysync] 设置服务完成"
}

# 设置 verysync 模板
set_verysync_template()
{
	# 获取配置路径
	local data_dir="${SYSTEM_CONFIG[data_dir]}/verysync"
	local etc_dir="${SYSTEM_CONFIG[config_dir]}/verysync"
	local sys_dir="/usr/local/verysync"
	local bin_file="${sys_dir}/verysync"
	local symlink_file="/usr/local/bin/verysync"
	
	local verysync_json=$(jq -n \
		--arg name "verysync" \
		--arg passwd "123456" \
		--argjson http_port "${VERYSYNC_HTTP_PORT:-8886}" \
		--argjson trans_port "${VERYSYNC_TRANS_PORT:-22330}" \
		--arg etc "${etc_dir}" \
		--arg data "${data_dir}" \
		--arg sys "${sys_dir}" \
		--arg bin "${bin_file}" \
		--arg symlink "${symlink_file}" \
		--arg conf "${etc_dir}/config.xml" \
		'{
			name: $name,
			passwd: $passwd,
			http_port: $http_port,
			trans_port: $trans_port,
			etc_path: $etc,
			data_path: $data,
			sys_path: $sys,
			bin_file: $bin,
			symlink_file: $symlink,
			conf_file: $conf
		}')
		
	local pid_file="/var/run/verysync.pid"
	local log_file="${data_dir}/verysync.log"
	
	import_service_config "verysync" "$pid_file" "$log_file" "$verysync_json"
	return $?
}

# 初始化 verysync 环境
init_verysync_service()
{
	logger "INFO" "[verysync] 初始化服务"
	
	# 设置 verysync 模板
	if ! set_verysync_template; then
		logger "ERROR" "[verysync] 设置模板失败"
		return 1
	fi
	
	# 获取服务配置
	get_service_config "verysync" "config" "verysync_cfg" || {
		logger "ERROR" "[verysync] 无法获取服务配置"
		return 2
	}
	
	# 安装 verysync 环境
	if ! install_verysync_env "$1"; then
		logger "ERROR" "[verysync] 安装环境失败"
		return 3
	fi
	
	# 设置 verysync 环境
	if ! set_verysync_env "$1"; then
		logger "ERROR" "[verysync] 设置环境失败"
		return 4
	fi
	
	logger "INFO" "[verysync] ✓ 初始化服务完成"
}

# 运行 verysync 服务
run_verysync_service()
{
	local -n pid_ref="${1:-}"
	logger "INFO" "[verysync] 运行服务"
	
	# 获取服务配置
	get_service_config "verysync" "config" "verysync_cfg" || {
		logger "ERROR" "[verysync] 无法获取服务配置"
		return 1
	}
	
	local bin_file="${verysync_cfg[bin_file]}"
	local etc_path="${verysync_cfg[etc_path]}"
	local data_path="${verysync_cfg[data_path]}"
	local http_port="${verysync_cfg[http_port]}"
	local trans_port="${verysync_cfg[trans_port]}"
	
	[[ ! -f "$bin_file" ]] && { logger "ERROR" "[verysync] 可执行文件不存在"; return 1; }
	[[ ! -d "$etc_path" ]] && { logger "ERROR" "[verysync] 配置目录不存在"; return 1; }
	
	# 检查是否已运行
	if check_service_alive "verysync"; then
		logger "WARNING" "[verysync] 检测服务已经在运行!"
		return 0
	fi
	
	# 日志文件
	local log_file=$(get_service_log_file "verysync")
	
	# 启动服务
	local verysync_pid=$(exec_as_user ${USER_CONFIG[user]} "
		\"$bin_file\" serve \\
			--config \"${etc_path}\" \\
			--data \"${data_path}\" \\
			--no-browser \\
			--gui-address=\"0.0.0.0:${http_port}\" \\
			--logfile=\"${log_file}\" \\
			--log-max-size 10485760 \\
			--log-max-old-files 5 > /dev/null 2>&1 &
		echo \$!
	") || {
		logger "ERROR" "[verysync] 执行启动命令失败"
		return 2
	}
	
	# 等待进程
	wait_for_pid 5 "$verysync_pid" || {
		logger "ERROR" "[verysync] 进程启动失败 (pid=$verysync_pid)"
		return 3
	}
	
	# 端口检测
	if ! wait_for_ports "${http_port}" "${trans_port}"; then
		logger "ERROR" "[verysync] 检测服务端口未就绪!"
		return 4
	fi
	
	# 写入 PID 文件
	local pid_file=$(get_service_pid_file "verysync")
	echo "$verysync_pid" > "$pid_file"
	
	pid_ref="$verysync_pid"
	logger "INFO" "[verysync] ✓ 启动服务完成!"
}

# 更新 verysync 服务
update_verysync_service()
{
	logger "INFO" "[verysync] 开始检查更新"
	
	# 获取服务配置
	get_service_config "verysync" "config" "verysync_cfg" || {
		logger "ERROR" "[verysync] 无法获取服务配置"
		return 1
	}
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${verysync_cfg[sys_path]}"
	local bin_file="${verysync_cfg[bin_file]}"
	local symlink_file="${verysync_cfg[symlink_file]:-}"
	
	# 检查更新目录是否存在
	if [[ ! -d "$downloads_dir" ]]; then
		logger "ERROR" "[verysync] 更新目录不存在: $downloads_dir"
		return 1
	fi
	
	# 获取更新包
	local latest_path
	latest_path=$(get_service_archive "verysync" "$downloads_dir" download_verysync "*.sig") || {
		logger "ERROR" "[verysync] 下载更新包失败"
		return 2
	}
	
	# 版本检查
	if [[ -f "$bin_file" ]] && [[ -x "$bin_file" ]]; then
		local current_version new_version
		
		current_version=$("$bin_file" --version | awk '{print $2}' | tr -d 'v')
		new_version=$("$latest_path" --version | awk '{print $2}' | tr -d 'v')
		
		if [[ -z "$current_version" ]] || [[ -z "$new_version" ]]; then
			logger "WARNING" "[verysync] 无法获取版本信息, 强制更新"
		else
			# 版本比较
			compare_versions "$new_version" "$current_version"
			local result=$?
			
			case $result in
				0)	# 版本相同
					logger "INFO" "[verysync] 已是最新版本 (v$current_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
				2)	# 当前版本更高
					logger "WARNING" "[verysync] 当前版本更高 (v$current_version > v$new_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
			esac
			
			logger "INFO" "[verysync] 发现新版本: v$current_version → v$new_version"
		fi
		
		# 停止运行中的服务
		if check_service_alive "verysync"; then
			logger "INFO" "[verysync] 停止运行中的服务"
			
			close_verysync_service
			sleep 2
		fi
	fi
	
	# 执行更新
	install_binary "$latest_path" "$install_dir" "$symlink_file" || {
		logger "ERROR" "[verysync] 更新安装失败"
		return 3
	}
	
	# 清理临时文件
	[[ -d "$downloads_dir/output" ]] && rm -rf "$downloads_dir/output"
	
	logger "INFO" "[verysync] ✓ 更新完成"
}

# 停止 verysync 服务
close_verysync_service()
{
	logger "INFO" "[verysync] 开始停止服务"
	
	# 标识文件
	local pid_file=$(get_service_pid_file "verysync")
	
	# 获取PID
	local pid=$(get_service_pid "verysync" 2>/dev/null)
	[[ -z "$pid" && -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null)
	
	# 停止服务
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		logger "INFO" "[verysync] 停止进程 (PID: $pid)"
		
		# 优雅停止
		kill -TERM "$pid" 2>/dev/null
		
		# 等待最多5秒
		for i in {1..5}; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		
		# 强制停止
		if kill -0 "$pid" 2>/dev/null; then
			logger "WARNING" "[verysync] 进程未响应, 强制停止"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	
	# 清理PID文件
	rm -f "$pid_file" 2>/dev/null
	logger "INFO" "[verysync] ✓ 服务已停止"
}