#!/bin/bash

# 定义nginx配置数组
declare -A nginx_config=(
	["name"]="nginx"				# 服务名称
	["port"]="${HTTP_PORT:-80}"		# 端口号
	["sys_path"]="/usr/local/nginx"	# 安装路径
	["pid_file"]="/usr/local/nginx/logs/nginx.pid"		# 进程标识
	["bin_file"]="/usr/local/nginx/sbin/nginx"			# 运行文件
	["conf_file"]="/usr/local/nginx/conf/nginx.conf"	# 配置文件
	["lock_file"]="/usr/local/nginx/logs/nginx.lock"	# 锁文件
	["error_file"]="/usr/local/nginx/logs/error.log"	# 错误日志
	["access_file"]="/usr/local/nginx/logs/access.log"	# 运行日志
)

readonly -A nginx_config

# 获取nginx源码版本
fetch_nginx_source()
{
	local downloads_dir=$1
	
	# 获取文件
	local latest_file
	latest_file=$(find_latest_archive "${downloads_dir}" "${nginx_config[name]}*.tar.gz") || {
		# nginx下载url
		local downloads_url="https://nginx.org/download/${nginx_config[name]}-1.26.3.tar.gz"
		
		local json_config=$(jq -n \
			--arg type "static" \
			--argjson url "$(printf '%s' "${downloads_url}" | jq -Rs .)" \
			'{
				type: $type,
				url: $url
			}')
		
		if ! latest_file=$(download_package "${json_config}" "${downloads_dir}"); then
			return $?
		fi
	}
	
	local nginx_entry=$(extract_and_validate \
				"${latest_file}" \
				"${downloads_dir}/output" \
				"*${nginx_config[name]}*") || return 1
	
	echo "${nginx_entry}"
}

# 获取pcre源码版本
fetch_pcre_source()
{
	local downloads_dir=$1
	
	# 获取文件
	local latest_file
	latest_file=$(find_latest_archive "${downloads_dir}" "pcre*.tar.gz") || {
		local json_config=$(jq -n \
			--arg type "github" \
			--arg repo "PCRE2Project/pcre2" \
			--arg asset_matcher \
				"[[ \$name =~ \\.tar\\.gz\$ ]] && 
				 [[ ! \$name =~ \\.tar\\.gz\\. ]]" \
			'{
				type: $type,
				repo: $repo,
				asset_matcher: $asset_matcher
			}')
			
		if ! latest_file=$(download_package "${json_config}" "${downloads_dir}"); then
			return $?
		fi
	}
	
	local pcre_entry=$(extract_and_validate \
				"${latest_file}" \
				"${downloads_dir}/output" \
				"*pcre*") || return 1
	
	echo "${pcre_entry}"
}

# 编译安装nginx源码
setup_nginx_source()
{
	echo "[INFO] 编译${nginx_config[name]}源码"
	local paths=("$@")
	
	local nginx_path="${paths[0]}"
	local pcre_path="${paths[1]}"
	
	# 进入nginx源码目录
	cd "${nginx_path}" || { echo "[ERROR] 无法进入${nginx_config[name]}源码目录: ${nginx_path}"; return 1; }
	
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
	./configure "${configure_options[@]}"
	
	if [[ $? -ne 0 ]]; then
        echo "[ERROR] ${nginx_config[name]}配置失败,请检查!"
        return 1
    fi
	
	# 编译并安装
    echo "[INFO] 正在编译${nginx_config[name]}..."
	make -j$(nproc)
	
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] ${nginx_config[name]}编译失败,请检查!"
        return 1
    fi
	
	echo "[INFO] 正在安装${nginx_config[name]}..."
    make install
	
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] ${nginx_config[name]}安装失败,请检查！"
        return 1
    fi
	
	return 0
}

# 安装nginx环境
install_nginx_env()
{
	local arg=$1
	echo "[INFO] 安装${nginx_config[name]}服务..."
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	if [ "$arg" = "init" ]; then
		if [ ! -d "${install_dir}/${nginx_config[name]}" ]; then
			# 获取nginx源码路径
			local nginx_path=$(fetch_nginx_source "${downloads_dir}")
		
			# 获取pcre源码路径
			local pcre_path=$(fetch_pcre_source "${downloads_dir}")
		
			[[ -z ${nginx_path} || -z ${pcre_path} ]] && { echo "[ERROR] 获取${nginx_config[name]}源码失败，请检查！" >&2; return 1; }
		
			# 参数数组
			local source_array=("${nginx_path}" "${pcre_path}")
		
			# 编译nginx源码
			if ! setup_nginx_source "${source_array[@]}"; then
				echo "[ERROR] 编译${nginx_config[name]}源码失败,请检查!"
				return 1
			fi
			
			# 安装二进制文件
			install_binary "${nginx_config[sys_path]}" "${install_dir}" || return 1
		fi
	elif [ "$arg" = "config" ]; then
		if [ ! -e "${nginx_config[bin_file]}" ]; then
			# 安装二进制文件
			install_binary "${install_dir}/${nginx_config[name]}" \
						"${nginx_config[sys_path]}" \
						"/usr/local/bin/${nginx_config[name]}" || return 1
		fi
	fi
	
	echo "[INFO] 编译${nginx_config[name]}完成!"
	return 0
}

