#!/bin/bash

# 下载 syncthing 安装包
download_syncthing()
{
	logger "INFO" "[syncthing] 下载服务安装包" >&2
	
	local downloads_dir=$1
	local name="syncthing"
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"arm"}'
	local mapped_arch=$(jq -r ".\"${SYSTEM_CONFIG[arch]}\" // empty" <<< "$arch_map")
	
	if [[ -z "$mapped_arch" ]]; then
		logger "ERROR" "[syncthing] 不支持的架构 ${SYSTEM_CONFIG[arch]}" >&2
		return 1
	fi
	
	# 动态生成匹配条件
	local matcher_conditions=(
		"[[ \$name =~ ${SYSTEM_CONFIG[type]} ]]"
		"[[ \$name =~ $mapped_arch ]]"
	)
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local json_config=$(jq -n \
		--arg type "github" \
		--arg name "$name" \
		--arg repo "syncthing/syncthing" \
		--argjson asset_matcher "$(printf '%s' "$asset_matcher" | jq -Rs .)" \
		'{
			type: $type,
			name: $name,
			repo: $repo,
			asset_matcher: $asset_matcher,
			tags: "release"
		}')
		
	# 调用下载函数
	local latest_file
	if ! latest_file=$(download_package "$json_config" "$downloads_dir"); then
		logger "ERROR" "[syncthing] 下载服务文件失败" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 syncthing 环境
install_syncthing_env()
{
	logger "INFO" "[syncthing] 安装服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/syncthing"
	if [[ "$arg" = "init" ]]; then
		if [[ ! -d "$target_path" ]]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "syncthing" "$downloads_dir" download_syncthing) || {
				logger "ERROR" "[syncthing] 获取服务安装包失败"
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				logger "ERROR" "[syncthing] 安装服务失败"
				return 2
			}
					
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [[ "$arg" = "config" ]]; then
		if [[ ! -d "${syncthing_cfg[sys_path]}" || ! -e "${syncthing_cfg[bin_file]}" ]]; then
			local install_dir=$(dirname "${syncthing_cfg[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				logger "ERROR" "[syncthing] 安装服务失败"
				return 2
			}
			
			# 创建符号链接
			install_binary "${syncthing_cfg[bin_file]}" "" "${syncthing_cfg[symlink_file]}" || {
				logger "ERROR" "[syncthing] 创建服务符号链接失败"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	logger "INFO" "[syncthing] 服务安装完成"
}

# 设置 syncthing 用户
set_syncthing_user()
{
	logger "INFO" "[syncthing] 设置服务用户权限"
	
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	# 获取配置路径
	local sys_path="${syncthing_cfg[sys_path]}"
	local etc_path="${syncthing_cfg[etc_path]}"
	local data_path="${syncthing_cfg[data_path]}"
	
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
	local pid_file=$(get_service_pid_file "syncthing")
	if [[ -n "$pid_file" ]]; then
		chown "$user:$group" "$pid_file" 2>/dev/null || true
		chmod 666 "$pid_file" 2>/dev/null || true
	fi
	
	logger "INFO" "[syncthing] 服务权限完成"
}

