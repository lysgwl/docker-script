#!/bin/bash

# 定义 nginx 配置数组
declare -A nginx_config=(
	["name"]="nginx"				# 服务名称
	["port"]="${HTTP_PORT:-80}"		# 端口号
	["sys_path"]="/usr/local/nginx"	# 安装路径
	["bin_file"]="/usr/local/nginx/sbin/nginx"							# 运行文件
	["conf_file"]="${system_config[config_dir]}/nginx/nginx.conf"		# 配置文件
	["pid_file"]="${system_config[data_dir]}/nginx/nginx.pid"			# 进程标识
	["lock_file"]="${system_config[data_dir]}/nginx/nginx.lock"			# 锁文件
	["error_file"]="${system_config[data_dir]}/nginx/logs/error.log"	# 错误日志
	["access_file"]="${system_config[data_dir]}/nginx/logs/access.log"	# 运行日志
)

# 定义 nginx 源码数组
declare -A nginx_sources=(
	["pcre"]='{"repo":"PCRE2Project/pcre2", "version":"latest"}'
	["nginx"]='{"repo":"nginx/nginx", "version":"latest"}'
)

readonly -A nginx_config

# 获取 nginx 源码版本
fetch_nginx_source()
{
	local downloads_dir=$1
	echo "[INFO] 获取${nginx_config[name]}源码" >&2

	local output_dir="${downloads_dir}/output"
	if [ ! -d "$output_dir" ]; then
		mkdir -p "$output_dir"
	fi

	local ret=0
	for key in "${!nginx_sources[@]}"; do
		local name="$key"
		local source_config="${nginx_sources[$name]}"

		# 解析 JSON 配置
		local repo=$(jq -r '.repo // empty' <<< "$source_config")
		local version=$(jq -r '.version // empty' <<< "$source_config")

		local url="https://github.com/$repo.git"
		echo "[INFO] 正在获取$name源码..." >&2

		local findpath latest_path
		if ! findpath=$(find_latest_archive "$downloads_dir" "$name.*"); then
			echo "[WARNING] 未匹配到$name软件包..." >&2

			if [ -n "$url" ] || [ -n "$repo" ]; then
				local jq_args=(
					--arg type "$([ -n "$repo" ] && echo "github" || echo "static")"
					--arg name "$name"
					--arg repo "${repo:-}"
					--arg version "${version}"
					--arg url "${url:-}"
				)

				local json_config=$(jq -n "${jq_args[@]}" '{ type: $type, name: $name, repo: $repo, version: $version, url: $url }')

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
				local clone_path
				if ! clone_path=$(clone_repo "$json_config" "$downloads_dir"); then
					ret=2; break
				fi

				local clone_name="$(basename "$clone_path")"
				if [ ! -d "$output_dir/$clone_name" ]; then
					#cp -rf "$clone_path" "$output_dir"
					rsync -a --exclude '.*' "$clone_path" "$output_dir"/
				fi

				latest_path="$output_dir/$clone_name"
			fi
		else
			local archive_type=$(jq -r '.filetype' <<< "$findpath")
			local archive_path=$(jq -r '.filepath' <<< "$findpath")

			if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
				ret=1; break
			fi

			if [ "$archive_type" = "file" ]; then
				if ! latest_path=$(extract_and_validate "$archive_path" "$output_dir" "$name.*"); then
					ret=3; break 
				fi
			else
				local archive_name=$(jq -r '.name' <<< "$findpath")
				if [ ! -d "$output_dir/$archive_name" ]; then
					# cp -rf "$archive_path" "$output_dir"
					rsync -a --exclude '.*' "$archive_path" "$output_dir"/
				fi
				latest_path="$output_dir/$archive_name"
			fi
		fi

		nginx_sources[$name]=$(jq --arg path "$latest_path" '. + {path: $path}' <<< "$source_config")
	done

	return $ret
}

