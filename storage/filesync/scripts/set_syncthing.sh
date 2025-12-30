#!/bin/bash

# 定义 syncthing 配置数组
declare -A SYNCTHING_CONFIG=(
	["name"]="syncthing"		# 服务名称
	["passwd"]="123456"			# 缺省密码
	["http_port"]="${SYNCTHING_HTTP_PORT:-8384}"			# WEB 端口号
	["trans_port"]="${SYNCTHING_TRANS_PORT:-22000}"			# 传输端口号
	["etc_path"]="${SYSTEM_CONFIG[config_dir]}/syncthing"	# 配置目录
	["data_path"]="${SYSTEM_CONFIG[data_dir]}/syncthing"	# 数据目录
	["sys_path"]="/usr/local/syncthing"						# 安装路径
	["pid_path"]="/var/run/syncthing"						# 标识路径
	["bin_file"]="/usr/local/syncthing/syncthing"			# 运行文件
	["log_file"]="${SYSTEM_CONFIG[data_dir]}/syncthing/syncthing.log"	# 日志文件
	["conf_file"]="${SYSTEM_CONFIG[config_dir]}/syncthing/config.xml"	# 配置文件
)

readonly -A SYNCTHING_CONFIG

# 下载 syncthing 安装包
download_syncthing()
{
	print_log "TRACE" "下载 ${SYNCTHING_CONFIG[name]} 安装包" >&2
	
	local downloads_dir=$1
	local name="${SYNCTHING_CONFIG[name]}"
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"arm"}'
	local mapped_arch=$(jq -r ".\"${SYSTEM_CONFIG[arch]}\" // empty" <<< "$arch_map")
	
	if [ -z "$mapped_arch" ]; then
		print_log "ERROR" "不支持的架构 ${SYSTEM_CONFIG[arch]}, 请检查!" >&2
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
		print_log "ERROR" "下载 $name 文件失败,请检查!" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 syncthing 环境