# 检查nginx配置
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
        if (has_http && has_server) { print 0 }     # 完整配置
        else if (has_http)          { print 1 }     # 仅有http块
		else if (has_server)        { print 2 }     # server块不在http内
        else                        { print 3 }     # 无有效块
    }
	
    ' "$conf_file")

    return $status_code
}

# 设置nginx配置
set_nginx_conf()
{
	if [ ! -f "${nginx_config[conf_file]}" ]; then
		return
	fi
	
	# 修改端口
	set_port() {
		local target_file="$1"
		
		# 安全转义端口
        local safe_port=$(sed 's/[\/&]/\\&/g' <<< "${nginx_config[port]}")
		
		# 执行替换
		sed -i -E \
        -e "/^[[:space:]]*listen[[:space:]]*/ { 
            s/^([[:space:]]*listen[[:space:]]+)((([0-9]{1,3}\\.){3}[0-9]{1,3}:)?[0-9]+)?([^;]*)([;]?)/\1\4${safe_port}\5;/ 
            t 
            s//\1${safe_port};/ 
        }" "${target_file}"
		
        if [ $? -eq 0 ]; then
			echo "[INFO] ${nginx_config[name]}端口修改成功!"
        else
			echo "[ERROR] ${nginx_config[name]}端口修改失败!"
        fi
	}
	
	check_process() {
		local target_file=$1
		[ ! -f "${target_file}" ] && return 1
		
		check_nginx_conf "${target_file}"
		local ret=$?
		
		echo "[INFO] 检查配置文件${target_file}状态:${ret}"	
		case "${ret}" in
			0|2)  set_port "${target_file}"; return 0;; # 正常配置
			1)  return 1 ;;	# 仅有http块
			*)  return 2 ;;	# 无效配置
		esac
	}
	
	# 检查处理文件
    check_process "${nginx_config[conf_file]}" || \
	check_process "${nginx_config[conf_file]%/*}/extra/www.conf"
}

# 设置nginx环境
set_nginx_env()
{
	echo "[INFO] 设置${nginx_config[name]}服务..."
	
	if [ "$arg" = "config" ]; then
		if [[ -d "${system_config[conf_dir]}/${nginx_config[name]}" && \
			  -f "${system_config[conf_dir]}/${nginx_config[name]}/${nginx_config[name]}.conf" ]]; then

			[ -f "${nginx_config[conf_file]}" ] && mv -f "${nginx_config[conf_file]}" "${nginx_config[conf_file]}.bak"

			mkdir -p "${nginx_config[conf_file]%/*}" && \
			cp -rf "${system_config[conf_dir]}/${nginx_config[name]}/"* "${nginx_config[conf_file]%/*}"
		fi
		
		mkdir -p "${nginx_config[sys_path]}/temp"
		echo "[INFO] ${nginx_config[name]}配置文件:${nginx_config[conf_file]}"
		
		# 设置nginx配置
		set_nginx_conf
	fi

	echo "[INFO] ${nginx_config[name]}设置完成!"
}

# 初始化nginx环境
init_nginx_env()
{
	local arg=$1
	echo "[INFO] 初始化${nginx_config[name]}服务..."
	
	# 安装nginx环境
	if ! install_nginx_env "${arg}"; then
		return 1
	fi
	
	# 设置nginx环境
	set_nginx_env "${arg}"
	
	echo "[INFO] 初始化${nginx_config[name]}服务成功!"
	return 0
}

# 运行nginx服务
run_nginx_service()
{
	echo "[INFO] 运行${nginx_config[name]}服务..."

	if [ ! -e "${nginx_config[bin_file]}" ] || [ ! -e "${nginx_config[conf_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务运行失败,请检查!"
		return
	fi

	# 检查服务是否已运行
	if pgrep -f "${nginx_config[name]}" > /dev/null; then
		echo "[WARNING] ${nginx_config[name]}服务已经在运行!"
		return
	fi
	
	# 后台运行nginx
	nohup ${nginx_config[bin_file]} -c ${nginx_config[conf_file]} > /dev/null 2>&1 &
	
	# 等待 2 秒
	sleep 2
	
	echo "[INFO] 启动${nginx_config[name]}服务成功!"
}

# 停止snginx服务
close_nginx_service()
{
	echo "[INFO] 关闭${nginx_config[name]}服务..."
	
	if [ ! -e "${nginx_config[bin_file]}" ]; then
		echo "[ERROR] ${nginx_config[name]}服务不存在,请检查!"
		return
	fi
	
	for PID in $(pidof ${nginx_config[name]}); do
		echo "[INFO] ${nginx_config[name]}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${nginx_config[name]}服务成功!"
}