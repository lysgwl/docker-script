#!/bin/bash

declare -A filebrowser_config=(
	["name"]="filebrowser"	# 服务名称
	["passwd"]="123456"		# 缺省密码
	["port"]="${FILEBROWSER_PORT:-8080}"					# 端口号
	["etc_path"]="${system_config[config_dir]}/filebrowser"	# 配置目录
	["data_path"]="${system_config[data_dir]}/filebrowser"	# 数据目录
	["sys_path"]="/usr/local/filebrowser"					# 安装路径
	["pid_path"]="/var/run/filebrowser"						# 标识路径
	["bin_file"]="/usr/local/filebrowser/filebrowser"		# 运行文件
	["log_file"]="${system_config[data_dir]}/filebrowser/filebrowser.log"	# 日志文件
	["db_file"]="${system_config[data_dir]}/filebrowser/database.db"		# 数据库文件
	["conf_file"]="${system_config[config_dir]}/filebrowser/config.json"	# 配置文件
)

readonly -A filebrowser_config

# 下载 filebrowser安装包
download_filebrowser()
{
	local downloads_dir=$1
	echo "[INFO] 下载${filebrowser_config[name]}安装包" >&2
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"armv7"}'
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
	
	local name_value="${filebrowser_config[name]}"
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local json_config=$(jq -n \
		--arg type "github" \
		--arg name "$name_value" \
		--arg repo "filebrowser/filebrowser" \
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

# 安装 filebrowser 环境
install_filebrowser_env()
{
	local arg=$1
	echo "[INFO] 安装${filebrowser_config[name]}服务环境"
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	local name="${filebrowser_config[name]}"
	local target_path="$install_dir/$name"
	
	if [ "$arg" = "init" ]; then
		if [ -z "$(find "$install_dir" -maxdepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)" ]; then
			local output_dir="$downloads_dir/output"
			if [ ! -d "$output_dir" ]; then
				mkdir -p "$output_dir"
			fi
			
			local findpath latest_path archive_path
			if ! findpath=$(find_latest_archive "$downloads_dir" ".*${name}.*"); then
				echo "[WARNING] 未匹配到$name软件包..." >&2
				
				# 下载文件并验证
				local download_file
				download_file=$(download_filebrowser "$downloads_dir") && [ -n "$download_file" ] || {
					echo "[ERROR] 下载$name软件包失败,请检查!"
					return 2
				}
				
				archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*${name}.*") || return 3
			else
				# 解析文件类型和路径
				local archive_type=$(jq -r '.filetype' <<< "$findpath")
				archive_path=$(jq -r '.filepath' <<< "$findpath")
				
				# 验证文件类型
				if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
					return 1
				fi
				
				if [ "$archive_type" = "file" ]; then
					archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*${name}.*") || return 3
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
		if [[ ! -d "${filebrowser_config[sys_path]}" && ! -e "${filebrowser_config[bin_file]}" ]]; then
			# 安装二进制文件
			install_binary "$target_path" "${filebrowser_config[bin_file]}" "/usr/local/bin/$name" || return 4
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	echo "[INFO] 安装${filebrowser_config[name]}完成!"
	return 0
}

# 设置 filebrowser 配置文件
set_filebrowser_conf()
{
	echo "[INFO] 设置${filebrowser_config[name]}配置文件"
	
	if [ ! -f "${filebrowser_config[bin_file]}" ]; then
		echo "[ERROR] ${filebrowser_config[name]}可执行文件不存在,请检查!"
		return 1
	fi
	
	# filebrowser 默认配置
	if [ ! -e "${filebrowser_config[conf_file]}" ]; then
		echo "${filebrowser_config[name]}配置文件:${filebrowser_config[conf_file]}"
		
		cat > "${filebrowser_config[etc_path]}/config.json" <<EOF
{
  "port": ${filebrowser_config[port]},
  "address": "0.0.0.0",
  "locale": "zh-cn",
  "log": "${filebrowser_config[log_file]}",
  "database": "${filebrowser_config[db_file]}",
  "root": "${system_config[usr_dir]}",
  "auth": {
    "method": "password",
    "header": ""
  },
  "recaptcha": {
    "key": "",
    "secret": ""
  },
  "baseURL": "",
  "allowCommands": true,
  "allowEdit": true,
  "allowNew": true,
  "commands": [
    "ls",
    "df",
    "git",
    "unzip"
  ],
  "shell": [],
  "rules": [],
  "branding": {
    "name": "文件管理器",
	"files": "",
    "disableExternal": false,
	"loginDescription": "欢迎使用文件管理系统",
	"theme": "dark",
	"color": "#3f51b5"
  },
  "filesystem": {
    "followSymlinks": true,
    "hideDotfiles": true
  }
}
EOF
	fi	
	
	echo "[INFO] 设置${filebrowser_config[name]}配置完成!"
	return 0
}

# 设置 filebrowser 用户
set_filebrowser_user()
{
	echo "[INFO] 设置${filebrowser_config[name]}用户权限"
	mkdir -p "${filebrowser_config[pid_path]}"
	
	chown -R ${user_config[user]}:${user_config[group]} \
		"${filebrowser_config[sys_path]}" \
		"${filebrowser_config[etc_path]}" \
		"${filebrowser_config[data_path]}" \
		"${filebrowser_config[pid_path]}" 2>/dev/null || return 1
	
	echo "[INFO] 设置${filebrowser_config[name]}权限完成!"
	return 0
}

# 设置 filebrowser 环境
set_filebrowser_env()
{
	local arg=$1
	echo "[INFO] 设置${filebrowser_config[name]}服务配置"
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${filebrowser_config[etc_path]}" "${filebrowser_config[data_path]}"
		
		# 设置 filebrowser 配置
		set_filebrowser_conf
		
		# 设置 filebrowser 用户
		if ! set_filebrowser_user; then
			return 1
		fi
	fi
	
	echo "[INFO] 设置${filebrowser_config[name]}完成!"
	return 0
}

# 初始化 filebrowser 服务
init_filebrowser_service()
{
	local arg=$1
	echo "[INFO] 初始化${filebrowser_config[name]}服务"
	
	# 安装 filebrowser 环境
	if ! install_filebrowser_env "$arg"; then
		return 1
	fi
	
	# 设置 filebrowser 环境
	if ! set_filebrowser_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${filebrowser_config[name]}服务成功!"
	return 0
}

# 运行 filebrowser 服务
run_filebrowser_service()
{
	echo "[INFO] 运行${filebrowser_config[name]}服务"
	
	if [ ! -e "${filebrowser_config[bin_file]}" ] && [ ! -e "${filebrowser_config[etc_path]}" ]; then
		echo "[ERROR] ${filebrowser_config[name]}服务运行失败,请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${filebrowser_config[pid_path]}/${filebrowser_config[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${filebrowser_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${filebrowser_config[name]}服务已经在运行!(PID:$pid)"
				return 0
			fi
		fi
	fi
	
	# 后台运行 filebrowser 服务
	if [ ! -f "${filebrowser_config[db_file]}" ]; then
		nohup "${filebrowser_config[bin_file]}" -c "${filebrowser_config[conf_file]}" &> /dev/null &
	else
		nohup "${filebrowser_config[bin_file]}" -d "${filebrowser_config[db_file]}" --disable-preview-resize --disable-exec --disable-type-detection-by-header &> /dev/null &
	fi
	
	# 获取后台进程的 PID
	local filebrowser_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$filebrowser_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${filebrowser_config[port]}"; then
		echo "[ERROR] ${filebrowser_config[name]} 端口未就绪！"
		return 1
	fi

	echo "$filebrowser_pid" > "$pid_file"
	echo "[INFO] 启动${filebrowser_config[name]}服务成功!"
}

# 停止 filebrowser 服务
close_filebrowser_service()
{
	echo "[INFO] 关闭${filebrowser_config[name]}服务"
	
	if [ ! -x "${filebrowser_config[bin_file]}" ]; then
		echo "[ERROR] ${filebrowser_config[name]}服务不存在,请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${filebrowser_config[pid_path]}/${filebrowser_config[name]}.pid"
	
	# 检查 filebrowser 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 filebrowser 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${filebrowser_config[name]}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${filebrowser_config[name]}); do
		echo "[INFO] ${filebrowser_config[name]}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${filebrowser_config[name]}服务成功!"
}