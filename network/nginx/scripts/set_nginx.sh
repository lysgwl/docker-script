#!/bin/bash

# nginx 源码配置
declare -A NGINX_SOURCES=(
	["pcre"]='{"repo":"PCRE2Project/pcre2", "version":"latest"}'
	["nginx"]='{"repo":"nginx/nginx", "version":"latest"}'
	["upstream-check"]='{"repo":"", "version":""}'
)

# 获取 nginx 源码
fetch_nginx_source()
{
	logger "INFO" "[nginx] 获取源码 ..."
	local downloads_dir=$1
	local ret=0
	
	for key in "${!NGINX_SOURCES[@]}"; do
		local name="$key"
		local source_config="${NGINX_SOURCES[$name]}"
		
		[[ -z "$source_config" ]] && continue
	
		# 解析 JSON 配置
		local repo=$(jq -r '.repo // empty' <<< "$source_config")
		local version=$(jq -r '.version // empty' <<< "$source_config")
		
		# 如果repo为空, 跳过该源码获取
		if [[ -z "$repo" ]]; then
			logger "WARNING" "[nginx] 跳过获取 $name 源码, 未配置仓库"
			continue
		fi
		
		local url="https://github.com/$repo.git"
		logger "INFO" "[nginx] 正在获取 $name 源码 ..." 
		
		# 构建克隆仓库的配置
		local jq_args=(
			--arg type "$([ -n "$repo" ] && echo "github" || echo "static")"
			--arg name "$name"
			--arg repo "${repo:-}"
			--arg version "${version}"
			--arg url "${url:-}"
		)
		
		# 创建克隆的 JSON 配置
		local json_config=$(jq -n "${jq_args[@]}" '{ type: $type, name: $name, repo: $repo, version: $version, url: $url }')
		
		# 获取源码路径
		local source_path
		source_path=$(get_service_sources "$name" "$downloads_dir" "$json_config")
		
		local ret=$?
		if [[ $ret -ne 0 ]]; then
			logger "ERROR" "[nginx] 获取 $name 源码失败, 错误码: $ret"
			break
		fi
		
		NGINX_SOURCES[$name]=$(jq --arg path "$source_path" '. + {path: $path}' <<< "$source_config")
	done
	
	return $ret
}