# 编译安装 nginx 源码
setup_nginx_source()
{
	echo "[INFO] 编译${nginx_config[name]}源码"

	local pcre_path=""
	local nginx_path=""

	local pcre_json="${nginx_sources[pcre]}"
	if [ -n "$pcre_json" ]; then
		pcre_path=$(jq -r '.path // empty' <<< "$pcre_json")
	fi

	local nginx_json="${nginx_sources[nginx]}"
	if [ -n "$nginx_json" ]; then
		nginx_path=$(jq -r '.path // empty' <<< "$nginx_json")
	fi

	if [[ -z "$pcre_path" || -z "$nginx_path" ]]; then
		echo "[ERROR] 获取${nginx_config[name]}源码路径为空,请检查!"
		return 1
	fi

	# 进入 nginx 源码目录
	cd "$nginx_path" || { echo "[ERROR] 无法进入${nginx_config[name]}源码目录: $nginx_path"; return 1; }

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

	# 执行配置命令
	 echo "[INFO] 正在配置${nginx_config[name]}..."
	./configure "${configure_options[@]}" || {
		echo "[ERROR] ${nginx_config[name]}配置失败,请检查!"
		return 2
	}

	# 编译并安装
	echo "[INFO] 正在编译${nginx_config[name]}..."
	make -j$(nproc) || {
		echo "[ERROR] ${nginx_config[name]}编译失败,请检查!"
		return 3
	}

	echo "[INFO] 正在安装${nginx_config[name]}..."
	make install || {
		echo "[ERROR] ${nginx_config[name]}安装失败,请检查！"
		return 4
	}

	rm -rf "$pcre_path" "nginx_path"
	return 0
}

# 安装 nginx 环境
install_nginx_env()
{
	local arg=$1
	echo "[INFO] 安装${nginx_config[name]}服务..."

	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"

	local target_dir="$install_dir/${nginx_config[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "${target_dir}" ]; then
			# 获取 nginx 源码路径
			if ! fetch_nginx_source "$downloads_dir"; then
				echo "[ERROR] 获取${nginx_config[name]}失败,请检查!"
				return 2
			fi

			# 编译 nginx 源码
			if ! setup_nginx_source; then
				echo "[ERROR] 编译${nginx_config[name]}源码失败,请检查!"
				return 3
			fi

			# 安装二进制文件
			install_binary "${nginx_config[sys_path]}" "$install_dir" || return 4
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${nginx_config[sys_path]}" || ! -e "${nginx_config[bin_file]}" ]]; then	
			# 安装二进制文件
			install_binary "$target_dir" "${nginx_config[sys_path]}" "/usr/local/bin/${nginx_config[name]}" || return 4
		fi
	else
		echo "[ERROR] 无效的未知参数:$arg"
		return 1
	fi

	echo "[INFO] 编译${nginx_config[name]}完成!"
	return 0
}

# 检查 nginx 配置
check_nginx_conf()
{
	local conf_file="$1"
	local status_code=0

	status_code=$(gawk '
	BEGIN {
		stack_idx = 0          # 括号堆栈索引
		has_http = 0           # 存在未注释的http块
		has_server = 0         # 存在未注释的server块
		invalid_config = 0     # 配置是否无效
		line_num = 0           # 当前行号
		delete stack           # 初始化堆栈
	}

	{
		line_num++
		$0 = gensub(/#.*/, "", "g")  # 去除行内注释
		$0 = gensub(/^[[:blank:]]+|[[:blank:]]+$/, "", "g")  # 清理首尾空格
		if ($0 ~ /^[[:blank:]]*$/) next  # 跳过空行
	}

	# 检测块开始
	#match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+(.*)[ \t]*\{/, arr) {
	match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+([^{}]*)[ \t]*\{[ \t]*$/, arr) {
		block_type = arr[1]
		block_param = arr[2]

		if (block_type == "location") {
			sub(/^[[:space:]]*[=~*]+[[:space:]]*/, "", block_param)  # 移除前缀修饰符
		}

		block_value=block_param
		if (block_value == "") {
			block_value=block_type
		}

		stack[++stack_idx] = block_value			  # 推入堆栈
		
		if (block_type == "http" || block_type == "server") {
			has_http += (block_type == "http")       # 标记存在http块
			has_server += (block_type == "server")   # 标记存在server块
		}
		next
	}

	# 检测闭合符
	/^[[:blank:]]*\}/ {
		if (stack_idx == 0) {
			invalid_config = 1
			next
		}

		current_block = stack[stack_idx]
		stack_idx--
		next
	}

	END {
		# 错误优先级：括号不匹配 > 块存在性
		if (invalid_config || stack_idx != 0) {
			if (stack_idx > 0) {
				current_block = stack[stack_idx]
				if (current_block == "http") {
					print "[ERROR] http块未闭合" > "/dev/stderr"
				} else if (current_block == "server") {
					print "[ERROR] server块未闭合" > "/dev/stderr"
				} else {
					printf "[ERROR] %s块未闭合\n", current_block > "/dev/stderr"
				}
			}
			print 3
			exit
		}

		# 有效配置判断
		if (has_http && has_server)	{ print 0 }		# 完整配置
		else if (has_http)			{ print 1 }		# 仅有http块
		else if (has_server)		{ print 2 }		# server块不在http内
		else						{ print 3 }		# 无有效块
	}
	' "$conf_file")

	return $status_code
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

# 处理 nginx 配置文件的状态
handle_nginx_config() 
{
	local target_file=$1
	check_nginx_conf "$target_file"

	local ret=$?
	echo "[WARNING] 检查配置文件$target_file状态:$ret"

	case "$ret" in
		0|2)# 正常配置
			set_nginx_port "$target_file"
			return 0
			;;
		1)	# 仅有 http 块
			return 1 
			;;
		*)	# 无效配置
			return 2 
			;;
	esac
}

