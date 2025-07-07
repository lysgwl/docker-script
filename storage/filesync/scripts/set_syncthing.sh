#!/bin/bash

# 定义 syncthing 配置数组
declare -A syncthing_config=(
	["name"]="syncthing"		# 服务名称
	["passwd"]="123456"			# 缺省密码
	["http_port"]="${SYNCTHING_HTTP_PORT:-8384}"			# WEB 端口号
	["trans_port"]="${SYNCTHING_TRANS_PORT:-22000}"			# 传输端口号
	["etc_path"]="${system_config[config_dir]}/syncthing"	# 配置目录
	["data_path"]="${system_config[data_dir]}/syncthing"	# 数据目录
	["sys_path"]="/usr/local/syncthing"						# 安装路径
	["pid_path"]="/var/run/syncthing"						# 标识路径
	["bin_file"]="/usr/local/syncthing/syncthing"			# 运行文件
	["log_file"]="${system_config[data_dir]}/syncthing/syncthing.log"	# 日志文件
	["conf_file"]="${system_config[config_dir]}/syncthing/config.xml"	# 配置文件
)

readonly -A syncthing_config

# 下载 syncthing 安装包
download_syncthing()
{
	local downloads_dir=$1
	echo "[INFO] 下载${syncthing_config[name]}安装包" >&2
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"arm"}'
	local mapped_arch=$(jq -r ".\"${system_config[arch]}\" // empty" <<< "$arch_map")
	
	if [ -z "$mapped_arch" ]; then
		echo "[ERROR] 不支持的架构${system_config[arch]},请检查!" >&2
		return 1
	fi
	
	# 动态生成匹配条件
	local matcher_conditions=(
		"[[ \$name =~ ${system_config[type]} ]]"
		"[[ \$name =~ $mapped_arch ]]"
	)
	
	local name_value="${syncthing_config[name]}"
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local json_config=$(jq -n \
		--arg type "github" \
		--arg name "$name_value" \
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
		return 2
	fi
	
	echo "$latest_file"
	return 0
}

# 安装 syncthing 环境
install_syncthing_env()
{
	local arg=$1
	echo "[INFO] 安装${syncthing_config[name]}服务环境"
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	local name="${syncthing_config[name]}"
	local target_path="${install_dir}/$name"

	if [ "$arg" = "init" ]; then
		if [ -z "$(find "$install_dir" -maxdepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)" ]; then
			local output_dir="${downloads_dir}/output"
			if [ ! -d "$output_dir" ]; then
				mkdir -p "$output_dir"
			fi
			
			local findpath latest_path archive_path
			if ! findpath=$(find_latest_archive "$downloads_dir" "$name.*"); then
				echo "[WARNING] 未匹配到${name}软件包..." >&2
				
				# 下载文件并验证
				local download_file
				download_file=$(download_syncthing "$downloads_dir") || {
					echo "[ERROR] 下载$name软件包失败,请检查!"
					return 2
				}
				
				archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*$name-${system_config[type]}.*") || return 3
			else
				# 解析文件类型和路径
				local archive_type=$(jq -r '.filetype' <<< "$findpath")
				archive_path=$(jq -r '.filepath' <<< "$findpath")
				
				# 验证文件类型
				if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
					return 1
				fi
				
				if [ "$archive_type" = "file" ]; then
					archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*$name-${system_config[type]}.*") || return 3
				fi	
			fi
			
			# 查找目标文件
			if [[ -f "$archive_path" ]]; then
				latest_path="$archive_path"
			else
				latest_path=$(find "$archive_path" -maxdepth 1 -mindepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)
				if [[ -z "$latest_path" ]] || [[ ! -f "$latest_path" ]]; then
					echo "[ERROR] $name可执行文件不存在,请检查!"
					return 1
				fi
			fi	
			
			# 安装二进制文件
			install_binary "$latest_path" "$target_path" || return 4
					
			# 清理临时文件
			rm -rf "$output_dir"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${syncthing_config[sys_path]}" || ! -e "${syncthing_config[bin_file]}" ]]; then
			# 安装二进制文件
			install_binary "$target_path" "${syncthing_config[bin_file]}" "/usr/local/bin/$name" || return 4
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	echo "[INFO] 安装${syncthing_config[name]}完成!"
	return 0
}