# 编译安装 nginx 源码
setup_nginx_source()
{
	logger "INFO" "[nginx] 编译源码 ..."
	
	local pcre_path=$(jq -r '.path // empty' <<< "${NGINX_SOURCES[pcre]}" 2>/dev/null || echo '{}')
	if [[ ! -d "$pcre_path" ]]; then
		logger "ERROR" "[nginx] 获取 pcre 源码失败: ($pcre_path)"
		return 1
	fi
	
	local nginx_path=$(jq -r '.path // empty' <<< "${NGINX_SOURCES[nginx]}" 2>/dev/null || echo '{}')
	if [[ ! -d "$nginx_path" ]]; then
		logger "ERROR" "[nginx] 获取 nginx 源码失败: ($nginx_path)"
		return 1
	fi
	
	local upstream_check_path=$(jq -r '.path // empty' <<< "${NGINX_SOURCES[upstream-check]}" 2>/dev/null || echo '{}')
	if [[ ! -d "$upstream_check_path" ]]; then
		logger "WARNING" "[nginx] 获取 upstream_check 源码失败: ($upstream_check_path)"
	fi
	
	# 进入 nginx 源码目录
	cd "$nginx_path" || { logger "ERROR" "[nginx] 无法进入源码目录: $nginx_path"; return 1; }
	
	local configure_options=(
		--prefix=${nginx_cfg[sys_path]}
		--sbin-path=${nginx_cfg[bin_file]}
		--conf-path=${nginx_cfg[conf_file]}
		--pid-path=${nginx_cfg[pid_file]}
		--lock-path=${nginx_cfg[lock_file]}
		--error-log-path=${nginx_cfg[error_log]}
		--http-log-path=${nginx_cfg[access_log]}
		--with-debug
		--with-threads
		--with-pcre="$pcre_path"
		--with-file-aio
		--with-select_module
		--with-poll_module
		--with-compat
		--with-cc-opt='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -grecord-gcc-switches -mtune=generic -fPIC'
		--with-http_ssl_module
		--with-http_v2_module
		--with-http_realip_module
		--with-http_addition_module
		--with-http_sub_module
		--with-http_dav_module
		--with-http_flv_module
		--with-http_mp4_module
		--with-http_gunzip_module
		--with-http_gzip_static_module
		--with-http_auth_request_module
		--with-http_random_index_module
		--with-http_secure_link_module
		--with-http_slice_module
		--with-http_stub_status_module
		--http-client-body-temp-path=${nginx_cfg[sys_path]}/temp/client_body_temp
		--http-proxy-temp-path=${nginx_cfg[sys_path]}/temp/proxy_temp
		--http-fastcgi-temp-path=${nginx_cfg[sys_path]}/temp/fastcgi_temp
		--http-scgi-temp-path=${nginx_cfg[sys_path]}/temp/scgi_temp
		--http-uwsgi-temp-path=${nginx_cfg[sys_path]}/temp/uwsgi_temp
		--with-mail
		--with-mail_ssl_module
		--with-stream
		--with-stream_ssl_module
		--with-stream_realip_module
		--with-stream_ssl_preread_module
	)
	
	if [[ -n "$upstream_check_path" && -d "$upstream_check_path" ]]; then
		if patch -p1 < "$upstream_check_path/check_1.20.1+.patch"; then
			configure_options+=(--add-module="$upstream_check_path")
		fi
	fi
	
	# 执行配置命令
	logger "INFO" "[nginx] 正在配置源码 ..."
	./configure "${configure_options[@]}" || {
		logger "ERROR" "[nginx] 配置源码失败"
		return 2
	}
	
	# 编译并安装
	logger "INFO" "[nginx] 正在编译源码 ..."
	make -j$(nproc) || {
		logger "ERROR" "[nginx] 编译源码失败"
		return 3
	}
	
	logger "INFO" "[nginx] 正在安装服务文件 ..."
	make install || {
		logger "ERROR" "[nginx] 安装服务文件失败"
		return 4
	}
	
	rm -rf "$pcre_path" "$nginx_path"
}

