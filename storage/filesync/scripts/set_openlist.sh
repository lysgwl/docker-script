#!/bin/bash

# 下载 openlist 安装包
download_openlist()
{
	logger "INFO" "[openlist] 下载服务安装包" >&2
	
	local downloads_dir=$1
	local name="openlist-musl"
	
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"armv7"}'
	local mapped_arch=$(jq -r ".\"${SYSTEM_CONFIG[arch]}\" // empty" <<< "$arch_map")
	
	if [[ -z "$mapped_arch" ]]; then
		logger "ERROR" "[openlist] 不支持的架构 ${SYSTEM_CONFIG[arch]}, 请检查!" >&2
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
		logger "ERROR" "[openlist] 下载服务文件失败, 请检查!" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 openlist 环境
install_openlist_env()
{
	logger "INFO" "[openlist] 安装服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/${openlist_cfg[name]}"
	if [[ "$arg" = "init" ]]; then
		if [[ ! -d "$target_path" ]]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${openlist_cfg[name]}" "$downloads_dir" download_openlist) || {
				logger "ERROR" "[openlist] 获取服务安装包失败, 请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				logger "ERROR" "[openlist] 安装服务失败, 请检查!" >&2
				return 2
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [[ "$arg" = "config" ]]; then
		if [[ ! -d "${openlist_cfg[sys_path]}" && ! -e "${openlist_cfg[bin_file]}" ]]; then
			local install_dir=$(dirname "${openlist_cfg[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				logger "ERROR" "[openlist] 安装服务失败, 请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${openlist_cfg[bin_file]}" "" "${openlist_cfg[symlink_file]}" || {
				logger "ERROR" "[openlist] 创建服务符号链接失败, 请检查!" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	logger "INFO" "[openlist] 服务安装完成"
}

# 设置 openlist 用户
set_openlist_user()
{
	logger "INFO" "[openlist] 设置服务用户权限"
	
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	# 获取相关路径
	local sys_path="${openlist_cfg[sys_path]}"
	local etc_path="${openlist_cfg[etc_path]}"
	local data_path="${openlist_cfg[data_path]}"
	
	chown -R "$user:$group" \
		"${sys_path}" \
		"${etc_path}" \
		"${data_path}" 2>/dev/null || return 1
		
	# 获取 PID 文件路径
	local pid_file=$(get_service_pid_file "openlist")
	if [[ -n "$pid_file" ]]; then
		chown "$user:$group" "$pid_file" 2>/dev/null || true
		chmod 666 "$pid_file" 2>/dev/null || true
	fi
	
	# 获取可执行文件路径
	local bin_file="${openlist_cfg[bin_file]}"
	if [[ -n "$bin_file" && -f "$bin_file" ]]; then
		local passwd="${openlist_cfg[passwd]}"
		
		# 查看 openlist 管理员密码
		su-exec $user "$bin_file" admin --data "$etc_path"
		
		# 设置 openlist 缺省密码
		su-exec  $user "$bin_file" admin --data "$etc_path" set "$passwd"
	fi
	
	logger "INFO" "[openlist] 服务权限完成"
}

# 设置 openlist 配置
set_openlist_conf()
{
	logger "INFO" "[openlist] 设置服务配置文件"
	local jwt_secret=`openssl rand -base64 12 | tr -dc 'a-zA-Z'`
	
	local tmp_dir="${openlist_cfg[data_path]}/temp"
	[[ ! -d "$tmp_dir" ]] && mkdir -p "$tmp_dir"
	
	local bleve_dir="${openlist_cfg[data_path]}/bleve"
	[[ ! -d "$bleve_dir" ]] && mkdir -p "$bleve_dir"
	
	local db_file="${openlist_cfg[db_file]}"
	local conf_file="${openlist_cfg[conf_file]}"
	
	local http_port="${openlist_cfg[port]}"
	local log_file=$(get_service_log_file "openlist")
	
	logger "INFO" "[openlist] 服务配置文件: $conf_file"
	
	# openlist 默认配置
	if [[ ! -e "$conf_file" ]]; then
		cat <<EOF > "$conf_file"
{
  "force": false,
  "site_url": "/openlist",
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
    "index": "openlist"
  },
  "scheme": {
    "address": "0.0.0.0",
    "http_port": $http_port,
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
    "name": "$log_file",
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
	
	logger "INFO" "[openlist] 服务配置完成"
}

# 设置 openlist 路径
set_openlist_paths()
{
	logger "INFO" "[openlist] 设置服务环境目录"
	
	# 获取 PID 文件路径
	local pid_file=$(get_service_pid_file "openlist")
	if [[ -z "$pid_file" ]]; then
		logger "ERROR" "[openlist] 无法获取服务的 PID 文件"
		return 1
	fi
	
	# 提取 PID 文件所在目录
	local pid_dir=$(dirname "$pid_file")
	mkdir -p "$pid_dir" || {
		logger "ERROR" "[openlist] 无法创建 PID 目录: $pid_dir"
		return 1
	}
	
	# 创建 PID 文件
	touch "$pid_file" || {
		logger "ERROR" "[openlist] 无法创建 PID 文件: $pid_file"
		return 1
	}
	
	# 获取其他配置路径
	local sys_path="${openlist_cfg[sys_path]}"
	local etc_path="${openlist_cfg[etc_path]}"
	local data_path="${openlist_cfg[data_path]}"
	
	mkdir -p \
		"${sys_path}" \
		"${etc_path}" \
		"${data_path}"
	
	logger "INFO" "[openlist] 设置目录完成"
}

# 设置 openlist 环境
set_openlist_env()
{
	logger "INFO" "[openlist] 设置服务环境"

	if [[ "$1" = "config" ]]; then
		# 创建环境目录
		if ! set_openlist_paths; then
			logger "ERROR" "[openlist] 设置环境路径失败"
			return 1
		fi
		
		# 设置 openlist 配置
		set_openlist_conf
		
		# 设置 openlist 用户
		if ! set_openlist_user; then
			logger "ERROR" "[openlist] 设置服务用户权限失败"
			return 2
		fi
	fi
	
	logger "INFO" "[openlist] 设置服务完成"
}

# 设置 openlist 模板
set_openlist_template()
{
	# 获取配置路径
	local data_dir="${SYSTEM_CONFIG[data_dir]}/openlist"
	local etc_dir="${SYSTEM_CONFIG[config_dir]}/openlist"
	local sys_dir="/usr/local/openlist"
	local bin_file="${sys_dir}/openlist"
	local symlink_file="/usr/local/bin/openlist"
	
	local openlist_json=$(jq -n \
		--arg name "openlist" \
		--arg passwd "123456" \
		--argjson port "${ALIST_HTTP_PORT:-5244}" \
		--arg etc "${etc_dir}" \
		--arg data "${data_dir}" \
		--arg sys "${sys_dir}" \
		--arg bin "${bin_file}" \
		--arg symlink "${symlink_file}" \
		--arg database "${data_dir}/database.db" \
		--arg conf "${etc_dir}/config.json" \
		'{
			name: $name,
			passwd: $passwd,
			port: $port,
			etc_path: $etc,
			data_path: $data,
			sys_path: $sys,
			bin_file: $bin,
			symlink_file: $symlink,
			db_file: $database,
			conf_file: $conf
		}')
		
	local pid_file="/var/run/openlist.pid"
	local log_file="${data_dir}/openlist.log"
		
	import_service_config "openlist" "$pid_file" "$log_file" "$openlist_json"
	return $?
}

# 初始化 openlist 环境
init_openlist_service()
{
	logger "INFO" "[openlist] 初始化服务"
	
	# 设置 openlist 模板
	if ! set_openlist_template; then
		logger "ERROR" "[openlist] 设置模板失败"
		return 1
	fi
	
	# 获取服务配置
	get_service_config "openlist" "config" "openlist_cfg" || {
		logger "ERROR" "[openlist] 无法获取服务配置"
		return 2
	}
	
	# 安装 openlist 环境
	if ! install_openlist_env "$1"; then
		logger "ERROR" "[openlist] 安装环境失败"
		return 3
	fi
	
	# 设置 openlist 环境
	if ! set_openlist_env "$1"; then
		logger "ERROR" "[openlist] 设置环境失败"
		return 4
	fi
	
	logger "INFO" "[openlist] ✓ 初始化服务完成"
}

# 运行 openlist 服务
run_openlist_service()
{
	logger "INFO" "[openlist] 运行服务"
	
	# 获取服务配置
	get_service_config "openlist" "config" "openlist_cfg" || {
		logger "ERROR" "[openlist] 无法获取服务配置"
		return 1
	}
	
	local bin_file="${openlist_cfg[bin_file]}"
	local etc_path="${openlist_cfg[etc_path]}"
	local http_port="${openlist_cfg[port]}"
	
	[[ ! -f "$bin_file" ]] && { logger "ERROR" "[openlist] 可执行文件不存在"; return 1; }
	[[ ! -d "$etc_path" ]] && { logger "ERROR" "[openlist] 配置目录不存在"; return 1; }
	
	# 检查是否已运行
	if check_service_alive "openlist"; then
		logger "WARNING" "[openlist] 检测服务已经在运行!"
		return 0
	fi
	
	# 清理PID文件
	local pid_file=$(get_service_pid_file "openlist")
	echo "" > "$pid_file"
	
	# 启动服务
	"$bin_file" server --data "$etc_path" &> /dev/null &
	local openlist_pid=$!
	
	# 等待进程
	wait_for_pid 5 "$openlist_pid" || {
		logger "ERROR" "[openlist] 进程启动失败!"
		return 2
	}
	# 端口检测
	if ! wait_for_ports "$http_port"; then
		logger "ERROR" "[openlist] 检测服务端口未就绪!"
		return 3
	fi

	echo "$openlist_pid" > "$pid_file"
	update_service_pid "openlist" "$openlist_pid"
	
	logger "INFO" "[openlist] ✓ 启动服务完成!"
}

# 更新 openlist 服务
update_openlist_service()
{
	logger "INFO" "[openlist] 开始检查更新"
	
	# 获取服务配置
	get_service_config "openlist" "config" "openlist_cfg" || {
		logger "ERROR" "[openlist] 无法获取服务配置"
		return 1
	}
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${openlist_cfg[sys_path]}"
	local bin_file="${openlist_cfg[bin_file]}"
	local symlink_file="${openlist_cfg[symlink_file]:-}"
	
	# 检查更新目录是否存在
	if [[ ! -d "$downloads_dir" ]]; then
		logger "ERROR" "[openlist] 更新目录不存在: $downloads_dir"
		return 1
	fi
	
	# 获取更新包
	local latest_path
	latest_path=$(get_service_archive "${openlist_cfg[name]}" "$downloads_dir" download_openlist) || {
		logger "ERROR" "[openlist] 下载更新包失败"
		return 2
	}
	
	# 版本检查
	if [[ -f "$bin_file" ]] && [[ -x "$bin_file" ]]; then
		local current_version new_version
		
		current_version=$("$bin_file" version 2>/dev/null | awk '/^Version:/ {print $2}' | tr -d 'v')
		new_version=$("$latest_path" version 2>/dev/null | awk '/^Version:/ {print $2}' | tr -d 'v')
		
		if [[ -z "$current_version" ]] || [[ -z "$new_version" ]]; then
			logger "WARNING" "[openlist] 无法获取版本信息, 强制更新"
		else
			# 版本比较
			compare_versions "$new_version" "$current_version"
			local result=$?
			
			case $result in
				0)	# 版本相同
					logger "INFO" "[openlist] 已是最新版本 (v$current_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
				2)	# 当前版本更高
					logger "WARNING" "[openlist] 当前版本更高 (v$current_version > v$new_version)"
					rm -rf "$downloads_dir/output" 2>/dev/null
					return 0
					;;
			esac
			
			logger "INFO" "[openlist] 发现新版本: v$current_version → v$new_version"
		fi
		
		# 停止运行中的服务
		if check_service_alive "openlist"; then
			logger "INFO" "[openlist] 停止运行中的服务"
			close_openlist_service
			sleep 2
		fi
	fi
	
	# 执行更新
	install_binary "$latest_path" "$install_dir" "$symlink_file" || {
		logger "ERROR" "[openlist] 更新安装失败"
		return 3
	}
	
	# 清理临时文件
	[[ -d "$downloads_dir/output" ]] && rm -rf "$downloads_dir/output"
	
	logger "INFO" "[openlist] ✓ 更新完成"
}

# 停止 openlist 服务
close_openlist_service()
{
	logger "INFO" "[openlist] 开始停止服务"
	
	# 标识文件
	local pid_file=$(get_service_pid_file "openlist")
	
	# 获取PID
	local pid=$(get_service_pid "openlist" 2>/dev/null)
	[[ -z "$pid" && -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null)
	
	# 停止服务
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		logger "INFO" "[openlist] 停止进程 (PID: $pid)"
		
		# 优雅停止
		kill -TERM "$pid" 2>/dev/null
		
		# 等待最多5秒
		for i in {1..5}; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		
		# 强制停止
		if kill -0 "$pid" 2>/dev/null; then
			logger "WARNING" "[openlist] 进程未响应, 强制停止"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	
	# 清理PID文件
	rm -f "$pid_file" 2>/dev/null
	update_service_pid "openlist" "null"
	
	logger "INFO" "[openlist] ✓ 服务已停止"
}