#!/bin/bash

# nginx服务
NGINX_SERVICE_NAME="nginx"

# nginx服务端口号
NGINX_HTTP_PORT=${HTTP_PORT:-80}

# nginx安装路径
NGINX_SYSTEM_PATH="/usr/local/${NGINX_SERVICE_NAME}"

# nginx运行文件
NGINX_BIN_FILE="${NGINX_SYSTEM_PATH}/sbin/${NGINX_SERVICE_NAME}"

# nginx配置目录
NGINX_ETC_FILE="${NGINX_SYSTEM_PATH}/conf/${NGINX_SERVICE_NAME}.conf"

# nginx进程标识
NGINX_PID_FILE="${NGINX_SYSTEM_PATH}/logs/${NGINX_SERVICE_NAME}.pid"

# nginx锁文件
NGINX_LOCK_FILE="${NGINX_SYSTEM_PATH}/logs/${NGINX_SERVICE_NAME}.lock"

# nginx错误日志
NGINX_ERROR_FILE="${NGINX_SYSTEM_PATH}/logs/error.log"

# nginx运行日志
NGINX_ACCESS_FILE="${NGINX_SYSTEM_PATH}/logs/access.log"

# nginx下载文件
NGINX_DOWNLOADS_FILE=""

# nginx版本号
NGINX_VERSION="1.26.3"

# 获取nginx源码版本
fetch_nginx_source()
{
	echo "获取${NGINX_SERVICE_NAME}源码文件"
	
	# 检索文件列表
	local fileList=$(find "${WORK_DOWNLOADS_DIR}" -name "${NGINX_SERVICE_NAME}*.tar.gz" | sort -s | tail -n 1)
	
	# 获取文件压缩包
	local filePath=""
	
	if [ -z "${fileList}" ]; then
		# nginx版本号
		local version_tag="${NGINX_VERSION}"
		
		# nginx下载url
		local downloads_url="https://nginx.org/download/${NGINX_SERVICE_NAME}-${version_tag}.tar.gz"
		
		echo "${NGINX_SERVICE_NAME}下载URL:${downloads_url}"
		
		if [ -z "${downloads_url}" ]; then
			echo "无法获取${NGINX_SERVICE_NAME}下载URL, 请检查!"
			return 1
		fi
		
		echo "正在下载${NGINX_SERVICE_NAME}..."
		
		# nginx下载文件
		filePath="${WORK_DOWNLOADS_DIR}/${NGINX_SERVICE_NAME}-${version_tag}.tar.gz"
		
		# 下载nginx 
		curl -L -o "${filePath}" "${downloads_url}" >/dev/null 2>&1
	else
		filePath="${fileList}"
	fi
	
	if [ ! -f "${filePath}" ]; then
		echo "${NGINX_SERVICE_NAME}源码文件不存在,请检查!"
		return 1
	fi
	
	tar -xzvf "${filePath}" -C "${WORK_DOWNLOADS_DIR}" >/dev/null 2>&1
		
	echo "获取${NGINX_SERVICE_NAME}源码完成!"
	return 0
}

# 获取pcre源码版本
fetch_pcre_source()
{
	echo "获取PCRE源码文件"
	
	# 检索文件列表
	local fileList=$(find "${WORK_DOWNLOADS_DIR}" -name "pcre*.tar.gz" | sort -s | tail -n 1)
	
	# 获取文件压缩包
	local filePath=""
	
	if [ -z "${fileList}" ]; then
		# pcre版本url
		local pcre_version_url="https://api.github.com/repos/PCRE2Project/pcre2/releases/latest"
		
		# 获取最新release信息
		local latest_release=$(curl -s "${pcre_version_url}")
		
		# 获取最新版本号
		local latest_tag=$(echo $latest_release | jq -r '.tag_name')
		
		# assets信息
		local assets=$(echo $latest_release | jq -r '.assets[] | @base64')
		
		if [ -z "$latest_tag" ] || [ -z "$assets" ]; then
			echo "无法获取pcre版本信息, 请检查!"
			return 1
		fi
		
		# pcre下载url
		local downloads_url=""
		
		# 遍历assets数组，寻找匹配的文件
		for asset in $assets; do
			_jq() {
				echo ${asset} | base64 --decode | jq -r ${1}
			}
			
			name=$(_jq '.name')
			url=$(_jq '.browser_download_url')
			
			# 根据系统和架构匹配文件名
			if [[ "$name" =~ \.tar\.gz$ ]] && [[ ! "$name" =~ \.tar\.gz\. ]]; then
				downloads_url=$url
			fi
		done
		
		echo "PCRE下载URL:${downloads_url}"
		
		if [ -z "${downloads_url}" ]; then
			echo "无法获取pcre下载URL, 请检查!"
			return 1
		fi
		
		echo "正在下载PCRE..."
		
		# pcre下载文件
		filePath="${WORK_DOWNLOADS_DIR}/${latest_tag}.tar.gz"
		
		# 下载nginx 
		curl -L -o "${filePath}" "${downloads_url}" >/dev/null 2>&1
	else
		filePath="${fileList}"
	fi
	
	if [ ! -f "${filePath}" ]; then
		echo "pcre源码文件不存在,请检查!"
		return 1
	fi
	
	tar -xzvf "${filePath}" -C "${WORK_DOWNLOADS_DIR}" >/dev/null 2>&1
	
	echo "获取PCRE源码完成!"
	return 0
}