# 安装 nginx 环境
install_nginx_env()
{
	logger "INFO" "[nginx] 安装服务环境"
	local arg=$1
	
	local target_path="${SYSTEM_CONFIG[install_dir]}/nginx"
	if [[ "$arg" = "init" ]]; then
		if [[ ! -d "${target_path}" ]]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取 nginx 源码
			if ! fetch_nginx_source "$downloads_dir"; then
				logger "ERROR" "[nginx] 获取源码失败"
				return 1
			fi
			
			# 编译 nginx 源码
			if ! setup_nginx_source; then
				logger "ERROR" "[nginx] 编译源码失败" 
				return 2
			fi
			
			# 安装软件包
			install_binary "${nginx_cfg[sys_path]}/*" "$target_path" || {
				logger "ERROR" "[nginx] 安装服务失败"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [[ "$arg" = "config" ]]; then
		if [[ ! -d "${nginx_cfg[sys_path]}" || ! -e "${nginx_cfg[bin_file]}" ]]; then
			local install_dir=$(dirname "${nginx_cfg[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				logger "ERROR" "[nginx] 安装服务失败"
				return 3
			}
			
			# 创建符号链接
			install_binary "${nginx_cfg[bin_file]}" "" "${nginx_cfg[symlink_file]}" || {
				logger "ERROR" "[nginx] 创建符号链接失败"
				return 3
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi
	
	logger "INFO" "[nginx] 服务安装完成"
}

# 设置 nginx 用户
set_nginx_user()
{
	logger "INFO" "[nginx] 设置服务用户权限"
	
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	# 获取配置路径
	local dirs=(
		"${nginx_cfg[sys_path]}"
		"${nginx_cfg[etc_path]}"
		"${nginx_cfg[data_path]}"
		"${nginx_cfg[sys_path]}/temp"
	)
	
	# 设置目录权限
	for dir in "${dirs[@]}"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[nginx] 目录 $dir 变量为空"
			return 1
		fi
		
		chown -R "$user:$group" "$dir" 2>/dev/null || {
			logger "ERROR" "[nginx] 设置目录权限失败: $dir"
			return 2
		}
	done
	
	logger "INFO" "[nginx] 服务权限完成"
}

# 修改 nginx 端口
set_nginx_port()
{
	local target_file="$1"
	
	# 安全转义端口
	local safe_port=$(sed 's/[\/&]/\\&/g' <<< "${nginx_cfg[port]}")
	
	# 执行替换
	sed -i -E \
		-e "/^[[:space:]]*listen[[:space:]]*/ { 
			s/^([[:space:]]*listen[[:space:]]+)((([0-9]{1,3}\\.){3}[0-9]{1,3}:)?[0-9]+)?([^;]*)([;]?)/\1\4$safe_port\5;/ 
			t 
			s//\1$safe_port;/ 
		}" "$target_file"
	
	if [ $? -ne 0 ]; then
		logger "ERROR" "[nginx] 端口修改失败: $target_file"
		return 1
	fi
	
	logger "INFO" "[nginx] 端口修改成功: $target_file"
}

# 处理 nginx 配置文件
handle_nginx_config() 
{
	local config_file=$1
	logger "INFO" "[nginx] 处理配置文件: $config_file"
	
	# 检查文件是否存在
	if [[ ! -f "$config_file" ]]; then
		logger "WARNING" "配置文件不存在: $config_file"
		return 0
	fi
	
	# 检查 nginx 配置
	local status_code
	check_nginx_conf "$config_file" && status_code=0 || status_code=$?
	
	logger "DEBUG" "[nginx] 配置文件: $config_file, 状态码: $status_code"
	case $status_code in
		0|3)
			# 正常配置 (0:完整配置, 3:server块不在http内)
			set_nginx_port "$config_file"
			return 0
			;;
		2)
			# 仅有 http 块
			return 1
			;;
		*)
			# 无效配置或其他错误
			return 2
			;;
	esac
}

# 同步配置数据
sync_nginx_conf()
{
	local src="$1"
	local dst="$2"
	local desc="$3"
	
	[[ ! -d "$src" ]] && return 1
	
	if find "$src" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		if ! rsync -a --remove-source-files "$src"/ "$dst"/ >/dev/null 2>&1; then
			logger "ERROR" "[nginx] 复制 $desc 失败"
			return 1
		fi
		
		rm -rf "$src" 
		logger "DEBUG" "[nginx] 复制 $desc 完成: $src → $dst"
	fi
	
	return 0
}

