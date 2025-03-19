#!/bin/bash

# alist服务
ALIST_SERVICE_NAME="alist"

# alist服务端口号
ALIST_HTTP_PORT=${ALIST_HTTP_PORT:-5244}

# alist缺省密码
ALIST_DEFAULT_PASSWD="123456"

# alist的musl版本
ALIST_USE_MUSL=false

# alist配置目录
ALIST_PRIVATE_ETC="${SYSTEM_CONFIG_DIR}/${ALIST_SERVICE_NAME}"

# alist数据目录
ALIST_PRIVATE_DATA="${SYSTEM_DATA_DIR}/${ALIST_SERVICE_NAME}"

# alist安装路径
ALIST_SYSTEM_PATH="/usr/local/bin"

# alist进程标识路径
ALIST_PID_PATH="/var/run/${ALIST_SERVICE_NAME}"

# alist服务进程标识
ALIST_PID_FILE="${ALIST_PID_PATH}/${ALIST_SERVICE_NAME}.pid"

# alist运行文件
ALIST_BIN_FILE="${ALIST_SYSTEM_PATH}/${ALIST_SERVICE_NAME}"

# alist配置文件
ALIST_CONFIG_FILE="${ALIST_PRIVATE_ETC}/config.json"

# alist下载文件
ALIST_DOWNLOADS_FILE=""

# alist版本URL
ALIST_VERSION_URL="https://api.github.com/repos/AlistGo/alist/releases/latest"

# 下载alist安装包
download_alist()
{
	echo "下载${ALIST_SERVICE_NAME}安装包"
	
	# 架构信息
	local arch=$SYSTEM_ARCH
	case ${arch} in
		x86_64)
			arch="amd64"
			;;
		aarch64)
			arch="arm64"
			;;
		armv7l)
			arch="armv7"
			;;
		*)
			echo "Unsupported architecture: $arch"
			return 1
			;;
	esac
	
	# 系统信息
	local system_type=$SYSTEM_TYPE
	if [ "${system_type}" == "linux" ]; then
		if [ -f "/etc/os-release" ]; then
			. /etc/os-release
			if [ "$ID" == "alpine" ]; then
				ALIST_USE_MUSL=true
			fi
		fi
	fi
	
	# 获取最新release信息
	local latest_release=$(curl -s "${ALIST_VERSION_URL}")
	
	# 获取最新版本号
	local latest_tag=$(echo $latest_release | jq -r '.tag_name')
	
	# assets信息
	local assets=$(echo $latest_release | jq -r '.assets[] | @base64')
	
	if [ -z "$latest_tag" ] || [ -z "$assets" ]; then
		echo "无法获取${ALIST_SERVICE_NAME}版本信息, 请检查!"
		return 1
	fi
	
	# alist下载URL
	local alist_download_url=""

	# 遍历assets数组，寻找匹配的文件
	for asset in $assets; do
		_jq() {
			echo ${asset} | base64 --decode | jq -r ${1}
		}
		
		name=$(_jq '.name')
		url=$(_jq '.browser_download_url')
		
		# 根据系统和架构匹配文件名
		if [[ "$name" == *"${system_type}"*  && "$name" == *"${ARCH}"* ]]; then
			if [[ ${ALIST_USE_MUSL} = true  && "$name" == *"musl"* ]]; then
				alist_download_url=$url
				break
			elif [[ ${ALIST_USE_MUSL} = false ]]; then
				alist_download_url=$url
				break
			fi
		fi
	done

	echo "下载URL:${alist_download_url}"
	
	if [ -z "${alist_download_url}" ]; then
		echo "无法获取${ALIST_SERVICE_NAME}下载URL, 请检查!"
		return 1
	fi
	
	echo "正在下载${ALIST_SERVICE_NAME}..."
	
	# 下载 alist
	ALIST_DOWNLOADS_FILE="${WORK_DOWNLOADS_DIR}/${ALIST_SERVICE_NAME}-${system_type}-${arch}-${latest_tag}.tar.gz"
	curl -L -o "${ALIST_DOWNLOADS_FILE}" "${alist_download_url}" >/dev/null 2>&1
	
	if [ ! -f "${ALIST_DOWNLOADS_FILE}" ]; then
		echo "${ALIST_SERVICE_NAME}下载失败，请检查!"
		return 1
	fi
	
	echo "下载${ALIST_SERVICE_NAME}完成!"
	return 0
}

