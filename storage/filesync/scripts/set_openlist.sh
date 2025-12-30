#!/bin/bash

# 定义 openlist 配置数组
declare -A OPENLIST_CONFIG=(
	["name"]="openlist"		# 服务名称
	["passwd"]="123456"		# 缺省密码
	["port"]="${ALIST_HTTP_PORT:-5244}"						# 端口号
	["etc_path"]="${SYSTEM_CONFIG[config_dir]}/openlist"	# 配置目录
	["data_path"]="${SYSTEM_CONFIG[data_dir]}/openlist"		# 数据目录
	["sys_path"]="/usr/local/openlist"						# 安装路径
	["pid_path"]="/var/run/openlist"						# 标识路径
	["bin_file"]="/usr/local/openlist/openlist"				# 运行文件
	["log_file"]="${SYSTEM_CONFIG[data_dir]}/openlist/openlist.log"			# 日志文件
	["db_file"]="${SYSTEM_CONFIG[data_dir]}/openlist/database.db"			# 数据库文件
	["conf_file"]="${SYSTEM_CONFIG[config_dir]}/openlist/config.json"		# 配置文件
)

readonly -A OPENLIST_CONFIG

# 下载 openlist 安装包
download_openlist()
{
	print_log "TRACE" "下载 ${OPENLIST_CONFIG[name]} 安装包" >&2
	
	local downloads_dir=$1
	local name="${OPENLIST_CONFIG[name]}-musl"
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"armv7"}'
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

	# 检测 musl
	if { ldd --version 2>&1 || true; } | grep -q "musl"; then
		matcher_conditions+=("[[ \$name =~ musl ]]")
	fi
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local json_config=$(jq -n \
		--arg type "github" \
		--arg name "$name" \
		--arg repo "OpenListTeam/OpenList" \
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

# 安装 openlist 环境
install_openlist_env()
{
	print_log "TRACE" "安装 ${OPENLIST_CONFIG[name]} 服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/${OPENLIST_CONFIG[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${OPENLIST_CONFIG[name]}" "$downloads_dir" download_openlist) || {
				print_log "ERROR" "获取 ${OPENLIST_CONFIG[name]} 安装包失败, 请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				print_log "ERROR" "安装 ${OPENLIST_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${OPENLIST_CONFIG[sys_path]}" && ! -e "${OPENLIST_CONFIG[bin_file]}" ]]; then
			local install_dir=$(dirname "${OPENLIST_CONFIG[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				print_log "ERROR" "安装 ${OPENLIST_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${OPENLIST_CONFIG[bin_file]}" "" "$install_dir/bin/${OPENLIST_CONFIG[name]}" || {
				print_log "ERROR" "创建 ${OPENLIST_CONFIG[name]} 符号链接失败, 请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	print_log "INFO" "安装 ${OPENLIST_CONFIG[name]} 完成!"
	return 0
}

# 设置 openlist 配置
set_openlist_conf()
{
	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 配置文件"
	local jwt_secret=`openssl rand -base64 12 | tr -dc 'a-zA-Z'`

	local tmp_dir="${OPENLIST_CONFIG[data_path]}/temp"
	if [ ! -d "$tmp_dir" ]; then
		mkdir -p "$tmp_dir"
	fi
	
	local bleve_dir="${OPENLIST_CONFIG[data_path]}/bleve"
	if [ ! -d "$bleve_dir" ]; then
		mkdir -p "$bleve_dir"
	fi
	
	print_log "INFO" "初始化 ${OPENLIST_CONFIG[name]} 配置文件:${OPENLIST_CONFIG[conf_file]}"

	# openlist 默认配置
	if [ ! -e "${OPENLIST_CONFIG[conf_file]}" ]; then
		cat <<EOF > "${OPENLIST_CONFIG[conf_file]}"
{
  "force": false,
  "site_url": "/${OPENLIST_CONFIG[name]}",
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
    "db_file": "${OPENLIST_CONFIG[db_file]}",
    "table_prefix": "x_",
    "ssl_mode": "",
    "dsn": ""
  },
  "meilisearch": {
    "host": "http://localhost:7700",
    "api_key": "",
    "index": "openlist"
  },
  "scheme": {
    "address": "0.0.0.0",
    "http_port": ${OPENLIST_CONFIG[port]},
    "https_port": -1,
    "force_https": false,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": "",
    "enable_h2c": false
  },
  "temp_dir": "$tmp_dir",
  "bleve_dir": "$bleve_dir",
  "dist_dir": "",
  "log": {
    "enable": true,
    "name": "${OPENLIST_CONFIG[log_file]}",
    "max_size": 50,
    "max_backups": 30,
    "max_age": 28,
    "compress": false,
    "filter": {
      "enable": false,
      "filters": [
        {
          "cidr": "",
          "path": "/ping",
          "method": ""
        },
        {
          "cidr": "",
          "path": "",
          "method": "HEAD"
        },
        {
          "cidr": "",
          "path": "/dav/",
          "method": "PROPFIND"
        }
      ]
    }
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
  "last_launched_version": "openlist version"
}
EOF
	fi

	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 配置完成!"
}

# 设置 openlist 用户
set_openlist_user()
{
	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 用户权限"
	mkdir -p "${OPENLIST_CONFIG[pid_path]}"

	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
		"${OPENLIST_CONFIG[sys_path]}" \
		"${OPENLIST_CONFIG[etc_path]}" \
		"${OPENLIST_CONFIG[data_path]}" \
		"${OPENLIST_CONFIG[pid_path]}" 2>/dev/null || return 1

	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 权限完成!"
	return 0
}

# 设置 openlist 环境
set_openlist_env()
{
	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 服务配置"
	local arg=$1
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${OPENLIST_CONFIG[etc_path]}" "${OPENLIST_CONFIG[data_path]}"
		
		# 设置 openlist 配置
		set_openlist_conf
		
		# 设置 openlist 用户
		if ! set_openlist_user; then
			return 1
		fi
		
		if [ ! -f "${OPENLIST_CONFIG[bin_file]}" ]; then
			print_log "ERROR" "${OPENLIST_CONFIG[name]} 可执行文件不存在,请检查!" >&2
			return 1
		fi
		
		# 查看 openlist 管理员密码
		su-exec ${USER_CONFIG[user]} "${OPENLIST_CONFIG[bin_file]}" admin --data "${OPENLIST_CONFIG[etc_path]}"

		# 设置 openlist 缺省密码	
		su-exec ${USER_CONFIG[user]} "${OPENLIST_CONFIG[bin_file]}" admin --data "${OPENLIST_CONFIG[etc_path]}" set "${OPENLIST_CONFIG[passwd]}"
	fi

	print_log "TRACE" "设置 ${OPENLIST_CONFIG[name]} 完成!"
	return 0
}

# 初始化 openlist 环境
init_openlist_service()
{
	print_log "TRACE" "初始化 ${OPENLIST_CONFIG[name]} 服务"
	local arg=$1
	
	# 安装 openlist 环境
	if ! install_openlist_env "$arg"; then
		return 1
	fi
	
	# 设置 openlist 环境
	if ! set_openlist_env "$arg"; then
		return 1
	fi
	
	print_log "TRACE" "初始化 ${OPENLIST_CONFIG[name]} 服务成功!"
	return 0
}

# 运行 openlist 服务
run_openlist_service()
{
	print_log "TRACE" "运行 ${OPENLIST_CONFIG[name]} 服务"
	
	if [ ! -e "${OPENLIST_CONFIG[bin_file]}" ] && [ ! -e "${OPENLIST_CONFIG[etc_path]}" ]; then
		print_log "ERROR" "运行 ${OPENLIST_CONFIG[name]} 服务失败, 请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${OPENLIST_CONFIG[pid_path]}/${OPENLIST_CONFIG[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${OPENLIST_CONFIG[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				print_log "WARNING" "${OPENLIST_CONFIG[name]} 服务已经在运行!(PID:$pid)"
				return 0
			fi
		fi
	fi
	
	# 后台运行 openlist 服务
	nohup "${OPENLIST_CONFIG[bin_file]}" server --data "${OPENLIST_CONFIG[etc_path]}" &> /dev/null &
	
	# 获取后台进程的 PID
	local openlist_pid=$!
	
	# 等待 PID 生效
	if ! wait_for_pid 10 "$openlist_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${OPENLIST_CONFIG[port]}"; then
		print_log "ERROR" "${OPENLIST_CONFIG[name]} 端口未就绪!"
		return 1
	fi

	echo "$openlist_pid" > "$pid_file"
	print_log "TRACE" "启动 ${OPENLIST_CONFIG[name]} 服务成功!"
}

# 更新 openlist 服务
update_openlist_service()
{
	print_log "TRACE" "更新 ${OPENLIST_CONFIG[name]} 服务"
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${OPENLIST_CONFIG[sys_path]}"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${OPENLIST_CONFIG[name]}" "$downloads_dir" download_openlist) || {
		print_log "ERROR" "获取 ${OPENLIST_CONFIG[name]} 安装包失败!"
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${OPENLIST_CONFIG[bin_file]}" ]; then
		install_binary "$latest_path" "$install_dir" "/usr/local/bin/${OPENLIST_CONFIG[name]}" || {
			print_log "ERROR" "安装 ${OPENLIST_CONFIG[name]} 失败!"
			return 2
		}
		
		rm -rf "$downloads_dir/output"
		return 0
	fi
	
	local current_version=$(${OPENLIST_CONFIG[bin_file]} version | awk '/^Version:/ {print $2}' | tr -d 'v')
	local new_version=$($latest_path version | awk '/^Version:/ {print $2}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?

	case $result in
		0)
			print_log "INFO" "${OPENLIST_CONFIG[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 openlist 运行
			close_openlist_service
			
			# 安装软件包
			install_binary "$latest_path" "$install_dir" || {
				print_log "ERROR" "更新 ${OPENLIST_CONFIG[name]} 失败!"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			print_log "INFO" "${OPENLIST_CONFIG[name]} 已更新至 v$new_version"
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

# 停止 openlist 服务
close_openlist_service()
{
	print_log "TRACE" "关闭 ${OPENLIST_CONFIG[name]} 服务"
	
	if [ ! -x "${OPENLIST_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${OPENLIST_CONFIG[name]} 服务不存在, 请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${OPENLIST_CONFIG[pid_path]}/${OPENLIST_CONFIG[name]}.pid"
	
	# 检查 openlist 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 openlist 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			print_log "INFO" "${OPENLIST_CONFIG[name]} 服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${OPENLIST_CONFIG[name]}); do
		print_log "INFO" "${OPENLIST_CONFIG[name]} 服务进程:${PID}"
		kill $PID
	done

	print_log "TRACE" "关闭 ${OPENLIST_CONFIG[name]} 服务成功!"
}