#!/bin/bash

declare -A FILEBROWSER_CONFIG=(
	["name"]="filebrowser"	# 服务名称
	["passwd"]="123456"		# 缺省密码
	["port"]="${FILEBROWSER_PORT:-8080}"					# 端口号
	["etc_path"]="${SYSTEM_CONFIG[config_dir]}/filebrowser"	# 配置目录
	["data_path"]="${SYSTEM_CONFIG[data_dir]}/filebrowser"	# 数据目录
	["sys_path"]="/usr/local/filebrowser"					# 安装路径
	["pid_path"]="/var/run/filebrowser"						# 标识路径
	["bin_file"]="/usr/local/filebrowser/filebrowser"		# 运行文件
	["log_file"]="${SYSTEM_CONFIG[data_dir]}/filebrowser/filebrowser.log"	# 日志文件
	["db_file"]="${SYSTEM_CONFIG[data_dir]}/filebrowser/database.db"		# 数据库文件
	["conf_file"]="${SYSTEM_CONFIG[config_dir]}/filebrowser/config.json"	# 配置文件
)

readonly -A FILEBROWSER_CONFIG

# 下载 filebrowser安装包
download_filebrowser()
{
	print_log "TRACE" "下载 ${FILEBROWSER_CONFIG[name]} 安装包" >&2
	local downloads_dir=$1
	
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
	
	local name_value="${FILEBROWSER_CONFIG[name]}"
	
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
		print_log "ERROR" "下载 $name 文件失败,请检查!" >&2
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 filebrowser 环境
install_filebrowser_env()
{
	print_log "TRACE" "安装 ${FILEBROWSER_CONFIG[name]} 服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/${FILEBROWSER_CONFIG[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${FILEBROWSER_CONFIG[name]}" "$downloads_dir" download_filebrowser) || {
				print_log "ERROR" "获取 ${FILEBROWSER_CONFIG[name]} 安装包失败, 请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				print_log "ERROR" "安装 ${FILEBROWSER_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${FILEBROWSER_CONFIG[sys_path]}" && ! -e "${FILEBROWSER_CONFIG[bin_file]}" ]]; then
			local install_dir=$(dirname "${FILEBROWSER_CONFIG[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				print_log "ERROR" "安装 ${FILEBROWSER_CONFIG[name]} 失败, 请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${FILEBROWSER_CONFIG[bin_file]}" "" "$install_dir/bin/${FILEBROWSER_CONFIG[name]}" || {
				print_log "ERROR" "创建 ${FILEBROWSER_CONFIG[name]} 符号链接失败, 请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	print_log "INFO" "安装 ${FILEBROWSER_CONFIG[name]} 完成!"
	return 0
}

# 设置 filebrowser 配置文件
set_filebrowser_conf()
{
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 配置文件"
	
	if [ ! -f "${FILEBROWSER_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${FILEBROWSER_CONFIG[name]} 可执行文件不存在, 请检查!"
		return 1
	fi
	
	print_log "INFO" "初始化 ${FILEBROWSER_CONFIG[name]} 配置文件:${FILEBROWSER_CONFIG[conf_file]}"

	# filebrowser 默认配置
	if [ ! -e "${FILEBROWSER_CONFIG[conf_file]}" ]; then
		cat > "${FILEBROWSER_CONFIG[etc_path]}/config.json" <<EOF
{
    "settings": {
        "key": "",
        "signup": false,
        "createUserDir": false,
        "userHomeBasePath": "/users",
        "defaults": {
            "scope": ".",
            "locale": "zh-cn",
            "viewMode": "mosaic",
            "singleClick": false,
            "sorting": {
                "by": "",
                "asc": false
            },
            "perm": {
                "admin": false,
                "execute": true,
                "create": true,
                "rename": true,
                "modify": true,
                "delete": true,
                "share": true,
                "download": true
            },
            "commands": [
                "ls",
                "df",
                "git",
                "unzip"
            ],
            "hideDotfiles": true,
            "dateFormat": false
        },
        "authMethod": "json",
        "branding": {
            "name": "文件管理器",
            "disableExternal": true,
            "disableUsedPercentage": true,
            "files": "",
            "theme": "dark",
            "color": "#3f51b5"
        },
        "tus": {
            "chunkSize": 10485760,
            "retryCount": 5
        },
        "commands": {
            "after_copy": [],
            "after_delete": [],
            "after_rename": [],
            "after_save": [],
            "after_upload": [],
            "before_copy": [],
            "before_delete": [],
            "before_rename": [],
            "before_save": [],
            "before_upload": []
        },
        "shell": [],
        "rules": [],
        "minimumPasswordLength": 6
    },
    "server": {
        "root": "${SYSTEM_CONFIG[usr_dir]}",
        "baseURL": "",
        "socket": "",
        "tlsKey": "",
        "tlsCert": "",
        "port": "${FILEBROWSER_CONFIG[port]}",
        "address": "0.0.0.0",
        "log": "${FILEBROWSER_CONFIG[log_file]}",
        "enableThumbnails": false,
        "resizePreview": false,
        "enableExec": true,
        "typeDetectionByHeader": false,
        "authHook": "",
        "tokenExpirationTime": ""
    },
    "auther": {
        "recaptcha": {
            "host": "",
            "key": "",
            "secret": ""
        }
    }
}
EOF
	fi
	
	# 初始化数据库
	print_log "INFO" "初始化 ${FILEBROWSER_CONFIG[name]} 数据库:${FILEBROWSER_CONFIG[db_file]}"

	if [ ! -f "${FILEBROWSER_CONFIG[db_file]}" ]; then
		if ! "${FILEBROWSER_CONFIG[bin_file]}" -d "${FILEBROWSER_CONFIG[db_file]}" config init >/dev/null 2>&1; then
			print_log "ERROR" "数据库初始化失败!"
			return 1
		fi
	fi
	
	# 导入 config.json 的配置
	print_log "INFO" "导入 ${FILEBROWSER_CONFIG[name]} 数据配置..."
	
	if ! "${FILEBROWSER_CONFIG[bin_file]}" -d "${FILEBROWSER_CONFIG[db_file]}" config import "${FILEBROWSER_CONFIG[conf_file]}"  >/dev/null 2>&1; then
		print_log "ERROR" "导入数据配置失败!"
		return 1
	fi
	
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 配置完成!"
	return 0
}

# 设置 filebrowser 用户
set_filebrowser_user()
{
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 用户权限"
	
	mkdir -p "${FILEBROWSER_CONFIG[pid_path]}"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
		"${FILEBROWSER_CONFIG[sys_path]}" \
		"${FILEBROWSER_CONFIG[etc_path]}" \
		"${FILEBROWSER_CONFIG[data_path]}" \
		"${FILEBROWSER_CONFIG[pid_path]}" 2>/dev/null || return 1

	# 设置管理员密码
	local admin_user="admin"
	print_log "INFO" "设置 ${FILEBROWSER_CONFIG[name]} 管理员用户 $admin_user密码"
	
	if ! "${FILEBROWSER_CONFIG[bin_file]}" users ls -d "${FILEBROWSER_CONFIG[db_file]}" | grep -qE "^[0-9]+[[:space:]]+${admin_user}[[:space:]]" >/dev/null 2>&1; then
		if ! "${FILEBROWSER_CONFIG[bin_file]}" users add "$admin_user" \
			"${FILEBROWSER_CONFIG[passwd]}" \
			-d "${FILEBROWSER_CONFIG[db_file]}" \
			--perm.admin \
			--perm.execute \
			--perm.create \
			--perm.rename \
			--perm.modify \
			--perm.delete \
			--perm.share \
			--perm.download >/dev/null 2>&1; then
			print_log "ERROR" "创建管理员 $admin_use r密码失败, 请检查!"
			return 1
		fi
	else
		if ! "${FILEBROWSER_CONFIG[bin_file]}" users update "$admin_user" \
			-d "${FILEBROWSER_CONFIG[db_file]}" \
			-p "${FILEBROWSER_CONFIG[passwd]}" \
			--perm.admin \
			--perm.execute \
			--perm.create \
			--perm.rename \
			--perm.modify \
			--perm.delete \
			--perm.share \
			--perm.download >/dev/null 2>&1; then
			print_log "ERROR" "更新管理员 $admin_user 密码失败, 请检查!"
			return 1
		fi
	fi
	
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 权限完成!"
	return 0
}

# 设置 filebrowser 环境
set_filebrowser_env()
{
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 服务配置"
	local arg=$1
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${FILEBROWSER_CONFIG[etc_path]}" "${FILEBROWSER_CONFIG[data_path]}"
		
		# 设置 filebrowser 配置
		if ! set_filebrowser_conf; then
			return 1
		fi
		
		# 设置 filebrowser 用户
		if ! set_filebrowser_user; then
			return 1
		fi
	fi
	
	print_log "TRACE" "设置 ${FILEBROWSER_CONFIG[name]} 完成!"
	return 0
}

# 初始化 filebrowser 服务
init_filebrowser_service()
{
	print_log "TRACE" "初始化 ${FILEBROWSER_CONFIG[name]} 服务"
	local arg=$1
	
	# 安装 filebrowser 环境
	if ! install_filebrowser_env "$arg"; then
		return 1
	fi
	
	# 设置 filebrowser 环境
	if ! set_filebrowser_env "$arg"; then
		return 1
	fi
	
	print_log "TRACE" "初始化 ${FILEBROWSER_CONFIG[name]} 服务成功!"
	return 0
}

# 运行 filebrowser 服务
run_filebrowser_service()
{
	print_log "TRACE" "运行 ${FILEBROWSER_CONFIG[name]} 服务"
	
	if [ ! -e "${FILEBROWSER_CONFIG[bin_file]}" ] && [ ! -e "${FILEBROWSER_CONFIG[etc_path]}" ]; then
		print_log "ERROR" "运行 ${FILEBROWSER_CONFIG[name]} 服务失败, 请检查!"
		return 1
	fi
	
	# 标识文件
	local pid_file="${FILEBROWSER_CONFIG[pid_path]}/${FILEBROWSER_CONFIG[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${FILEBROWSER_CONFIG[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				print_log "WARNING" "${FILEBROWSER_CONFIG[name]} 服务已经在运行!(PID:$pid)"
				return 0
			fi
		fi
	fi
	
	# 后台运行 filebrowser 服务
	if [ ! -f "${FILEBROWSER_CONFIG[db_file]}" ]; then
		nohup "${FILEBROWSER_CONFIG[bin_file]}" -c "${FILEBROWSER_CONFIG[conf_file]}" &> /dev/null &
	else
		nohup "${FILEBROWSER_CONFIG[bin_file]}" -d "${FILEBROWSER_CONFIG[db_file]}" --disable-preview-resize --disable-exec --disable-type-detection-by-header &> /dev/null &
	fi
	
	# 获取后台进程的 PID
	local filebrowser_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$filebrowser_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${FILEBROWSER_CONFIG[port]}"; then
		print_log "ERROR" "${FILEBROWSER_CONFIG[name]} 端口未就绪!"
		return 1
	fi

	echo "$filebrowser_pid" > "$pid_file"
	print_log "TRACE" "启动 ${FILEBROWSER_CONFIG[name]} 服务成功!"
}

# 更新 filebrowser 服务
update_filebrowser_service()
{
	print_log "TRACE" "更新 ${FILEBROWSER_CONFIG[name]} 服务"
	
	local downloads_dir="${SYSTEM_CONFIG[update_dir]}"
	local install_dir="${syncthing_config[sys_path]}"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${FILEBROWSER_CONFIG[name]}" "$downloads_dir" download_filebrowser) || {
		print_log "ERROR" "获取 ${FILEBROWSER_CONFIG[name]} 安装包失败!"
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${FILEBROWSER_CONFIG[bin_file]}" ]; then
		install_binary "$latest_path" "$install_dir" "/usr/local/bin/${FILEBROWSER_CONFIG[name]}" || {
			print_log "ERROR" "安装 ${FILEBROWSER_CONFIG[name]} 失败!"
			return 2
		}
		
		rm -rf "$downloads_dir/output"
		return 0
	fi
	
	local current_version=$(${FILEBROWSER_CONFIG[bin_file]} version | awk -F'[/ ]' '{print $3}' | tr -d 'v')
	local new_version=$($latest_path version | awk -F'[/ ]' '{print $3}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?
	
	case $result in
		0)
			print_log "INFO" "${FILEBROWSER_CONFIG[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 filebrowser 运行
			close_filebrowser_service
			
			# 安装软件包
			install_binary "$latest_path" "$install_dir" || {
				print_log "ERROR" "更新 ${FILEBROWSER_CONFIG[name]} 失败!"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			print_log "INFO" "${FILEBROWSER_CONFIG[name]} 已更新至 v$new_version"
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

# 停止 filebrowser 服务
close_filebrowser_service()
{
	print_log "TRACE" "关闭 ${FILEBROWSER_CONFIG[name]} 服务"
	
	if [ ! -x "${FILEBROWSER_CONFIG[bin_file]}" ]; then
		print_log "ERROR" "${FILEBROWSER_CONFIG[name]} 服务不存在, 请检查!"
		return
	fi
	
	# 标识文件
	local pid_file="${FILEBROWSER_CONFIG[pid_path]}/${FILEBROWSER_CONFIG[name]}.pid"
	
	# 检查 filebrowser 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 filebrowser 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			print_log "INFO" "${FILEBROWSER_CONFIG[name]} 服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${FILEBROWSER_CONFIG[name]}); do
		print_log "INFO" "${FILEBROWSER_CONFIG[name]} 服务进程:${PID}"
		kill $PID
	done
	
	print_log "TRACE" "关闭 ${FILEBROWSER_CONFIG[name]} 服务成功!"
}