# 安装alist环境
install_alist_env()
{
	echo "安装${ALIST_SERVICE_NAME}服务环境..."
	
	# 检索文件列表
	local fileList=$(find "${WORK_DOWNLOADS_DIR}" -name "${ALIST_SERVICE_NAME}*.tar.gz" | sort -s | tail -n 1)
	
	# 获取文件压缩包
	local filePath=""
	if [ -n "${fileList}" ]; then
		filePath="${fileList}"
	else
		
		if ! download_alist; then
			return 1
		fi
		
		filePath="${ALIST_DOWNLOADS_FILE}"
	fi
	
	if [ ! -f "${filePath}" ]; then
		echo "${ALIST_SERVICE_NAME}压缩文件不存在,请检查!"
		return 1
	fi
	
	if [ -d "${ALIST_BIN_FILE}" ]; then
		rm -rf "${ALIST_BIN_FILE}"
	fi
	
	echo "正在安装${ALIST_SERVICE_NAME}..."
	
	# 解压 alist
	if ! tar -xzvf "${filePath}" -C "${ALIST_SYSTEM_PATH}" >/dev/null 2>&1; then
		echo "${ALIST_SERVICE_NAME}安装失败，请检查!"
		
		rm -f "${filePath}"
		return 1
	fi
	
	# 清理压缩包
	rm -f "${filePath}"
	
	echo "安装${ALIST_SERVICE_NAME}完成!"
	return 0
}

# 设置alist配置
set_alist_conf()
{
	echo "设置${ALIST_SERVICE_NAME}配置文件..."
	local jwt_secret=`openssl rand -base64 16`

	local tmp_dir="${ALIST_PRIVATE_DATA}/temp"
	if [ ! -d "${tmp_dir}" ]; then
		mkdir -p ${tmp_dir}
	fi
	
	local bleve_dir="${ALIST_PRIVATE_DATA}/bleve"
	if [ ! -d "${bleve_dir}" ]; then
		mkdir -p ${bleve_dir}
	fi
	
	local log_dir="${ALIST_PRIVATE_DATA}/log"
	if [ ! -d "${log_dir}" ]; then
		mkdir -p ${log_dir}
	fi
	
	local db_file="${ALIST_PRIVATE_DATA}/data.db"
	local log_file="${log_dir}/log.log"
	
	# alist 默认配置
	if [ ! -e "${ALIST_CONFIG_FILE}" ]; then
		echo "${ALIST_SERVICE_NAME}配置文件:${ALIST_CONFIG_FILE}"
		
		cat <<EOF > "${ALIST_CONFIG_FILE}"
{
    "force": false,
    "site_url": "/${ALIST_SERVICE_NAME}",
    "cdn": "",
    "jwt_secret": "${jwt_secret}",
    "token_expires_in": 48,
    "database": {
        "type": "sqlite3",
        "host": "",
        "port": 0,
        "user": "",
        "password": "",
        "name": "",
        "db_file": "${db_file}",
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
        "http_port": ${ALIST_HTTP_PORT},
        "https_port": -1,
        "force_https": false,
        "cert_file": "",
        "key_file": "",
        "unix_file": "",
        "unix_file_perm": ""
    },
    "temp_dir": "${tmp_dir}",
    "bleve_dir": "${bleve_dir}",
    "dist_dir": "",
    "log": {
        "enable": true,
        "name": "${log_file}",
        "max_size": 10,
        "max_backups": 5,
        "max_age": 28,
        "compress": false
    },
    "delayed_start": 0,
    "max_connections": 0,
    "tls_insecure_skip_verify": true,
    "tasks": {
        "download": {
            "workers": 5,
            "max_retry": 1,
            "task_persistant": true
        },
        "transfer": {
            "workers": 5,
            "max_retry": 2,
            "task_persistant": true
        },
        "upload": {
            "workers": 5,
            "max_retry": 0,
            "task_persistant": false
        },
        "copy": {
            "workers": 5,
            "max_retry": 2,
            "task_persistant": true
        }
    },
    "cors": {
        "allow_origins": ["*"],
        "allow_methods": ["*"],
        "allow_headers": ["*"]
    },
    "s3": {
        "enable": false,
        "port": 5246,
        "ssl": false
    }
}
EOF
	fi
	
	echo "设置${ALIST_SERVICE_NAME}配置完成!"
}

# 设置alist用户
set_alist_user()
{
	echo "设置${ALIST_SERVICE_NAME}用户权限..."
	
	mkdir -p "${ALIST_PID_PATH}"
	
	chown -R ${SERVICE_APP_USER}:${SERVICE_APP_GROUP} \
        "${ALIST_PRIVATE_ETC}" \
        "${ALIST_PRIVATE_DATA}" \
		"${ALIST_PID_PATH}"
		
	chmod 750 \
        "${ALIST_PRIVATE_ETC}" \
        "${ALIST_PRIVATE_DATA}" \
		"${ALIST_PID_PATH}"

	echo "设置${ALIST_SERVICE_NAME}权限完成!"
	return 0		
}

