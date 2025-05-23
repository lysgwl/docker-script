#!/bin/bash

# 定义alist配置数组
declare -A alist_config=(
	["name"]="alist"		# 服务名称
	["passwd"]="123456"		# 缺省密码
	["port"]="${ALIST_HTTP_PORT:-5244}"			# 端口号
	["etc_path"]="${system_config[config_dir]}/alist"	# 配置目录
	["data_path"]="${system_config[data_dir]}/alist"	# 数据目录
	["sys_path"]="/usr/local/alist"				# 安装路径
	["pid_path"]="/var/run/alist"				# 进程标识路径
	["pid_file"]="/var/run/alist/alist.pid"		# 进程标识
	["bin_file"]="/usr/local/alist/alist"		# 运行文件
	["conf_file"]="${system_config[config_dir]}/alist/config.json"	# 配置文件
)

readonly -A alist_config

# 下载alist安装包
download_alist()
{
	local downloads_dir=$1
	echo "[INFO] 下载${alist_config[name]}安装包" >&2
	
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
	
	local name_value="${alist_config[name]}"
	name_value+="-musl"
	
	# 检测musl
	if { ldd --version 2>&1 || true; } | grep -q "musl"; then
		matcher_conditions+=("[[ \$name =~ musl ]]")
	fi
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local json_config=$(jq -n \
		--arg type "github" \
		--arg name "$name_value" \
		--arg repo "AlistGo/alist" \
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

# 安装alist环境
install_alist_env()
{
	local arg=$1
	echo "[INFO] 安装${alist_config[name]}服务环境"
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	local name="${alist_config[name]}"
	local target_dir="$install_dir/$name"
	
	local output_dir="$downloads_dir/output"
	if [ ! -d "$output_dir" ]; then
		mkdir -p "$output_dir"
	fi
	
	if [ "$arg" = "init" ]; then
		if [ -z "$(find "$install_dir" -maxdepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)" ]; then
			local findpath latest_path  download_file
			if ! findpath=$(find_latest_archive "$downloads_dir" "${name}.*"); then
				echo "[WARNING] 未匹配到$name软件包..." >&2
				
				download_file=$(download_alist "$downloads_dir") && [ -n "$download_file" ] || {
					echo "[ERROR] 下载$name软件包失败,请检查!"
					return 2
				}
				
				latest_path=$(extract_and_validate "$download_file" "$output_dir" "${name}.*") || return 3
			else
				local archive_type=$(jq -r '.filetype' <<< "$findpath")
				local archive_path=$(jq -r '.filepath' <<< "$findpath")
				
				if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
					return 1
				fi
				
				if [ "$archive_type" = "file" ]; then
					latest_path=$(extract_and_validate "$archive_path" "$output_dir" "${name}.*") || return 3
				else
					local filepath=$(find "$archive_path" -maxdepth 1 -mindepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)
					if [[ -z "$filepath" ]]; then
						echo "[ERROR] $name可执行文件不存在,请检查!"
						return 1
					fi
					
					local archive_name=$(basename "$filepath")
					if [ ! -d "$output_dir/$archive_name" ]; then
						mkdir -p "$output_dir"
						rsync -a --no-relative "$filepath" "$output_dir/"
					fi
					
					latest_path="$output_dir/$archive_name"
				fi
			fi
			
			# 安装二进制文件
			install_binary "$latest_path" "$target_dir" || return 4
					
			# 清理临时文件
			rm -rf  "$latest_path" "$output_dir"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${alist_config[sys_path]}" && ! -e "${alist_config[bin_file]}" ]]; then
			# 安装二进制文件
			install_binary "$target_dir" "${alist_config[bin_file]}" "/usr/local/bin/$name" || return 4
		fi
	fi

	echo "[INFO] 安装${alist_config[name]}完成!"
	return 0
}

# 设置alist配置
set_alist_conf()
{
	echo "[INFO] 设置${alist_config[name]}配置文件"
	local jwt_secret=`openssl rand -base64 12`

	local tmp_dir="${alist_config[data_path]}/temp"
	if [ ! -d "$tmp_dir" ]; then
		mkdir -p "$tmp_dir"
	fi
	
	local bleve_dir="${alist_config[data_path]}/bleve"
	if [ ! -d "$bleve_dir" ]; then
		mkdir -p "$bleve_dir"
	fi
	
	local log_dir="${alist_config[data_path]}/log"
	if [ ! -d "$log_dir" ]; then
		mkdir -p "$log_dir"
	fi
	
	local db_file="${alist_config[data_path]}/data.db"
	local log_file="$log_dir/log.log"
	
	# alist 默认配置
	if [ ! -e "${alist_config[conf_file]}" ]; then
		echo "${alist_config[name]}配置文件:${alist_config[conf_file]}"
		
		cat <<EOF > "${alist_config[conf_file]}"
{
  "force": false,
  "site_url": "/${alist_config[name]}",
  "cdn": "",
  "jwt_secret": "$jwt_secret",
  "token_expires_in": 48,
  "database": {
    "type": "sqlite3",
    "host": "",
    "port": 0,
    "user": "",
    "password": "",
    "name": "",
    "db_file": "$db_file",
    "table_prefix": "x_",
    "ssl_mode": "",
    "dsn": ""
  },
  "meilisearch": {
    "host": "http://localhost:7700",
    "api_key": "",
    "index_prefix": ""
  },
  "scheme": {
    "address": "0.0.0.0",
    "http_port": ${alist_config[port]},
    "https_port": -1,
    "force_https": false,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": ""
  },
  "temp_dir": "$tmp_dir",
  "bleve_dir": "$bleve_dir",
  "dist_dir": "",
  "log": {
    "enable": true,
    "name": "$log_file",
    "max_size": 50,
    "max_backups": 30,
    "max_age": 28,
    "compress": false
  },
  "delayed_start": 0,
  "max_connections": 0,
  "max_concurrency": 64,
  "tls_insecure_skip_verify": true,
  "tasks": {
    "download": {
      "workers": 5,
      "max_retry": 1,
      "task_persistant": false
    },
    "transfer": {
      "workers": 5,
      "max_retry": 2,
      "task_persistant": false
    },
    "upload": {
      "workers": 5,
      "max_retry": 0,
      "task_persistant": false
    },
    "copy": {
      "workers": 5,
      "max_retry": 2,
      "task_persistant": false
    },
    "decompress": {
      "workers": 5,
      "max_retry": 2,
      "task_persistant": false
    },
    "decompress_upload": {
      "workers": 5,
      "max_retry": 2,
      "task_persistant": false
    },
    "allow_retry_canceled": false
  },
  "cors": {
    "allow_origins": [
      "*"
    ],
    "allow_methods": [
      "*"
    ],
    "allow_headers": [
      "*"
    ]
  },
  "s3": {
    "enable": false,
    "port": 5246,
    "ssl": false
  },
  "ftp": {
    "enable": false,
    "listen": ":5221",
    "find_pasv_port_attempts": 50,
    "active_transfer_port_non_20": false,
    "idle_timeout": 900,
    "connection_timeout": 30,
    "disable_active_mode": false,
    "default_transfer_binary": false,
    "enable_active_conn_ip_check": true,
    "enable_pasv_conn_ip_check": true
  },
  "sftp": {
    "enable": false,
    "listen": ":5222"
  },
  "last_launched_version": "AList version"
}
EOF
	fi
	
	echo "[INFO] 设置${alist_config[name]}配置完成!"
}

# 设置alist用户
set_alist_user()
{
	echo "[INFO] 设置${alist_config[name]}用户权限"
	mkdir -p "${alist_config[pid_path]}"
	
	chown -R ${user_config[user]}:${user_config[group]} \
		"${alist_config[sys_path]}" \
		"${alist_config[etc_path]}" \
		"${alist_config[data_path]}" \
		"${alist_config[pid_path]}" 2>/dev/null || return 1

	echo "[INFO] 设置${alist_config[name]}权限完成!"
	return 0
}

# 设置alist环境
set_alist_env()
{
	local arg=$1
	echo "[INFO] 设置${alist_config[name]}服务配置"
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${alist_config[etc_path]}" "${alist_config[data_path]}"
		
		# 设置alist配置
		set_alist_conf
		
		# 设置alist用户
		if ! set_alist_user; then
			return 1
		fi
		
		if [ ! -f "${alist_config[bin_file]}" ]; then
			echo "[ERROR] ${alist_config[name]}可执行文件不存在,请检查!"
			return 1
		fi
		
		# 查看alist管理员密码
		su-exec ${user_config[user]} "${alist_config[bin_file]}" admin --data "${alist_config[etc_path]}"

		# 设置alist缺省密码	
		su-exec ${user_config[user]} "${alist_config[bin_file]}" admin --data "${alist_config[etc_path]}" set "${alist_config[passwd]}"
	fi

	echo "[INFO] 设置${alist_config[name]}完成!"
	return 0
}

# 初始化alist环境
init_alist_env()
{
	local arg=$1
	echo "[INFO] 初始化${alist_config[name]}服务"
	
	# 安装alist环境
	if ! install_alist_env "$arg"; then
		return 1
	fi
	
	# 设置alist环境
	if ! set_alist_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${alist_config[name]}服务成功!"
	return 0
}

# 运行alist服务
run_alist_service()
{
	echo "[INFO] 运行${alist_config[name]}服务"
	
	if [ ! -e "${alist_config[bin_file]}" ] && [ ! -e "${alist_config[etc_path]}" ]; then
		echo "[ERROR] ${alist_config[name]}服务运行失败,请检查!"
		return 1
	fi
	
	# 检查服务是否已运行
	if [ -f "${alist_config[pid_file]}" ]; then
		local pid=$(cat "${alist_config[pid_file]}")
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "${alist_config[pid_file]}"
		else
			if ! grep -qF "${alist_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "${alist_config[pid_file]}"
			else
				echo "[WARNING] ${alist_config[name]}服务已经在运行!(PID:$pid)"
				return 0
			fi
		fi
	fi
	
	# 后台运行alist服务
	nohup "${alist_config[bin_file]}" server --data "${alist_config[etc_path]}" &> /dev/null &
	
	# 获取后台进程的 PID
	local alist_pid=$!
	
	# 等待 2 秒
	sleep 2
	
	# 验证 PID 有效性
	if ! kill -0 "$alist_pid" >/dev/null; then
        echo "[ERROR] ${alist_config[name]}服务启动失败, 请检查!"
        return 1
    fi
	
	# 启动端口检测
	if ! wait_for_ports "${alist_config[port]}"; then
        echo "[ERROR] ${alist_config[name]} 端口未就绪！"
        return 1
    fi

	echo "$alist_pid" > "${alist_config[pid_file]}"
	echo "[INFO] 启动${alist_config[name]}服务成功!"
}

# 停止alist服务
close_alist_service()
{
	echo "[INFO] 关闭${alist_config[name]}服务"
	
	if [ ! -x "${alist_config[bin_file]}" ]; then
		echo "[ERROR] ${alist_config[name]}服务不存在,请检查!"
		return
	fi
	
	# 检查alist服务进程
	if [ -e "${alist_config[pid_file]}" ]; then
		# 关闭alist服务进程
		for PID in $(cat "${alist_config[pid_file]}"); do
			echo "[INFO] ${alist_config[name]}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "${alist_config[pid_file]}"
	fi
	
	for PID in $(pidof ${alist_config[name]}); do
		echo "[INFO] ${alist_config[name]}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${alist_config[name]}服务成功!"
}