# 编译安装nginx源码
setup_nginx_source()
{
	echo "编译${NGINX_SERVICE_NAME}源码文件"
	local paths=("$@")
	
	local nginx_path="${paths[0]}"
	local pcre_path="${paths[1]}"
	
	# 进入nginx源码目录
	cd "${nginx_path}" || { echo "无法进入${NGINX_SERVICE_NAME}源码目录: ${nginx_path}"; return 1; }
	
	local configure_options=(
		--prefix=${NGINX_SYSTEM_PATH}
		--sbin-path=${NGINX_BIN_FILE}
		--conf-path=${NGINX_ETC_FILE}
		--pid-path=${NGINX_PID_FILE}
		--lock-path=${NGINX_LOCK_FILE}
		--error-log-path=${NGINX_ERROR_FILE}
		--http-log-path=${NGINX_ACCESS_FILE}
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
		--http-client-body-temp-path=${NGINX_SYSTEM_PATH}/temp/client_body_temp
		--http-proxy-temp-path=${NGINX_SYSTEM_PATH}/temp/proxy_temp
		--http-fastcgi-temp-path=${NGINX_SYSTEM_PATH}/temp/fastcgi_temp
		--http-scgi-temp-path=${NGINX_SYSTEM_PATH}/temp/scgi_temp
		--http-uwsgi-temp-path=${NGINX_SYSTEM_PATH}/temp/uwsgi_temp
		--with-mail
		--with-mail_ssl_module
		--with-stream
		--with-stream_ssl_module
		--with-stream_realip_module
		--with-stream_ssl_preread_module
	)
	
	# 执行配置命令
	 echo "正在配置${NGINX_SERVICE_NAME}..."
	./configure "${configure_options[@]}"
	
	if [[ $? -ne 0 ]]; then
        echo "${NGINX_SERVICE_NAME}配置失败,请检查!"
        return 1
    fi
	
	# 编译并安装
    echo "正在编译${NGINX_SERVICE_NAME}..."
	make -j$(nproc)
	
    if [[ $? -ne 0 ]]; then
        echo "${NGINX_SERVICE_NAME}编译失败,请检查!"
        return 1
    fi
	
	echo "正在安装${NGINX_SERVICE_NAME}..."
    make install
	
    if [[ $? -ne 0 ]]; then
        echo "${NGINX_SERVICE_NAME}安装失败,请检查！"
        return 1
    fi
	
	return 0
}

# 安装nginx环境
build_nginx_env()
{
	local copy_path=$1
	echo "编译${NGINX_SERVICE_NAME}服务..."
	
	if ! fetch_nginx_source; then
		return 1
	fi
	
	if ! fetch_pcre_source; then
		return 1
	fi
	
	# 获取nginx源码路径
	local nginx_path=$(find ${WORK_DOWNLOADS_DIR} -maxdepth 1 -type d -name "*${NGINX_SERVICE_NAME}*")
	
	# 获取pcre源码路径
	local pcre_path=$(find ${WORK_DOWNLOADS_DIR} -maxdepth 1 -type d -name "*pcre*")
	
	if [ -z "${nginx_path}" ] || [ -z "${pcre_path}" ]; then
		echo "${NGINX_SERVICE_NAME}源码路径为空,请检查!"
		return 1
	fi
	
	# 参数数组
	local source_array=("${nginx_path}" "${pcre_path}")
	
	# 编译nginx源码
	if ! setup_nginx_source "${source_array[@]}"; then
		echo "编译${NGINX_SERVICE_NAME}源码失败,请检查!"
		return 1
	fi
	
	# 备份nginx安装目录
	cp -rf "${NGINX_SYSTEM_PATH}" "${copy_path}"
	
	echo "编译${NGINX_SERVICE_NAME}完成!"
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
                    print "错误：http块未闭合" > "/dev/stderr"
                } else if (current_block == "server") {
                    print "错误：server块未闭合" > "/dev/stderr"
                } else {
                    printf "错误：%s块未闭合\n", current_block > "/dev/stderr"
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
	if [ ! -f "${NGINX_ETC_FILE}" ]; then
		return
	fi
	
	# 修改端口
	set_port() {
		local target_file="$1"
		
		# 安全转义端口
        local safe_port=$(sed 's/[\/&]/\\&/g' <<< "${NGINX_HTTP_PORT}")
		
		# 执行替换
		sed -i -E \
        -e "/^[[:space:]]*listen[[:space:]]*/ { 
            s/^([[:space:]]*listen[[:space:]]+)((([0-9]{1,3}\\.){3}[0-9]{1,3}:)?[0-9]+)?([^;]*)([;]?)/\1\4${safe_port}\5;/ 
            t 
            s//\1${safe_port};/ 
        }" "${target_file}"
		
        if [ $? -eq 0 ]; then
			echo "${NGINX_SERVICE_NAME}端口修改成功!"
        else
			echo "${NGINX_SERVICE_NAME}端口修改失败!"
        fi
	}
	
	check_process() {
		local target_file=$1
		[ ! -f "${target_file}" ] && return 1
		
		check_nginx_conf "${target_file}"
		local ret=$?
		
		echo "检查配置文件${target_file}状态:${ret}"	
		case "${ret}" in
			0|2)  set_port "${target_file}"; return 0;; # 正常配置
			1)  return 1 ;;	# 仅有http块
			*)  return 2 ;;	# 无效配置
		esac
	}
	
	# 检查处理文件
    check_process "${NGINX_ETC_FILE}" || \
	check_process "${NGINX_ETC_FILE%/*}/extra/www.conf"
}