# 设置alist环境
set_alist_env()
{
	echo "设置${ALIST_SERVICE_NAME}服务配置..."
	
	mkdir -p "${ALIST_PRIVATE_ETC}" "${ALIST_PRIVATE_DATA}"
	
	# 设置alist配置
	set_alist_conf
	
	# 设置alist用户
	if ! set_alist_user; then
		return 1
	fi
	
	# 查看alist管理员密码
	su-exec ${SERVICE_APP_USER} "${ALIST_BIN_FILE}" admin --data "${ALIST_PRIVATE_ETC}"
	
	# 设置alist缺省密码	
	su-exec ${SERVICE_APP_USER} "${ALIST_BIN_FILE}" admin --data "${ALIST_PRIVATE_ETC}" set "${ALIST_DEFAULT_PASSWD}"
	
	echo "设置${ALIST_SERVICE_NAME}完成!"
	return 0
}

# 初始化alist环境
init_alist_env()
{
	local arg=$1
	echo "【初始化${ALIST_SERVICE_NAME}服务】"
	
	if [ -e "${ALIST_BIN_FILE}" ]; then
		return 0
	fi
	
	if [ "$arg" = "init" ]; then
		# 设置安装路径
		ALIST_SYSTEM_PATH="${WORK_INSTALL_DIR}"
		
		# 安装alist环境
		if ! install_alist_env; then
			return 1
		fi
	elif [ "$arg" = "config" ]; then
		if [ ! -f "${WORK_INSTALL_DIR}/${ALIST_SERVICE_NAME}" ]; then
			echo "安装目录中无法找到${ALIST_SERVICE_NAME}!"
			return 1
		else
			cp "${WORK_INSTALL_DIR}/${ALIST_SERVICE_NAME}" "${ALIST_SYSTEM_PATH}"
			chmod +x "${ALIST_BIN_FILE}"
		fi
		
		# 设置alist环境
		if ! set_alist_env; then
			return 1
		fi
	fi
	
	echo "初始化${ALIST_SERVICE_NAME}服务成功!"
	return 0
}

# 运行alist服务
run_alist_service()
{
	echo "【运行${ALIST_SERVICE_NAME}服务】"
	
	if [ ! -x "${ALIST_BIN_FILE}" ] && [ ! -e "${ALIST_PRIVATE_ETC}" ]; then
		echo "${ALIST_SERVICE_NAME}服务运行失败,请检查!"
		return
	fi
	
	# 检查服务是否已运行
	if [ -f "${ALIST_PID_FILE}" ]; then
		local pid=$(cat "${ALIST_PID_FILE}")
		if ! kill -0 "${pid}" >/dev/null 2>&1; then
			rm -f "${ALIST_PID_FILE}"
		else
			if ! grep -qF "${ALIST_SERVICE_NAME}" "/proc/${pid}/cmdline" 2>/dev/null; then
				rm -f "${ALIST_PID_FILE}"
			else
				echo "${ALIST_SERVICE_NAME}服务已经在运行!(PID:${pid})"
				return
			fi
		fi
	fi
	
	# 后台运行alist服务
	nohup "${ALIST_BIN_FILE}" server --data "${ALIST_PRIVATE_ETC}" &> /dev/null &
	
	# 获取后台进程的 PID
	local alist_pid=$!
	
	# 等待 2 秒
	sleep 2
	
	# 验证 PID 有效性
	if ! kill -0 "${alist_pid}" >/dev/null; then
        echo "${SYNCTHING_SERVICE_NAME}服务启动失败, 请检查!"
        return 1
    fi

	echo "${alist_pid}" > "${ALIST_PID_FILE}"
	echo "启动${ALIST_SERVICE_NAME}服务成功!"
}

# 停止alist服务
close_alist_service()
{
	echo "【关闭${ALIST_SERVICE_NAME}服务】"
	
	if [ ! -x "${ALIST_BIN_FILE}" ]; then
		echo "${ALIST_SERVICE_NAME}服务不存在,请检查!"
		return
	fi
	
	# 检查alist服务进程
	if [ -e "${ALIST_PID_FILE}" ]; then
		# 关闭alist服务进程
		for PID in $(cat "${ALIST_PID_FILE}"); do
			echo "${ALIST_SERVICE_NAME}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "${ALIST_PID_FILE}"
	fi
	
	for PID in $(pidof ${ALIST_SERVICE_NAME}); do
		echo "${ALIST_SERVICE_NAME}服务进程:${PID}"
		kill $PID
	done
	
	echo "关闭${ALIST_SERVICE_NAME}服务成功!"
}