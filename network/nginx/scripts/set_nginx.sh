#!/bin/bash

# 定义 nginx 配置数组
declare -A nginx_config=(
	["name"]="nginx"				# 服务名称
	["port"]="${HTTP_PORT:-80}"		# 端口号
	["sys_path"]="/usr/local/nginx"	# 安装路径
	["bin_file"]="/usr/local/nginx/sbin/nginx"							# 运行文件
	["conf_file"]="${system_config[config_dir]}/nginx.conf"				# 配置文件
	["pid_file"]="${system_config[data_dir]}/nginx.pid"					# 进程标识
	["lock_file"]="${system_config[data_dir]}/nginx.lock"				# 锁文件
	["error_file"]="${system_config[data_dir]}/logs/error.log"			# 错误日志
	["access_file"]="${system_config[data_dir]}/logs/access.log"		# 运行日志
)

# 定义 nginx 源码数组
declare -A nginx_sources=(
	["pcre"]='{"repo":"PCRE2Project/pcre2", "version":"latest"}'
	["nginx"]='{"repo":"nginx/nginx", "version":"latest"}'
	["upstream-check"]='{"repo":"", "version":""}'
)

readonly -A nginx_config

# 获取 nginx 源码版本
fetch_nginx_source()
{
	local downloads_dir=$1
	echo "[INFO] 获取${nginx_config[name]}源码" >&2

	for key in "${!nginx_sources[@]}"; do
		local name="$key"
		local source_config="${nginx_sources[$name]}"
		
		if [[ -z "$source_config" ]]; then
			continue
		fi
	
		# 解析 JSON 配置
		local repo=$(jq -r '.repo // empty' <<< "$source_config")
		local version=$(jq -r '.version // empty' <<< "$source_config")
		
		# 如果repo为空，跳过该源码获取
		if [[ -z "$repo" ]]; then
			echo "[INFO] 跳过 $name 源码获取,未配置仓库" >&2
			continue
		fi
		
		local url="https://github.com/$repo.git"
		echo "[INFO] 正在获取$name源码..." >&2
		
		# 构建克隆仓库的配置
		local jq_args=(
			--arg type "$([ -n "$repo" ] && echo "github" || echo "static")"
			--arg name "$name"
			--arg repo "${repo:-}"
			--arg version "${version}"
			--arg url "${url:-}"
		)
: <<'COMMENT_BLOCK'
				local matcher_value=""
				if [ -n "$repo" ]; then
					matcher_value="[[ \$name =~ \\.tar\\.gz\$ ]] && [[ ! \$name =~ \\.tar\\.gz\\. ]]"
				fi

				jq_args+=(
					--arg url "${url:-}"
					--arg repo "${repo:-}"
					--arg asset_matcher "${matcher_value}"
				)

				# 动态生成JSON配置
				local json_config=$(jq -n "${jq_args[@]}" '
					{ type: $type, name: $name, version: $version } +
					if $type == "github" then
						{ repo: $repo, asset_matcher: $asset_matcher }
					else
						{ url: $url }
					end |
					with_entries(select(.value != "")) ')
COMMENT_BLOCK
		
		# 创建克隆的 JSON 配置
		local json_config=$(jq -n "${jq_args[@]}" '{ type: $type, name: $name, repo: $repo, version: $version, url: $url }')
		
		# 获取源码路径
		local source_path
		source_path=$(get_service_sources "$name" "$downloads_dir" "$json_config")
		
		local ret=$?
		if [ $ret -ne 0 ]; then
			echo "[ERROR] 获取 $name 源码失败，错误码: $ret" >&2
			break
		fi
		
		nginx_sources[$name]=$(jq --arg path "$source_path" '. + {path: $path}' <<< "$source_config")
	done

	return $ret
}

# 编译安装 nginx 源码
setup_nginx_source()
{
	echo "[INFO] 编译${nginx_config[name]}源码"

	local pcre_path=$(jq -r '.path // empty' <<< "${nginx_sources[pcre]}" 2>/dev/null || echo '{}')
	local nginx_path=$(jq -r '.path // empty' <<< "${nginx_sources[nginx]}" 2>/dev/null || echo '{}')
	local upstream_check_path=$(jq -r '.path // empty' <<< "${nginx_sources[upstream-check]}" 2>/dev/null || echo '{}')
	
	if [[ -z "$pcre_path" || -z "$nginx_path" ]]; then
		echo "[ERROR] 获取${nginx_config[name]}源码路径为空,请检查!" >&2
		return 1
	fi

	# 进入 nginx 源码目录
	cd "$nginx_path" || { echo "[ERROR] 无法进入${nginx_config[name]}源码目录: $nginx_path" >&2; return 1; }

	local configure_options=(
		--prefix=${nginx_config[sys_path]}
		--sbin-path=${nginx_config[bin_file]}
		--conf-path=${nginx_config[conf_file]}
		--pid-path=${nginx_config[pid_file]}
		--lock-path=${nginx_config[lock_file]}
		--error-log-path=${nginx_config[error_file]}
		--http-log-path=${nginx_config[access_file]}
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
		--http-client-body-temp-path=${nginx_config[sys_path]}/temp/client_body_temp
		--http-proxy-temp-path=${nginx_config[sys_path]}/temp/proxy_temp
		--http-fastcgi-temp-path=${nginx_config[sys_path]}/temp/fastcgi_temp
		--http-scgi-temp-path=${nginx_config[sys_path]}/temp/scgi_temp
		--http-uwsgi-temp-path=${nginx_config[sys_path]}/temp/uwsgi_temp
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
	 echo "[INFO] 正在配置${nginx_config[name]}..."
	./configure "${configure_options[@]}" || {
		echo "[ERROR] ${nginx_config[name]}配置失败,请检查!" >&2
		return 2
	}

	# 编译并安装
	echo "[INFO] 正在编译${nginx_config[name]}..."
	make -j$(nproc) || {
		echo "[ERROR] ${nginx_config[name]}编译失败,请检查!" >&2
		return 3
	}

	echo "[INFO] 正在安装${nginx_config[name]}..."
	make install || {
		echo "[ERROR] ${nginx_config[name]}安装失败,请检查" >&2
		return 4
	}

	rm -rf "$pcre_path" "$nginx_path"
	return 0
}

# 安装 nginx 环境
install_nginx_env()
{
	local arg=$1
	echo "[INFO] 安装${nginx_config[name]}服务"

	local target_path="${system_config[install_dir]}/${nginx_config[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "${target_path}" ]; then
			local downloads_dir="${system_config[downloads_dir]}"
			
			# 获取 nginx 源码路径
			if ! fetch_nginx_source "$downloads_dir"; then
				echo "[ERROR] 获取${nginx_config[name]}失败,请检查!" >&2
				return 2
			fi

			# 编译 nginx 源码
			if ! setup_nginx_source; then
				echo "[ERROR] 编译${nginx_config[name]}源码失败,请检查!" >&2
				return 3
			fi

			# 安装软件包
			install_binary "${nginx_config[sys_path]}/*" "$target_path" || {
				echo "[ERROR] 安装 ${nginx_config[name]} 失败,请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${nginx_config[sys_path]}" || ! -e "${nginx_config[bin_file]}" ]]; then
			local install_dir=$(dirname "${nginx_config[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				echo "[ERROR] 安装 ${nginx_config[name]} 失败,请检查" >&2
				return 4
			}

			# 创建符号链接
			install_binary "${nginx_config[bin_file]}" "" "$install_dir/bin/${nginx_config[name]}" || {
				echo "[ERROR] 创建 ${nginx_config[name]} 符号链接失败,请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	echo "[INFO] 安装${nginx_config[name]}完成!"
	return 0
}

# 修改 nginx 端口
set_nginx_port()
{
	local target_file="$1"

	# 安全转义端口
	local safe_port=$(sed 's/[\/&]/\\&/g' <<< "${nginx_config[port]}")

	# 执行替换
	sed -i -E \
		-e "/^[[:space:]]*listen[[:space:]]*/ { 
			s/^([[:space:]]*listen[[:space:]]+)((([0-9]{1,3}\\.){3}[0-9]{1,3}:)?[0-9]+)?([^;]*)([;]?)/\1\4$safe_port\5;/ 
			t 
			s//\1$safe_port;/ 
		}" "$target_file"

	if [ $? -eq 0 ]; then
		echo "[INFO] ${nginx_config[name]}端口修改成功!"
	else
		echo "[ERROR] ${nginx_config[name]}端口修改失败!"
	fi
}

# 处理 nginx 配置文件
handle_nginx_config() 
{
	local target_file=$1
	echo "[INFO] 检查 nginx 配置文件:$target_file"
	
	# 检查 nginx 配置
	local status_code
	check_nginx_conf "$target_file" && status_code=0 || status_code=$?
	
	echo "[WARNING] 检查配置文件$target_file状态:$status_code"
	
	case $status_code in
		0|3)
			# 正常配置 (0:完整配置, 3:server块不在http内)
			set_nginx_port "$target_file"
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

# 设置 nginx 配置
set_nginx_conf()
{
	echo "[INFO] 设置${nginx_config[name]}配置文件"

	# nginx 预设数据
	local target_dir="${system_config[conf_dir]}/data"
	local dest_dir="${system_config[data_dir]}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		if ! rsync -a --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			return 1
		fi
		
		rm -rf "$target_dir"
	fi

	# nginx 预设配置
	target_dir="${system_config[conf_dir]}/etc"
	dest_dir="${system_config[config_dir]}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		if ! rsync -a --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			return 1
		fi
		
		rm -rf "$target_dir"
	fi

	# nginx 配置文件
	target_dir="${system_config[conf_dir]}/conf"
	dest_dir="${nginx_config[conf_file]%/*}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		# 备份 nginx 配置文件
		if [[ -f "${nginx_config[conf_file]}" ]]; then
			rsync -a --remove-source-files "${nginx_config[conf_file]}" "${nginx_config[conf_file]}.bak" >/dev/null
		fi

		# 拷贝 nginx 配置文件
		if ! rsync -a --remove-source-files "$target_dir" "$dest_dir/" >/dev/null; then
			return 1
		fi
		
		# 创建配置文件软链接
		if [[ -f "$dest_dir/conf/nginx.conf" ]]; then
			ln -sf "$dest_dir/conf/nginx.conf" "$dest_dir/nginx.conf" || return 1
		fi
		
		rm -rf "$target_dir"
	fi

	echo "[INFO] ${nginx_config[name]}配置文件:${nginx_config[conf_file]}"

	# 处理配置文件
	if ! handle_nginx_config "${nginx_config[conf_file]}"; then
		for config_file in "${nginx_config[conf_file]%/*}/conf/sites"/*.conf; do
			if ! handle_nginx_config "$config_file"; then
				continue
			fi
		done
	fi

	return 0
}

# 设置 nginx 用户
set_nginx_user()
{
	echo "[INFO] 设置${nginx_config[name]}用户权限"

	# 创建 nginx 临时目录
	mkdir -p "${nginx_config[sys_path]}/temp"

	# 设置 Nginx 工作目录权限
	chown -R ${user_config[user]}:${user_config[group]} \
			"${nginx_config[sys_path]}" \
			"${system_config[config_dir]}"

	echo "[INFO] 设置${nginx_config[name]}权限完成!"
}

# 设置 nginx 环境
set_nginx_env()
{
	local arg=$1
	echo "[INFO] 设置${nginx_config[name]}服务"

	if [ "$arg" = "config" ]; then
		# 设置 nginx 配置文件
		if ! set_nginx_conf; then
			return 1
		fi

		# 设置 nginx 用户
		set_nginx_user
	fi

	echo "[INFO] ${nginx_config[name]}设置完成!"
	return 0
}

# 初始化 nginx 环境
init_nginx_service()
{
	local arg=$1
	echo "[INFO] 初始化${nginx_config[name]}服务"

	# 安装 nginx 环境
	if ! install_nginx_env "$arg"; then
		return 1
	fi

	# 设置 nginx 环境
	if ! set_nginx_env "$arg"; then
		return 1
	fi

	echo "[INFO] 初始化${nginx_config[name]}服务成功!"
	return 0
}

# 运行 nginx 服务
run_nginx_service()
{
	echo "[INFO] 运行${nginx_config[name]}服务"

	if [ ! -e "${nginx_config[bin_file]}" ] || [ ! -e "${nginx_config[conf_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务运行失败,请检查!" >&2
		return 1
	fi
	
	# 标识文件
	local pid_file="${nginx_config[pid_file]}"

	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${nginx_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${nginx_config[name]}服务已经在运行(PID:$pid), 请检查!" >&2
				return 0
			fi
		fi
	fi
	
	# 测试配置文件
	${nginx_config[bin_file]} -t -c ${nginx_config[conf_file]} > /dev/null 2>&1 || {
		echo "[ERROR] ${nginx_config[name]} 配置测试失败, 请检查!" >&2
		return 1
	}

	# 后台运行 nginx
	nohup ${nginx_config[bin_file]} -c ${nginx_config[conf_file]} > /dev/null 2>&1 &

	# 等待 PID 生效
	if ! wait_for_pid 10 "$pid_file"; then
		return 1
	fi

	# 启动端口检测
	if ! wait_for_ports "${nginx_config[port]}"; then
		echo "[ERROR] ${nginx_config[name]}端口未就绪，查看服务日志" >&2
		return 1
	fi

	echo "[INFO] 启动${nginx_config[name]}服务成功!"
	return 0
}

# 停止 nginx 服务
close_nginx_service()
{
	echo "[INFO] 关闭${nginx_config[name]}服务"

	if [ ! -x "${nginx_config[bin_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务不存在,请检查!" >&2
		return
	fi
	
	# 标识文件
	local pid_file="${nginx_config[pid_file]}"

	# 检查 nginx 服务进程
	if [ -e "$pid_file" ]; then
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${nginx_config[name]}服务进程:${PID}"
			kill "$PID"
		done

		rm -rf "$pid_file"
	fi

	for PID in $(pidof ${nginx_config[name]}); do
		echo "[INFO] ${nginx_config[name]}服务进程:$PID"
		kill "$PID"
	done

	echo "[INFO] 关闭${nginx_config[name]}服务成功!"
}