# 设置nginx环境
set_nginx_env()
{
	echo "设置${NGINX_SERVICE_NAME}服务..."
	
	if [[ -d "${WORK_CONFIG_DIR}/${NGINX_SERVICE_NAME}" && \
		  -f "${WORK_CONFIG_DIR}/${NGINX_SERVICE_NAME}/${NGINX_SERVICE_NAME}.conf" ]]; then

		[ -f "${NGINX_ETC_FILE}" ] && mv -f "${NGINX_ETC_FILE}" "${NGINX_ETC_FILE}.bak"

		mkdir -p "${NGINX_ETC_FILE%/*}" && \
		cp -rf "${WORK_CONFIG_DIR}/${NGINX_SERVICE_NAME}/"* "${NGINX_ETC_FILE%/*}"
	fi
	
	echo "${NGINX_SERVICE_NAME}配置文件:${NGINX_ETC_FILE}"
	set_nginx_conf
	
	echo "${NGINX_SERVICE_NAME}设置完成!"
}

# 初始化nginx环境
init_nginx_env()
{
	local arg=$1
	echo "初始化${NGINX_SERVICE_NAME}服务..."
	
	if [ -e "${NGINX_SYSTEM_PATH}" ] && [ -e "${NGINX_BIN_FILE}" ]; then
		return 0
	fi
	
	if [ "$arg" = "init" ]; then
		# 安装nginx环境
		if ! build_nginx_env "${WORK_INSTALL_DIR}"; then
			return 1
		fi
	elif [ "$arg" = "config" ]; then
		if [ ! -d "${WORK_INSTALL_DIR}/${NGINX_SERVICE_NAME}" ]; then
			echo "安装目录中无法找到${NGINX_SERVICE_NAME}!"
			return 1
		else
			cp -rf "${WORK_INSTALL_DIR}/${NGINX_SERVICE_NAME}" "${NGINX_SYSTEM_PATH}"
		fi
		
		if [ ! -d "${NGINX_SYSTEM_PATH}/temp" ]; then
			mkdir -p "${NGINX_SYSTEM_PATH}/temp"
		fi
		
		# 设置nginx环境
		set_nginx_env
	fi
	
	echo "初始化${NGINX_SERVICE_NAME}服务成功!"
	return 0
}

# 运行nginx服务
run_nginx_service()
{
	echo "运行${NGINX_SERVICE_NAME}服务..."

	if [ ! -e "${NGINX_BIN_FILE}" ] || [ ! -e "${NGINX_ETC_FILE}" ]; then
		echo "${NGINX_SERVICE_NAME}服务运行失败,请检查!"
		return
	fi

	# 检查服务是否已运行
	if pgrep -f "${NGINX_SERVICE_NAME}" > /dev/null; then
		echo "${NGINX_SERVICE_NAME}服务已经在运行!"
		return
	fi
	
	# 后台运行nginx
	nohup ${NGINX_BIN_FILE} -c ${NGINX_ETC_FILE} > /dev/null 2>&1 &
	
	# 等待 2 秒
	sleep 2
	
	echo "启动${NGINX_SERVICE_NAME}服务成功!"
}

# 停止snginx服务
close_nginx_service()
{
	echo "关闭${NGINX_SERVICE_NAME}服务..."
	
	if [ ! -e "${NGINX_BIN_FILE}" ]; then
		echo "${NGINX_SERVICE_NAME}服务不存在,请检查!"
		return
	fi
	
	for PID in $(pidof ${NGINX_SERVICE_NAME}); do
		echo "${NGINX_SERVICE_NAME}服务进程:${PID}"
		kill $PID
	done
	
	echo "关闭${NGINX_SERVICE_NAME}服务成功!"
}