# 设置 nginx 配置
set_nginx_conf()
{
	echo "设置${nginx_config[name]}配置文件"

	# nginx 预设数据
	local target_dir="${system_config[conf_dir]}/data"
	local dest_dir="${system_config[data_dir]}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		if rsync -av --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			rm -rf "$target_dir"
		fi
	fi

	# nginx 预设配置
	target_dir="${system_config[conf_dir]}/etc"
	dest_dir="${system_config[config_dir]}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		if rsync -av --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			rm -rf "$target_dir"
		fi
	fi

	# nginx 配置文件
	target_dir="${system_config[conf_dir]}/${nginx_config[name]}"
	dest_dir="${nginx_config[conf_file]%/*}"

	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"

		# 备份 nginx 配置文件
		if [ -f "${nginx_config[conf_file]}" ]; then
			mv -f "${nginx_config[conf_file]}" "${nginx_config[conf_file]}.bak"
		fi

		# 拷贝 nginx 配置文件
		cp -rf "$target_dir/"* "$dest_dir"
	fi

	echo "[INFO] ${nginx_config[name]}配置文件:${nginx_config[conf_file]}"

	# 检查处理配置文件
	handle_nginx_config "${nginx_config[conf_file]}" || \
	handle_nginx_config "${nginx_config[conf_file]%/*}/extra/www.conf"
}

# 设置 nginx 用户
set_nginx_user()
{
	echo "设置${nginx_config[name]}用户权限..."

	# 创建 nginx 临时目录
	mkdir -p "${nginx_config[sys_path]}/temp"

	# 设置 Nginx 工作目录权限
	chown -R ${user_config[user]}:${user_config[group]} "${nginx_config[sys_path]}"

	echo "设置${nginx_config[name]}权限完成!"
}

# 设置 nginx 环境
set_nginx_env()
{
	local arg=$1
	echo "[INFO] 设置${nginx_config[name]}服务..."

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
init_nginx_env()
{
	local arg=$1
	echo "[INFO] 初始化${nginx_config[name]}服务..."

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
	echo "[INFO] 运行${nginx_config[name]}服务..."

	if [ ! -e "${nginx_config[bin_file]}" ] || [ ! -e "${nginx_config[conf_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务运行失败,请检查!"
		return 1
	fi

	# 检查服务是否已运行
	if [ -f "${nginx_config[pid_file]}" ]; then
		local pid=$(cat "${nginx_config[pid_file]}")
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "${nginx_config[pid_file]}"
		else
			if ! grep -qF "${nginx_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "${nginx_config[pid_file]}"
			else
				echo "[WARNING] ${nginx_config[name]}服务已经在运行(PID:$pid), 请检查!"
				return 0
			fi
		fi
	fi

	# 后台运行 nginx
	nohup ${nginx_config[bin_file]} -c ${nginx_config[conf_file]} > /dev/null 2>&1 &

	# 等待 2 秒
	sleep 2

	# 启动端口检测
	if ! wait_for_ports "${nginx_config[port]}"; then
		echo "[ERROR] ${nginx_config[name]}端口未就绪，查看服务日志："
		return 1
	fi

	echo "[INFO] 启动${nginx_config[name]}服务成功!"
}

# 停止 nginx 服务
close_nginx_service()
{
	echo "[INFO] 关闭${nginx_config[name]}服务..."

	if [ ! -x "${nginx_config[bin_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务不存在,请检查!"
		return
	fi

	# 检查 nginx 服务进程
	if [ -e "${nginx_config[pid_file]}" ]; then
		for PID in $(cat "${nginx_config[pid_file]}"); do
			echo "[INFO] ${nginx_config[name]}服务进程:${PID}"
			kill "$PID"
		done

		rm -rf "${nginx_config[pid_file]}"
	fi

	for PID in $(pidof ${nginx_config[name]}); do
		echo "[INFO] ${nginx_config[name]}服务进程:$PID"
		kill "$PID"
	done

	echo "[INFO] 关闭${nginx_config[name]}服务成功!"
}