install_syncthing_env()
{
	print_log "TRACE" "安装 ${SYNCTHING_CONFIG[name]} 服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/${SYNCTHING_CONFIG[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${SYNCTHING_CONFIG[name]}" "$downloads_dir" download_syncthing) || {
				print_log "ERROR" "获取 ${SYNCTHING_CONFIG[name]} 安装包失败, 请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				print_log "ERROR" "安装 ${SYNCTHING_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
					
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${SYNCTHING_CONFIG[sys_path]}" || ! -e "${SYNCTHING_CONFIG[bin_file]}" ]]; then
			local install_dir=$(dirname "${SYNCTHING_CONFIG[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				print_log "ERROR" "安装 ${SYNCTHING_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${SYNCTHING_CONFIG[bin_file]}" "" "$install_dir/bin/${SYNCTHING_CONFIG[name]}" || {
				print_log "ERROR" "创建 ${SYNCTHING_CONFIG[name]} 符号链接失败, 请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	print_log "INFO" "安装 ${SYNCTHING_CONFIG[name]} 完成!"
	return 0
}

# 设置 syncthing 配置
set_syncthing_conf()
{
	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 配置文件"
	
	if [ ! -f "${SYNCTHING_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${SYNCTHING_CONFIG[name]} 可执行文件不存在, 请检查!"
		return 1
	fi
	
	if [ ! -f "${SYNCTHING_CONFIG[conf_file]}" ]; then
		#echo '<?xml version="1.0" encoding="UTF-8"?><configuration version="37"></configuration>' > "${SYNCTHING_CONFIG[conf_file]}"

		"${SYNCTHING_CONFIG[bin_file]}" generate \
			--config="${SYNCTHING_CONFIG[etc_path]}" \
			--data="${SYNCTHING_CONFIG[data_path]}" \
			--gui-user="admin" \
			--gui-password="${SYNCTHING_CONFIG[passwd]}"
		if [ $? -ne 0 ]; then
			print_log "ERROR" "${SYNCTHING_CONFIG[name]} 配置文件生成失败, 请检查!"
			return 2
		fi
	fi
	
	# 等待3次，每次5秒
	for ((retry=3; retry>0; retry--)); do
		[ -f "${SYNCTHING_CONFIG[conf_file]}" ] && break
		sleep 5
	done
	
	print_log "INFO" "初始化 ${SYNCTHING_CONFIG[name]} 配置文件: ${SYNCTHING_CONFIG[conf_file]}"
	
	# 修改 Syncthing 配置
	if [ -f "${SYNCTHING_CONFIG[conf_file]}" ]; then
		# 停止正在运行的进程
		pkill -f "${SYNCTHING_CONFIG[bin_file]}"
		sleep 2
		
		# GUI配置
		xmlstarlet ed -L \
			--subnode '/configuration[not(gui)]' -t elem -n 'gui' -v "" \
			--subnode '/configuration/gui[not(address)]' -t elem -n 'address' -v "" \
			--subnode '/configuration/gui[not(tls)]' -t elem -n 'tls' -v "" \
			--subnode '/configuration/gui[not(urlbase)]' -t elem -n 'urlbase' -v "" \
			-u '/configuration/gui/address' -v "0.0.0.0:${SYNCTHING_CONFIG[http_port]}" \
			-u '/configuration/gui/tls' -v "false" \
			-u '/configuration/gui/urlbase' -v "/syncthing" \
			"${SYNCTHING_CONFIG[conf_file]}" || {
			print_log "ERROR" "${SYNCTHING_CONFIG[name]} GUI配置失败, 请检查!"
			return 1
		}
	
		# 全局选项配置
		local options_config=(
			# 格式："元素名:元素值"
			"globalAnnounceEnabled:false"
			"localAnnounceEnabled:true"
			"natEnabled:true"
			"urAccepted:-1"
			"startBrowser:false"
			"listenAddresses:tcp://0.0.0.0:${SYNCTHING_CONFIG[trans_port]}, quic://0.0.0.0:${SYNCTHING_CONFIG[trans_port]}"
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
			"${SYNCTHING_CONFIG[conf_file]}" || {
			print_log "ERROR" "${SYNCTHING_CONFIG[name]} 全局选项配置失败, 请检查!"
			return 1
		}
			
		# 文件夹配置
		xmlstarlet ed -L --pf \
			-s "/configuration[not(folder[@id='default'])]" -t elem -n "folder" \
			-i "/configuration/folder[last()][not(@id)]" -t attr -n "id" -v "default" \
			-i "/configuration/folder[@id='default'][not(@path)]" -t attr -n "path" -v "${SYNCTHING_CONFIG[data_path]}/default" \
			-u "/configuration/folder[@id='default']/@path" -v "${SYNCTHING_CONFIG[data_path]}/default" \
			-s "/configuration/folder[@id='default'][not(label)]" -t elem -n "label" -v "默认目录" \
			-s "/configuration/folder[@id='default'][not(minDiskFree)]" -t elem -n "minDiskFree" -v "5" \
			-s "/configuration/folder[@id='default'][not(copiers)]" -t elem -n "copiers" -v "4" \
			-s "/configuration/folder[@id='default'][not(pullerMaxPendingKiB)]" -t elem -n "pullerMaxPendingKiB" -v "102400" \
			"${SYNCTHING_CONFIG[conf_file]}" || {
			print_log "ERROR" "${SYNCTHING_CONFIG[name]} 文件夹配置失败, 请检查!"
			return 1
		}		
	fi
	
	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 配置完成!"
	return 0
}

# 设置 syncthing 用户
set_syncthing_user()
{
	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 用户权限"

	mkdir -p "${SYNCTHING_CONFIG[pid_path]}"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
		"${SYNCTHING_CONFIG[sys_path]}" \
		"${SYNCTHING_CONFIG[etc_path]}" \
		"${SYNCTHING_CONFIG[data_path]}" \
		"${SYNCTHING_CONFIG[pid_path]}" 2>/dev/null || return 1

	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 权限完成!"
	return 0
}

# 设置 syncthing 环境
set_syncthing_env()
{
	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 服务环境"
	local arg=$1

	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${SYNCTHING_CONFIG[etc_path]}" "${SYNCTHING_CONFIG[data_path]}"
		
		# 设置 syncthing 配置
		if ! set_syncthing_conf; then
			return 1
		fi
		
		# 设置 syncthing 用户
		if ! set_syncthing_user; then
			return 1
		fi
	fi
	
	print_log "TRACE" "设置 ${SYNCTHING_CONFIG[name]} 完成!"
	return 0
}

# 初始化 syncthing 环境
init_syncthing_service()
{
	print_log "TRACE" "初始化 ${SYNCTHING_CONFIG[name]} 服务"
	local arg=$1
	
	# 安装 syncthing 环境
	if ! install_syncthing_env "$arg"; then
		return 1
	fi
	
	# 设置 syncthing 环境
	if ! set_syncthing_env "$arg"; then
		return 1
	fi
	
	print_log "TRACE" "初始化 ${SYNCTHING_CONFIG[name]} 服务成功!"
	return 0
}

# 运行 syncthing 服务
run_syncthing_service()
{
	print_log "TRACE" "运行 ${SYNCTHING_CONFIG[name]} 服务"
	
	if [ ! -e "${SYNCTHING_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "运行 ${SYNCTHING_CONFIG[name]} 服务失败, 请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${SYNCTHING_CONFIG[pid_path]}/${SYNCTHING_CONFIG[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${SYNCTHING_CONFIG[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				print_log "WARNING" "${SYNCTHING_CONFIG[name]} 服务已经在运行(PID:$pid), 请检查!"
				return 0
			fi
		fi
	fi
	
	# 后台运行 syncthing 服务		# sudo -u ${SERVICE_APP_USER} --
	nohup "${SYNCTHING_CONFIG[bin_file]}" \
			--config "${SYNCTHING_CONFIG[etc_path]}" \
			--data "${SYNCTHING_CONFIG[data_path]}" \
			--no-browser \
			--gui-address="0.0.0.0:${SYNCTHING_CONFIG[http_port]}" \
			> "${SYNCTHING_CONFIG[log_file]}" 2>&1 &

	# 获取后台进程的 PID
	local syncthing_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$syncthing_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${SYNCTHING_CONFIG[http_port]}" "${SYNCTHING_CONFIG[trans_port]}"; then
		print_log "ERROR" "${SYNCTHING_CONFIG[name]} 端口未就绪,查看服务日志!"
		return 1
	fi
	
	echo "$syncthing_pid" > "$pid_file"
	print_log "TRACE" "启动 ${SYNCTHING_CONFIG[name]} 服务成功!"
}

# 更新 syncthing 服务
update_syncthing_service()
{
	print_log "TRACE" "更新 ${SYNCTHING_CONFIG[name]} 服务"
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${SYNCTHING_CONFIG[sys_path]}"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${SYNCTHING_CONFIG[name]}" "$downloads_dir" download_openlist) || {
		print_log "ERROR" "获取 ${SYNCTHING_CONFIG[name]} 安装包失败!"
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${SYNCTHING_CONFIG[bin_file]}" ]; then
		install_binary "$latest_path" "$install_dir" "/usr/local/bin/${SYNCTHING_CONFIG[name]}" || {
			print_log "ERROR" "安装 ${SYNCTHING_CONFIG[name]} 失败!"
			return 2
		}
		
		rm -rf "$downloads_dir/output"
		return 0
	fi
	
	local current_version=$(${SYNCTHING_CONFIG[bin_file]} --version | awk '{print $2}' | tr -d 'v')
	local new_version=$($latest_path --version | awk '{print $2}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?
	
	case $result in
		0)
			print_log "INFO" "${SYNCTHING_CONFIG[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 syncthing 运行
			close_syncthing_service
			
			# 安装软件包
			install_binary "$latest_path" "$install_dir" || {
				print_log "ERROR" "更新 ${SYNCTHING_CONFIG[name]} 失败!"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			print_log "INFO" "${SYNCTHING_CONFIG[name]} 已更新至 v$new_version"
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

# 停止 syncthing 服务
close_syncthing_service()
{
	print_log "TRACE" "关闭 ${SYNCTHING_CONFIG[name]} 服务"
	
	if [ ! -x "${SYNCTHING_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${SYNCTHING_CONFIG[name]} 服务不存在,请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${SYNCTHING_CONFIG[pid_path]}/${SYNCTHING_CONFIG[name]}.pid"
	
	# 检查 syncthing 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 syncthing 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			print_log "INFO" "${SYNCTHING_CONFIG[name]} 服务进程:$PID"
			kill "$PID"
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${SYNCTHING_CONFIG[name]}); do
		print_log "INFO" "${SYNCTHING_CONFIG[name]} 服务进程:$PID"
		kill "$PID"
	done
	
	print_log "TRACE" "关闭 ${SYNCTHING_CONFIG[name]} 服务成功!"
}