# 设置 syncthing 配置文件
set_syncthing_conf()
{
	logger "INFO" "[syncthing] 设置服务配置文件"
	
	local etc_path="${syncthing_cfg[etc_path]}"
	local data_path="${syncthing_cfg[data_path]}"
	local bin_file="${syncthing_cfg[bin_file]}"
	local conf_file="${syncthing_cfg[conf_file]}"
	local http_port="${syncthing_cfg[http_port]}"
	local trans_port="${syncthing_cfg[trans_port]}"
	local passwd="${syncthing_cfg[passwd]}"
	
	# 检查可执行文件
	if [[ ! -f "$bin_file" ]]; then
		logger "ERROR" "[syncthing] 可执行文件不存在: $bin_file"
		return 1
	fi
	
	# 生成初始配置
	if [[ ! -f "$conf_file" ]]; then
		#echo '<?xml version="1.0" encoding="UTF-8"?><configuration version="37"></configuration>' > "${syncthing_cfg[conf_file]}"
		
		local gen_cmd=(
			"$bin_file" generate
			"--config=$etc_path"
			"--data=$data_path"
			"--gui-user=admin"
			"--gui-password=$passwd"
		)
		
		if ! "${gen_cmd[@]}"; then
			logger "ERROR" "[syncthing] 配置文件生成失败"
			return 2
		fi
		
		# 等待配置文件生成
		for ((retry=0; retry<10; retry++)); do
			[[ -f "$conf_file" ]] && break
			sleep 1
		done
		
		if [[ ! -f "$conf_file" ]]; then
			logger "ERROR" "[syncthing] 配置文件未生成: $conf_file"
			return 3
		fi
	fi
	
	logger "INFO" "[syncthing] 配置配置文件: $conf_file"
	
	# 停止正在运行的syncthing进程
	local syncthing_pids=$(pgrep -f "syncthing" 2>/dev/null)
	if [[ -n "$syncthing_pids" ]]; then
		logger "INFO" "[syncthing] 停止运行中的进程: $syncthing_pids"
		
		kill $syncthing_pids 2>/dev/null
		sleep 2
	fi
	
	# GUI配置
	xmlstarlet ed -L \
		--subnode '/configuration[not(gui)]' -t elem -n 'gui' -v "" \
		--subnode '/configuration/gui[not(address)]' -t elem -n 'address' -v "" \
		--subnode '/configuration/gui[not(tls)]' -t elem -n 'tls' -v "" \
		--subnode '/configuration/gui[not(urlbase)]' -t elem -n 'urlbase' -v "" \
		-u '/configuration/gui/address' -v "0.0.0.0:$http_port" \
		-u '/configuration/gui/tls' -v "false" \
		-u '/configuration/gui/urlbase' -v "/syncthing" \
		"$conf_file" || {
		logger "ERROR" "[syncthing] GUI配置失败"
		return 3
	}
	
	# 配置全局选项
	local options_config=(
		# 格式："元素名:元素值"
		"globalAnnounceEnabled:false"
		"localAnnounceEnabled:true"
		"natEnabled:true"
		"urAccepted:-1"
		"startBrowser:false"
		"listenAddresses:tcp://0.0.0.0:${trans_port}, quic://0.0.0.0:${trans_port}"
		"connectionLimitEnough:32"
		"connectionLimitMax:64"
		"maxSendKbps:0"
		"maxRecvKbps:0"
		"fsWatcherEnabled:true"
		"fsWatcherDelayS:5"
		"maxConcurrentWrites:4"
		"dbBlockCacheSize:8388608"
		"setLowPriority:true"
		"maxFolderConcurrency:4"
		"sendFullIndexOnUpgrade:false"
		"stunKeepaliveStartS:300"
		"autoUpgradeIntervalH:0"
	)
	
	local options_args=(-s '/configuration[not(options)]' -t elem -n 'options')
	for item in "${options_config[@]}"; do
		IFS=":" read -r name value <<< "$item"
		options_args+=(
			-s "/configuration/options[not($name)]" -t elem -n "$name" -v ""
			-u "/configuration/options/$name" -v "$value"
		)
	done
	
	xmlstarlet ed -L \
		"${options_args[@]}" \
		"$conf_file" || {
		logger "ERROR" "[syncthing] 全局选项配置失败"
		return 4
	}
	
	# 配置默认文件夹
	xmlstarlet ed -L --pf \
		-s "/configuration[not(folder[@id='default'])]" -t elem -n "folder" \
		-i "/configuration/folder[last()][not(@id)]" -t attr -n "id" -v "default" \
		-i "/configuration/folder[@id='default'][not(@path)]" -t attr -n "path" -v "${data_path}/default" \
		-u "/configuration/folder[@id='default']/@path" -v "${data_path}/default" \
		-s "/configuration/folder[@id='default'][not(label)]" -t elem -n "label" -v "默认目录" \
		-s "/configuration/folder[@id='default'][not(minDiskFree)]" -t elem -n "minDiskFree" -v "5" \
		-s "/configuration/folder[@id='default'][not(copiers)]" -t elem -n "copiers" -v "4" \
		-s "/configuration/folder[@id='default'][not(pullerMaxPendingKiB)]" -t elem -n "pullerMaxPendingKiB" -v "102400" \
		"$conf_file" || {
		logger "ERROR" "[syncthing] 文件夹配置失败"
		return 5
	}
	
	logger "INFO" "[syncthing] 服务配置完成"
}

