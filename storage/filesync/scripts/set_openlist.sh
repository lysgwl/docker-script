#!/bin/bash

# 定义 openlist 配置数组
declare -A openlist_config=(
	["name"]="openlist"		# 服务名称
	["passwd"]="123456"		# 缺省密码
	["port"]="${ALIST_HTTP_PORT:-5244}"						# 端口号
	["etc_path"]="${system_config[config_dir]}/openlist"	# 配置目录
	["data_path"]="${system_config[data_dir]}/openlist"		# 数据目录
	["sys_path"]="/usr/local/openlist"						# 安装路径
	["pid_path"]="/var/run/openlist"						# 标识路径
	["bin_file"]="/usr/local/openlist/openlist"				# 运行文件
	["log_file"]="${system_config[data_dir]}/openlist/openlist.log"			# 日志文件
	["db_file"]="${system_config[data_dir]}/openlist/database.db"			# 数据库文件
	["conf_file"]="${system_config[config_dir]}/openlist/config.json"		# 配置文件
)

readonly -A openlist_config

# 下载 openlist 安装包
download_openlist()
{
	local downloads_dir=$1
	echo "[INFO] 下载${openlist_config[name]}安装包" >&2
	
	local name="${openlist_config[name]}-musl"
	
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
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 openlist 环境
install_openlist_env()
{
	local arg=$1
	echo "[INFO] 安装${openlist_config[name]}服务环境"
	
	local target_path="${system_config[install_dir]}/${openlist_config[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${system_config[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${openlist_config[name]}" "$downloads_dir" download_openlist) || {
				echo "[ERROR] 获取 ${openlist_config[name]} 安装包失败,请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				echo "[ERROR] 安装 ${openlist_config[name]} 失败,请检查!" >&2
				return 2
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${openlist_config[sys_path]}" && ! -e "${openlist_config[bin_file]}" ]]; then
			local install_dir=$(dirname "${openlist_config[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				echo "[ERROR] 安装 ${openlist_config[name]} 失败,请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${openlist_config[bin_file]}" "" "$install_dir/bin/${openlist_config[name]}" || {
				echo "[ERROR] 创建 ${openlist_config[name]} 符号链接失败,请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	echo "[INFO] 安装${openlist_config[name]}完成!"
	return 0
}

# 设置 openlist 配置
set_openlist_conf()
{
	echo "[INFO] 设置${openlist_config[name]}配置文件"
	local jwt_secret=`openssl rand -base64 12 | tr -dc 'a-zA-Z'`

	local tmp_dir="${openlist_config[data_path]}/temp"
	if [ ! -d "$tmp_dir" ]; then
		mkdir -p "$tmp_dir"
	fi
	
	local bleve_dir="${openlist_config[data_path]}/bleve"
	if [ ! -d "$bleve_dir" ]; then
		mkdir -p "$bleve_dir"
	fi
	
	echo "[INFO] 初始化${openlist_config[name]}配置文件:${openlist_config[conf_file]}"
	
	# openlist 默认配置
	if [ ! -e "${openlist_config[conf_file]}" ]; then
		cat <<EOF > "${openlist_config[conf_file]}"
{
  "force": false,
  "site_url": "/${openlist_config[name]}",
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
    "db_file": "${openlist_config[db_file]}",
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
    "http_port": ${openlist_config[port]},
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
    "name": "${openlist_config[log_file]}",
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
	
	echo "[INFO] 设置${openlist_config[name]}配置完成!"
}

# 设置 openlist 用户
set_openlist_user()
{
	echo "[INFO] 设置${openlist_config[name]}用户权限"
	mkdir -p "${openlist_config[pid_path]}"

	chown -R ${user_config[user]}:${user_config[group]} \
		"${openlist_config[sys_path]}" \
		"${openlist_config[etc_path]}" \
		"${openlist_config[data_path]}" \
		"${openlist_config[pid_path]}" 2>/dev/null || return 1

	echo "[INFO] 设置${openlist_config[name]}权限完成!"
	return 0
}

# 设置 openlist 环境
set_openlist_env()
{
	local arg=$1
	echo "[INFO] 设置${openlist_config[name]}服务配置"
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${openlist_config[etc_path]}" "${openlist_config[data_path]}"
		
		# 设置 openlist 配置
		set_openlist_conf
		
		# 设置 openlist 用户
		if ! set_openlist_user; then
			return 1
		fi
		
		if [ ! -f "${openlist_config[bin_file]}" ]; then
			echo "[ERROR] ${openlist_config[name]}可执行文件不存在,请检查!" >&2
			return 1
		fi
		
		# 查看 openlist 管理员密码
		su-exec ${user_config[user]} "${openlist_config[bin_file]}" admin --data "${openlist_config[etc_path]}"

		# 设置 openlist 缺省密码	
		su-exec ${user_config[user]} "${openlist_config[bin_file]}" admin --data "${openlist_config[etc_path]}" set "${openlist_config[passwd]}"
	fi

	echo "[INFO] 设置${openlist_config[name]}完成!"
	return 0
}

# 初始化 openlist 环境
init_openlist_service()
{
	local arg=$1
	echo "[INFO] 初始化${openlist_config[name]}服务"
	
	# 安装 openlist 环境
	if ! install_openlist_env "$arg"; then
		return 1
	fi
	
	# 设置 openlist 环境
	if ! set_openlist_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${openlist_config[name]}服务成功!"
	return 0
}

# 运行 openlist 服务
run_openlist_service()
{
	echo "[INFO] 运行${openlist_config[name]}服务"
	
	if [ ! -e "${openlist_config[bin_file]}" ] && [ ! -e "${openlist_config[etc_path]}" ]; then
		echo "[ERROR] ${openlist_config[name]}服务运行失败,请检查!" >&2
		return 1
	fi
	
	# 标识文件
	local pid_file="${openlist_config[pid_path]}/${openlist_config[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${openlist_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${openlist_config[name]}服务已经在运行!(PID:$pid)" >&2
				return 0
			fi
		fi
	fi
	
	# 后台运行 openlist 服务
	nohup "${openlist_config[bin_file]}" server --data "${openlist_config[etc_path]}" &> /dev/null &
	
	# 获取后台进程的 PID
	local openlist_pid=$!
	
	# 等待 PID 生效
	if ! wait_for_pid 10 "$openlist_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${openlist_config[port]}"; then
		echo "[ERROR] ${openlist_config[name]} 端口未就绪!" >&2
		return 1
	fi

	echo "$openlist_pid" > "$pid_file"
	echo "[INFO] 启动${openlist_config[name]}服务成功!"
}

# 更新 openlist 服务
update_openlist_service()
{
	echo "[INFO] 更新${openlist_config[name]}服务"
	local downloads_dir="${system_config[usr_dir]}/downloads"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${openlist_config[name]}" "$downloads_dir" download_openlist) || {
		echo "[ERROR] 获取 ${openlist_config[name]} 安装包失败" >&2
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${openlist_config[bin_file]}" ]; then
		install_binary "$latest_path" "${openlist_config[bin_file]}" "/usr/local/bin/${openlist_config[name]}" || {
			echo "[ERROR] 安装 ${openlist_config[name]} 失败" >&2
			return 2
		}
		return 0
	fi
	
	local current_version=$(${openlist_config[bin_file]} version | awk '/^Version:/ {print $2}' | tr -d 'v')
	local new_version=$($latest_path version | awk '/^Version:/ {print $2}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?

	case $result in
		0)
			echo "[INFO] ${openlist_config[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 openlist 运行
			close_openlist_service
			
			# 安装软件包
			install_binary "$latest_path" "${openlist_config[bin_file]}" || {
				echo "[ERROR] 更新 ${openlist_config[name]} 失败" >&2
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			echo "[INFO] ${openlist_config[name]} 已更新至 v$new_version"
			return 0
			;;
		2)
			echo "[INFO] 当前版本 (v$current_version) 比下载版本 (v$new_version) 更高"
			return 0
			;;
		*)
			echo "[ERROR] 版本比较异常 $current_version -> $new_version" >&2
			return 2
			;;
	esac
}

# 停止 openlist 服务
close_openlist_service()
{
	echo "[INFO] 关闭${openlist_config[name]}服务"
	
	if [ ! -x "${openlist_config[bin_file]}" ]; then
		echo "[ERROR] ${openlist_config[name]}服务不存在,请检查!" >&2
		return
	fi
	
	# 标识文件
	local pid_file="${openlist_config[pid_path]}/${openlist_config[name]}.pid"
	
	# 检查 openlist 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 openlist 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${openlist_config[name]}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${openlist_config[name]}); do
		echo "[INFO] ${openlist_config[name]}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${openlist_config[name]}服务成功!"
}