# 设置 nginx 配置
set_nginx_conf()
{
	logger "INFO" "[nginx] 设置服务配置文件"
	
	# 预设数据(data)
	sync_nginx_conf "${SYSTEM_CONFIG[conf_dir]}/data" "${nginx_cfg[data_path]}" "数据文件" || return 1
	
	# 预设配置(etc)
	sync_nginx_conf "${SYSTEM_CONFIG[conf_dir]}/etc" "${nginx_cfg[etc_path]}" "配置文件" || return 1
	
	# 配置文件
	local target_dir="${SYSTEM_CONFIG[conf_dir]}/conf"
	local dest_dir="${nginx_cfg[conf_file]%/*}"
	
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		# 备份配置
		if [[ -f "${nginx_cfg[conf_file]}" ]]; then
			rsync -a --remove-source-files "${nginx_cfg[conf_file]}" "${nginx_cfg[conf_file]}.bak" >/dev/null
		fi
		
		# 复制新配置
		rsync -a --remove-source-files "$target_dir" "$dest_dir/" >/dev/null || return 1
		
		# 软链接
		if [[ -f "$dest_dir/conf/nginx.conf" ]]; then
			ln -sf "$dest_dir/conf/nginx.conf" "$dest_dir/nginx.conf"
		fi
		
		rm -rf "$target_dir"
	fi
	
	logger "INFO" "[nginx] 主配置文件:${nginx_cfg[conf_file]}"
	
	# 处理主配置
	if ! handle_nginx_config "${nginx_cfg[conf_file]}"; then
		# 站点目录
		local site_dir="${nginx_cfg[conf_file]%/*}/conf/sites"
		
		for file in "$site_dir"/*.conf; do
			[[ -f "$file" ]] || continue
			
			handle_nginx_config "$file"
		done
	fi
	
	logger "INFO" "[nginx] 服务配置完成"
}

# 设置 nginx 路径
set_nginx_paths()
{
	logger "INFO" "[nginx] 设置服务环境目录"
	
	local dirs=(
		"${nginx_cfg[sys_path]}"
		"${nginx_cfg[etc_path]}"
		"${nginx_cfg[data_path]}"
		"${nginx_cfg[sys_path]}/temp"
	)
	
	local files=(
		"${nginx_cfg[pid_file]}"
		"${nginx_cfg[error_log]}"
		"${nginx_cfg[access_log]}"
	)
	
	# 创建目录
	for dir in "${dirs[@]}"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[nginx] 目录 $dir 变量为空"
			return 1
		fi
		
		if ! mkdir -p "$dir"; then
			logger "ERROR" "[nginx] 目录创建失败: $dir"
			return 2
		fi
	done
	
	# 创建文件
	for file in "${files[@]}"; do
		if [[ -z "$file" ]]; then
			logger "ERROR" "[nginx] 文件 $file 路径为空"
			return 1
		fi
		
		local parent=$(dirname "$file")
		if ! mkdir -p "$parent"; then
			logger "ERROR" "[nginx] 父目录创建失败: $parent"
			return 1
		fi
		
		if ! touch "$file"; then
			logger "ERROR" "[nginx] 文件创建失败: $file"
			return 3
		fi
	done
	
	logger "INFO" "[nginx] 设置目录完成"
}

# 设置 nginx 环境
set_nginx_env()
{
	logger "INFO" "[nginx] 设置服务环境"
	
	# 设置路径
	if ! set_nginx_paths; then
		logger "ERROR" "[nginx] 路径设置失败"
		return 1
	fi
		
	if [ "$1" = "config" ]; then
		# 设置 nginx 配置文件
		if ! set_nginx_conf; then
			return 2
		fi
		
		# 设置 nginx 用户
		set_nginx_user
	fi
	
	logger "INFO" "[nginx] 设置服务完成"
}

# 设置 nginx 模板
set_nginx_template()
{
	# 获取配置路径
	local data_dir="${SYSTEM_CONFIG[data_dir]}"
	local etc_dir="${SYSTEM_CONFIG[config_dir]}"
	local log_dir="${SYSTEM_CONFIG[data_dir]}/logs"
	local sys_dir="/usr/local/nginx"
	local bin_file="${sys_dir}/sbin/nginx"
	local symlink_file="/usr/local/bin/nginx"
	
	local nginx_json=$(jq -n \
		--arg name "nginx" \
		--argjson port "${HTTP_PORT:-80}" \
		--arg etc "${etc_dir}" \
		--arg data "${data_dir}" \
		--arg sys "${sys_dir}" \
		--arg bin "${bin_file}" \
		--arg symlink "${symlink_file}" \
		--arg pid "${data_dir}/nginx.pid" \
		--arg conf "${etc_dir}/nginx.conf" \
		--arg lock "${data_dir}/nginx.lock" \
		--arg error "${log_dir}/error.log" \
		--arg access "${log_dir}/access.log" \
		'{
			name: $name,
			port: $port,
			etc_path: $etc,
			data_path: $data,
			sys_path: $sys,
			bin_file: $bin,
			symlink_file: $symlink,
			pid_file: $pid,
			conf_file: $conf,
			lock_file: $lock,
			error_log: $error,
			access_log: $access
		}')
		
	import_service_config "nginx" "" "" "$nginx_json"
	return $?
}

# 初始化 nginx 环境
init_nginx_service()
{
	logger "INFO" "[nginx] 初始化服务"
	
	# 设置 nginx 模板
	if ! set_nginx_template; then
		logger "ERROR" "[nginx] 设置模板失败"
		return 1
	fi
	
	# 获取服务配置
	get_service_config "nginx" "config" "nginx_cfg" || {
		logger "ERROR" "[nginx] 无法获取服务配置"
		return 2
	}
	
	# 安装 nginx 环境
	if ! install_nginx_env "$1"; then
		logger "ERROR" "[nginx] 安装环境失败"
		return 3
	fi
	
	# 设置 nginx 环境
	if ! set_nginx_env "$1"; then
		logger "ERROR" "[nginx] 设置环境失败"
		return 4
	fi
	
	logger "INFO" "[nginx] ✓ 初始化服务完成"
}

# 运行 nginx 服务
run_nginx_service()
{
	local -n pid_ref="${1:-}"
	logger "INFO" "[nginx] 运行服务"
	
	# 获取服务配置
	get_service_config "nginx" "config" "nginx_cfg" || {
		logger "ERROR" "[nginx] 无法获取服务配置"
		return 1
	}
	
	local bin_file="${nginx_cfg[bin_file]}"
	local pid_file="${nginx_cfg[pid_file]}"
	local conf_file="${nginx_cfg[conf_file]}"
	local http_port="${nginx_cfg[port]}"
	
	[[ ! -f "$bin_file" ]] && { logger "ERROR" "[nginx] 可执行文件不存在"; return 1; }
	[[ ! -f "$conf_file" ]] && { logger "ERROR" "[nginx] 配置文件不存在"; return 1; }
	
	# 检查是否已运行
	if check_service_alive "nginx"; then
		logger "WARNING" "[nginx] 检测服务已经在运行!"
		return 0
	fi
	
	# 测试配置文件
	"$bin_file" -t -c "$conf_file" > /dev/null 2>&1 || {
		logger "ERROR" "[nginx] 配置测试失败"
		return 2
	}
	
	# 启动服务
	"$bin_file" -c "$conf_file" > /dev/null 2>&1 || {
		logger "ERROR" "[nginx] 执行启动命令失败"
		return 3
	}
	
	#exec_as_user ${USER_CONFIG[user]} "
	#	\"$bin_file\" -c \"${conf_file}\" > /dev/null 2>&1 &
	#" || {
	#	logger "ERROR" "[nginx] 执行启动命令失败"
	#	return 3
	#}
	
	# 等待进程
	if ! wait_for_pid 5 "$pid_file"; then
		return 4
	fi
	
	# 端口检测
	if ! wait_for_ports "${http_port}"; then
		logger "ERROR" "[nginx] 检测服务端口未就绪!"
		return 5
	fi
	
	pid_ref=$(cat "$pid_file" 2>/dev/null | tr -d ' \n')
	logger "INFO" "[nginx] ✓ 启动服务完成!"
}

# 停止 nginx 服务
close_nginx_service()
{
	logger "INFO" "[nginx] 开始停止服务"
	
	# 标识文件
	local pid_file=$(get_service_pid_file "nginx")
	
	# 获取PID
	local pid=$(get_service_pid "nginx" 2>/dev/null)
	[[ -z "$pid" && -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null)
	
	# 停止服务
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		logger "INFO" "[nginx] 停止进程 (PID: $pid)"
		
		# 优雅停止
		kill -TERM "$pid" 2>/dev/null
		
		# 等待最多5秒
		for i in {1..5}; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		
		# 强制停止
		if kill -0 "$pid" 2>/dev/null; then
			logger "WARNING" "[nginx] 进程未响应, 强制停止"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	
	# 清理PID文件
	rm -f "$pid_file" 2>/dev/null
	logger "INFO" "[nginx] ✓ 服务已停止"
}