# 设置 syncthing 配置
set_syncthing_conf()
{
	echo "[INFO] 设置${syncthing_config[name]}配置文件"
	
	if [ ! -f "${syncthing_config[bin_file]}" ]; then
		echo "[ERROR] ${syncthing_config[name]}可执行文件不存在,请检查!"
		return 1
	fi
	
	if [ ! -f "${syncthing_config[conf_file]}" ]; then
		#echo '<?xml version="1.0" encoding="UTF-8"?><configuration version="37"></configuration>' > "${syncthing_config[conf_file]}"

		"${syncthing_config[bin_file]}" generate \
			--home="${syncthing_config[etc_path]}" \
			--gui-user="admin" \
			--gui-password="${syncthing_config[passwd]}"
		if [ $? -ne 0 ]; then
			echo "[ERROR] ${syncthing_config[name]}配置文件生成失败, 请检查!"
			return 1
		fi
	fi
	
	# 等待3次，每次5秒
	for ((retry=3; retry>0; retry--)); do
	  [ -f "${syncthing_config[conf_file]}" ] && break
	  sleep 5
	done
	
	echo "[INFO] 初始化${syncthing_config[name]}配置文件:${syncthing_config[conf_file]}"
	
	# 修改 Syncthing 配置
	if [ -f "${syncthing_config[conf_file]}" ]; then
		# 停止正在运行的进程
		pkill -f "${syncthing_config[bin_file]}"
		sleep 2
		
		# GUI配置
		xmlstarlet ed -L \
			--subnode '/configuration[not(gui)]' -t elem -n 'gui' -v "" \
			--subnode '/configuration/gui[not(address)]' -t elem -n 'address' -v "" \
			--subnode '/configuration/gui[not(tls)]' -t elem -n 'tls' -v "" \
			--subnode '/configuration/gui[not(urlbase)]' -t elem -n 'urlbase' -v "" \
			-u '/configuration/gui/address' -v "0.0.0.0:${syncthing_config[http_port]}" \
			-u '/configuration/gui/tls' -v "false" \
			-u '/configuration/gui/urlbase' -v "/syncthing" \
			"${syncthing_config[conf_file]}" || {
			echo "[ERROR] ${syncthing_config[name]} GUI配置失败, 请检查!"
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
			"listenAddresses:tcp://0.0.0.0:${syncthing_config[trans_port]}, quic://0.0.0.0:${syncthing_config[trans_port]}"
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
			"${syncthing_config[conf_file]}" || {
			echo "[ERROR] ${syncthing_config[name]}全局选项配置失败, 请检查!"
			return 1
		}
			
		# 文件夹配置
		xmlstarlet ed -L --pf \
			-s "/configuration[not(folder[@id='default'])]" -t elem -n "folder" \
			-i "/configuration/folder[last()][not(@id)]" -t attr -n "id" -v "default" \
			-i "/configuration/folder[@id='default'][not(@path)]" -t attr -n "path" -v "${syncthing_config[data_path]}/default" \
			-u "/configuration/folder[@id='default']/@path" -v "${syncthing_config[data_path]}/default" \
			-s "/configuration/folder[@id='default'][not(label)]" -t elem -n "label" -v "默认目录" \
			-s "/configuration/folder[@id='default'][not(minDiskFree)]" -t elem -n "minDiskFree" -v "5" \
			-s "/configuration/folder[@id='default'][not(copiers)]" -t elem -n "copiers" -v "4" \
			-s "/configuration/folder[@id='default'][not(pullerMaxPendingKiB)]" -t elem -n "pullerMaxPendingKiB" -v "102400" \
			"${syncthing_config[conf_file]}" || {
			echo "[ERROR] ${syncthing_config[name]}文件夹配置失败, 请检查!"
			return 1
		}		
	fi
	
	echo "[INFO] 设置${syncthing_config[name]}配置完成!"
	return 0
}

# 设置 syncthing 用户
set_syncthing_user()
{
	echo "[INFO] 设置${syncthing_config[name]}用户权限"
	mkdir -p "${syncthing_config[pid_path]}"
	
	chown -R ${user_config[user]}:${user_config[group]} \
		"${syncthing_config[sys_path]}" \
		"${syncthing_config[etc_path]}" \
		"${syncthing_config[data_path]}" \
		"${syncthing_config[pid_path]}" 2>/dev/null || return 1

	echo "[INFO] 设置${syncthing_config[name]}权限完成!"
	return 0
}

# 设置 syncthing 环境
set_syncthing_env()
{
	local arg=$1
	echo "[INFO] 设置${syncthing_config[name]}服务环境"

	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${syncthing_config[etc_path]}" "${syncthing_config[data_path]}"
		
		# 设置 syncthing 配置
		if ! set_syncthing_conf; then
			return 1
		fi
		
		# 设置 syncthing 用户
		if ! set_syncthing_user; then
			return 1
		fi
	fi

	echo "[INFO] 设置${syncthing_config[name]}完成!"
	return 0
}

# 初始化 syncthing 环境
init_syncthing_service()
{
	local arg=$1
	echo "[INFO] 初始化${syncthing_config[name]}服务"
	
	# 安装 syncthing 环境
	if ! install_syncthing_env "$arg"; then
		return 1
	fi
	
	# 设置 syncthing 环境
	if ! set_syncthing_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${syncthing_config[name]}服务成功!"
	return 0
}

# 运行 syncthing 服务
run_syncthing_service()
{
	echo "[INFO] 运行${syncthing_config[name]}服务"
	
	if [ ! -e "${syncthing_config[bin_file]}" ]; then
		echo "[ERROR] ${syncthing_config[name]}服务运行失败,请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${syncthing_config[pid_path]}/${syncthing_config[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${syncthing_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${syncthing_config[name]}服务已经在运行(PID:$pid), 请检查!"
				return 0
			fi
		fi
	fi
	
	# 后台运行 syncthing 服务		# sudo -u ${SERVICE_APP_USER} --
	nohup "${syncthing_config[bin_file]}" \
			--config "${syncthing_config[etc_path]}" \
			--data "${syncthing_config[data_path]}" \
			--no-browser \
			--gui-address="0.0.0.0:${syncthing_config[http_port]}" \
			> "${syncthing_config[log_file]}" 2>&1 &

	# 获取后台进程的 PID
	local syncthing_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$syncthing_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${syncthing_config[http_port]}" "${syncthing_config[trans_port]}"; then
		echo "[ERROR] ${syncthing_config[name]}端口未就绪，查看服务日志："
		return 1
	fi
	
	echo "$syncthing_pid" > "$pid_file"
	echo "[INFO] 启动${syncthing_config[name]}服务成功!"
}

# 停止 syncthing 服务
close_syncthing_service()
{
	echo "[INFO] 关闭${syncthing_config[name]}服务"
	
	if [ ! -x "${syncthing_config[bin_file]}" ]; then
		echo "[ERROR] ${syncthing_config[name]}服务不存在,请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${syncthing_config[pid_path]}/${syncthing_config[name]}.pid"
	
	# 检查 syncthing 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 syncthing 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${syncthing_config[name]}服务进程:$PID"
			kill "$PID"
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${syncthing_config[name]}); do
		echo "[INFO] ${syncthing_config[name]}服务进程:$PID"
		kill "$PID"
	done
	
	echo "[INFO] 关闭${syncthing_config[name]}服务成功!"
}