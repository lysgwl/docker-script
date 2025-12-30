#!/bin/bash

# 定义 verysync 配置数组
declare -A VERYSYNC_CONFIG=(
	["name"]="verysync"			# 服务名称
	["passwd"]="123456"			# 缺省密码
	["http_port"]="${VERYSYNC_HTTP_PORT:-8886}"				# WEB 端口号
	["trans_port"]="${VERYSYNC_TRANS_PORT:-22330}"			# 传输端口号
	["etc_path"]="${SYSTEM_CONFIG[config_dir]}/verysync"	# 配置目录
	["data_path"]="${SYSTEM_CONFIG[data_dir]}/verysync"		# 数据目录
	["sys_path"]="/usr/local/verysync"						# 安装路径
	["pid_path"]="/var/run/verysync"						# 标识路径
	["bin_file"]="/usr/local/verysync/verysync"				# 运行文件
	["log_file"]="${SYSTEM_CONFIG[data_dir]}/verysync/verysync.log"		# 日志文件
	["conf_file"]="${SYSTEM_CONFIG[config_dir]}/verysync/config.xml"	# 配置文件
)

readonly -A VERYSYNC_CONFIG

# 下载 verysync 安装包
download_verysync()
{
	print_log "TRACE" "下载 ${VERYSYNC_CONFIG[name]} 安装包" >&2
	local downloads_dir=$1

	local name="${VERYSYNC_CONFIG[name]}"
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
		print_log "ERROR" "下载 $name 文件失败,请检查!" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 verysync 环境
install_verysync_env()
{
	print_log "TRACE" "安装 ${VERYSYNC_CONFIG[name]} 服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/${VERYSYNC_CONFIG[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${VERYSYNC_CONFIG[name]}" "$downloads_dir" download_verysync "*.sig") || {
				print_log "ERROR" "获取 ${VERYSYNC_CONFIG[name]} 安装包失败, 请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				print_log "ERROR" "安装 ${VERYSYNC_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
					
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${VERYSYNC_CONFIG[sys_path]}" || ! -e "${VERYSYNC_CONFIG[bin_file]}" ]]; then
			local install_dir=$(dirname "${VERYSYNC_CONFIG[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				print_log "ERROR" "安装 ${VERYSYNC_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${VERYSYNC_CONFIG[bin_file]}" "" "$install_dir/bin/${VERYSYNC_CONFIG[name]}" || {
				print_log "ERROR" "创建 ${VERYSYNC_CONFIG[name]} 符号链接失败, 请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	print_log "INFO" "安装 ${VERYSYNC_CONFIG[name]} 完成!"
	return 0
}

# 设置 verysync 配置
set_verysync_conf()
{
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 配置文件"
	
	if [ ! -f "${VERYSYNC_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${VERYSYNC_CONFIG[name]} 可执行文件不存在,请检查!"
		return 1
	fi
	
	# 生成配置
	"${VERYSYNC_CONFIG[bin_file]}" generate \
			--config="${VERYSYNC_CONFIG[etc_path]}" \
			--gui-user="admin" \
			--gui-password="${VERYSYNC_CONFIG[passwd]}"
	if [ $? -ne 0 ]; then
		print_log "ERROR" "${VERYSYNC_CONFIG[name]} 配置文件生成失败, 请检查!"
		return 2
	fi
	
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 配置完成!"
	return 0
}

# 设置 verysync 用户
set_verysync_user()
{
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 用户权限"
	
	mkdir -p "${VERYSYNC_CONFIG[pid_path]}"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
		"${VERYSYNC_CONFIG[sys_path]}" \
		"${VERYSYNC_CONFIG[etc_path]}" \
		"${VERYSYNC_CONFIG[data_path]}" \
		"${VERYSYNC_CONFIG[pid_path]}" 2>/dev/null || return 1
		
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 权限完成!"
	return 0
}

# 设置 verysync 环境
set_verysync_env()
{
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 服务配置"
	local arg=$1
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${VERYSYNC_CONFIG[etc_path]}" "${VERYSYNC_CONFIG[data_path]}"
		
		# 设置 verysync 配置
		if ! set_verysync_conf; then
			return 1
		fi
		
		# 设置 verysync 用户
		if ! set_verysync_user; then
			return 1
		fi
	fi
	
	print_log "TRACE" "设置 ${VERYSYNC_CONFIG[name]} 完成!"
	return 0
}

# 初始化 verysync 环境
init_verysync_service()
{
	print_log "TRACE" "初始化 ${VERYSYNC_CONFIG[name]} 服务"
	local arg=$1
	
	# 安装 verysync 环境
	if ! install_verysync_env "$arg"; then
		return 1
	fi
	
	# 设置 verysync 环境
	if ! set_verysync_env "$arg"; then
		return 1
	fi
	
	print_log "TRACE" "初始化 ${VERYSYNC_CONFIG[name]} 服务成功!"
	return 0
}

# 运行 verysync 服务
run_verysync_service()
{
	print_log "TRACE" "运行 ${VERYSYNC_CONFIG[name]} 服务"
	
	if [ ! -e "${VERYSYNC_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "运行 ${VERYSYNC_CONFIG[name]} 服务失败, 请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${VERYSYNC_CONFIG[pid_path]}/${VERYSYNC_CONFIG[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${VERYSYNC_CONFIG[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				print_log "WARNING" "${VERYSYNC_CONFIG[name]} 服务已经在运行!(PID:$pid)"
				return 0
			fi
		fi
	fi
	
	# 后台运行 verysync 服务		# sudo -u ${SERVICE_APP_USER} --
	nohup "${VERYSYNC_CONFIG[bin_file]}" \
			--config "${VERYSYNC_CONFIG[etc_path]}" \
			--data "${VERYSYNC_CONFIG[data_path]}" \
			--no-browser \
			--gui-address="0.0.0.0:${VERYSYNC_CONFIG[http_port]}" \
			--logfile="${VERYSYNC_CONFIG[log_file]}" \
			> /dev/null 2>&1 &

	# 获取后台进程的 PID
	local verysync_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$verysync_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${VERYSYNC_CONFIG[http_port]}" "${VERYSYNC_CONFIG[trans_port]}"; then
		print_log "ERROR" "${VERYSYNC_CONFIG[name]} 端口未就绪!"
		return 1
	fi
	
	echo "$verysync_pid" > "$pid_file"
	print_log "TRACE" "启动 ${VERYSYNC_CONFIG[name]} 服务成功!"
}

# 更新 verysync 服务
update_verysync_service()
{
	print_log "TRACE" "更新 ${VERYSYNC_CONFIG[name]} 服务"
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${VERYSYNC_CONFIG[sys_path]}"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${VERYSYNC_CONFIG[name]}" "$downloads_dir" download_verysync) || {
		print_log "ERROR" "获取 ${VERYSYNC_CONFIG[name]} 安装包失败!"
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${VERYSYNC_CONFIG[bin_file]}" ]; then
		install_binary "$latest_path" "$install_dir" "/usr/local/bin/${VERYSYNC_CONFIG[name]}" || {
			print_log "ERROR" "安装 ${VERYSYNC_CONFIG[name]} 失败!"
			return 2
		}
		
		rm -rf "$downloads_dir/output"
		return 0
	fi
	
	local current_version=$(${VERYSYNC_CONFIG[bin_file]} --version | awk '{print $2}' | tr -d 'v')
	local new_version=$($latest_path --version | awk '{print $2}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?
	
	case $result in
		0)
			print_log "INFO" "${VERYSYNC_CONFIG[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 verysync 运行
			close_verysync_service
			
			# 安装软件包
			install_binary "$latest_path" "$install_dir" || {
				print_log "ERROR" "更新 ${VERYSYNC_CONFIG[name]} 失败!"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			print_log "INFO" "${VERYSYNC_CONFIG[name]} 已更新至 v$new_version"
			return 0
			;;
		2)
			print_log "INFO" "当前版本 (v$current_version) 比下载版本 (v$new_version) 更高"
			return 0
			;;
		*)
			print_log "ERROR" "版本比较异常 $current_version -> $new_version"
			return 2
			;;
	esac
}

# 停止 verysync 服务
close_verysync_service()
{
	print_log "TRACE" "关闭 ${VERYSYNC_CONFIG[name]} 服务"
	
	if [ ! -x "${VERYSYNC_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${VERYSYNC_CONFIG[name]} 服务不存在, 请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${VERYSYNC_CONFIG[pid_path]}/${VERYSYNC_CONFIG[name]}.pid"
	
	# 检查 verysync 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 verysync 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			print_log "INFO" "${VERYSYNC_CONFIG[name]} 服务进程:${PID}"
			kill "$PID"
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${VERYSYNC_CONFIG[name]}); do
		print_log "INFO" "${VERYSYNC_CONFIG[name]} 服务进程:${PID}"
		kill "$PID"
	done
	
	print_log "TRACE" "关闭 ${VERYSYNC_CONFIG[name]} 服务成功!"
}