# 设置 syncthing 路径
set_syncthing_paths()
{
	logger "INFO" "[syncthing] 设置服务环境目录"
	
	# 获取配置路径
	local sys_path="${syncthing_cfg[sys_path]}"
	local etc_path="${syncthing_cfg[etc_path]}"
	local data_path="${syncthing_cfg[data_path]}"
	
	# 获取PID文件
	local pid_file=$(get_service_pid_file "syncthing")
	
	# 创建目录
	for dir in "$sys_path" "$etc_path" "$data_path"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[syncthing] 目录 $dir 变量为空"
			return 1
		fi
		
		if ! mkdir -p "$dir"; then
			logger "ERROR" "[syncthing] 目录创建失败: $dir"
			return 2
		fi
	done
	
	# 创建文件
	for file in "$pid_file"; do
		if [[ -z "$file" ]]; then
			logger "ERROR" "[syncthing] 文件 $file 路径为空"
			return 1
		fi
		
		local parent=$(dirname "$file")
		if ! mkdir -p "$parent"; then
			logger "ERROR" "[syncthing] 父目录创建失败: $parent"
			return 1
		fi
		
		if ! touch "$file"; then
			logger "ERROR" "[syncthing] 文件创建失败: $file"
			return 3
		fi
	done
	
	logger "INFO" "[syncthing] 设置目录完成"
}

# 设置 syncthing 环境
set_syncthing_env()
{
	logger "INFO" "[syncthing] 设置服务环境"
	
	if [[ "$1" = "config" ]]; then
		# 创建环境目录
		if ! set_syncthing_paths; then
			logger "ERROR" "[syncthing] 设置环境路径失败"
			return 1
		fi
		
		# 设置 syncthing 配置文件
		if ! set_syncthing_conf; then
			logger "ERROR" "[syncthing] 设置服务配置文件失败"
			return 2
		fi
		
		# 设置 syncthing 用户
		if ! set_syncthing_user; then
			logger "ERROR" "[syncthing] 设置服务用户权限失败"
			return 3
		fi
	fi
	
	logger "INFO" "[syncthing] 设置服务完成"
}

# 设置 syncthing 模板
set_syncthing_template()
{
	# 获取配置路径
	local data_dir="${SYSTEM_CONFIG[data_dir]}/syncthing"
	local etc_dir="${SYSTEM_CONFIG[config_dir]}/syncthing"
	local sys_dir="/usr/local/syncthing"
	local bin_file="${sys_dir}/syncthing"
	local symlink_file="/usr/local/bin/syncthing"
	
	local syncthing_json=$(jq -n \
		--arg name "syncthing" \
		--arg passwd "123456" \
		--argjson http_port "${SYNCTHING_HTTP_PORT:-8384}" \
		--argjson trans_port "${SYNCTHING_TRANS_PORT:-22000}" \
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
		
	local pid_file="/var/run/syncthing.pid"
	local log_file="${data_dir}/syncthing.log"
		
	import_service_config "syncthing" "$pid_file" "$log_file" "$syncthing_json"
	return $?
}

# 初始化 syncthing 环境
init_syncthing_service()
{
	logger "INFO" "[syncthing] 初始化服务"
	
	# 设置 syncthing 模板
	if ! set_syncthing_template; then
		logger "ERROR" "[syncthing] 设置模板失败"
		return 1
	fi
	
	# 获取服务配置
	get_service_config "syncthing" "config" "syncthing_cfg" || {
		logger "ERROR" "[syncthing] 无法获取服务配置"
		return 2
	}
	
	# 安装 syncthing 环境
	if ! install_syncthing_env "$1"; then
		logger "ERROR" "[syncthing] 安装环境失败"
		return 3
	fi
	
	# 设置 syncthing 环境
	if ! set_syncthing_env "$1"; then
		logger "ERROR" "[syncthing] 设置环境失败"
		return 4
	fi
	
	logger "INFO" "[syncthing] ✓ 初始化服务完成"
}

# 运行 syncthing 服务
run_syncthing_service()
{
	local -n pid_ref="${1:-}"
	logger "INFO" "[syncthing] 运行服务"
	
	# 获取服务配置
	get_service_config "syncthing" "config" "syncthing_cfg" || {
		logger "ERROR" "[syncthing] 无法获取服务配置"
		return 1
	}
	
	local bin_file="${syncthing_cfg[bin_file]}"
	local etc_path="${syncthing_cfg[etc_path]}"
	local data_path="${syncthing_cfg[data_path]}"
	local http_port="${syncthing_cfg[http_port]}"
	local trans_port="${syncthing_cfg[trans_port]}"
	
	[[ ! -f "$bin_file" ]] && { logger "ERROR" "[syncthing] 可执行文件不存在"; return 1; }
	[[ ! -d "$etc_path" ]] && { logger "ERROR" "[syncthing] 配置目录不存在"; return 1; }
	
	# 检查是否已运行
	if check_service_alive "syncthing"; then
		logger "WARNING" "[syncthing] 检测服务已经在运行!"
		return 0
	fi
	
	# 日志文件
	local log_file=$(get_service_log_file "syncthing")
	
	# 启动服务
	local syncthing_pid=$(exec_as_user ${USER_CONFIG[user]} "
		\"$bin_file\" serve \\
			--config \"${etc_path}\" \\
			--data \"${data_path}\" \\
			--no-browser \\
			--gui-address=\"0.0.0.0:${http_port}\" \\
			--log-file \"${log_file}\" \\
			--log-max-size 10485760 \\
			--log-max-old-files 5 \\
			--log-level \"${LOG_LEVEL}\" > /dev/null 2>&1 &
		echo \$!
	") || {
		logger "ERROR" "[syncthing] 执行启动命令失败"
		return 2
	}
	
	# 等待进程
	wait_for_pid 5 "$syncthing_pid" || {
		logger "ERROR" "[syncthing] 进程启动失败 (pid=$syncthing_pid)"
		return 3
	}
	
	# 端口检测
	if ! wait_for_ports "${http_port}" "${trans_port}"; then
		logger "ERROR" "[syncthing] 检测服务端口未就绪!"
		return 4
	fi
	
	# PID文件
	local pid_file=$(get_service_pid_file "syncthing")
	echo "$syncthing_pid" > "$pid_file"
	
	pid_ref="$syncthing_pid"
	logger "INFO" "[syncthing] ✓ 启动服务完成!"
}

# 更新 syncthing 服务
update_syncthing_service()
{
	logger "INFO" "[syncthing] 开始检查更新"
	
	# 获取服务配置
	get_service_config "syncthing" "config" "syncthing_cfg" || {
		logger "ERROR" "[syncthing] 无法获取服务配置"
		return 1
	}
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${syncthing_cfg[sys_path]}"
	local bin_file="${syncthing_cfg[bin_file]}"
	local symlink_file="${syncthing_cfg[symlink_file]:-}"
	
	# 检查更新目录是否存在
	if [[ ! -d "$downloads_dir" ]]; then
		logger "ERROR" "[syncthing] 更新目录不存在: $downloads_dir"
		return 1
	fi
	
	# 获取更新包
	local latest_path
	latest_path=$(get_service_archive "syncthing" "$downloads_dir" download_syncthing) || {
		logger "ERROR" "[syncthing] 下载更新包失败"
		return 2
	}
	
	# 版本检查
	if [[ -f "$bin_file" ]] && [[ -x "$bin_file" ]]; then
		local current_version new_version
		
		current_version=$("$bin_file" --version | awk '{print $2}' | tr -d 'v')
		new_version=$("$latest_path" --version | awk '{print $2}' | tr -d 'v')
		
		if [[ -z "$current_version" ]] || [[ -z "$new_version" ]]; then
			logger "WARNING" "[syncthing] 无法获取版本信息, 强制更新"
		else
			# 版本比较
			compare_versions "$new_version" "$current_version"
			local result=$?
			
			case $result in
				0)	# 版本相同
					logger "INFO" "[syncthing] 已是最新版本 (v$current_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
				2)	# 当前版本更高
					logger "WARNING" "[syncthing] 当前版本更高 (v$current_version > v$new_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
			esac
			
			logger "INFO" "[syncthing] 发现新版本: v$current_version → v$new_version"
		fi
		
		# 停止运行中的服务
		if check_service_alive "syncthing"; then
			logger "INFO" "[syncthing] 停止运行中的服务"
			
			close_syncthing_service
			sleep 2
		fi
	fi
	
	# 执行更新
	install_binary "$latest_path" "$install_dir" "$symlink_file" || {
		logger "ERROR" "[syncthing] 更新安装失败"
		return 3
	}
	
	# 清理临时文件
	[[ -d "$downloads_dir/output" ]] && rm -rf "$downloads_dir/output"
	
	logger "INFO" "[syncthing] ✓ 更新完成"
}

# 停止 syncthing 服务
close_syncthing_service()
{
	logger "INFO" "[syncthing] 开始停止服务"
	
	# 标识文件
	local pid_file=$(get_service_pid_file "syncthing")
	
	# 获取PID
	local pid=$(get_service_pid "syncthing" 2>/dev/null)
	[[ -z "$pid" && -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null)
	
	# 停止服务
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		logger "INFO" "[syncthing] 停止进程 (PID: $pid)"
		
		# 优雅停止
		kill -TERM "$pid" 2>/dev/null
		
		# 等待最多5秒
		for i in {1..5}; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		
		# 强制停止
		if kill -0 "$pid" 2>/dev/null; then
			logger "WARNING" "[syncthing] 进程未响应, 强制停止"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	
	# 清理PID文件
	rm -f "$pid_file" 2>/dev/null
	logger "INFO" "[syncthing] ✓ 服务已停止"
}