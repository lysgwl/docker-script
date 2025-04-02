#!/bin/bash

# alist服务
readonly ALIST_SERVICE_NAME="alist"

# alist服务端口号
readonly ALIST_HTTP_PORT=${ALIST_HTTP_PORT:-5244}

# alist缺省密码
readonly ALIST_DEFAULT_PASSWD="123456"

# alist的musl版本
readonly ALIST_USE_MUSL=false

# alist配置目录
readonly ALIST_PRIVATE_ETC="${SYSTEM_CONFIG_DIR}/${ALIST_SERVICE_NAME}"

# alist数据目录
readonly ALIST_PRIVATE_DATA="${SYSTEM_DATA_DIR}/${ALIST_SERVICE_NAME}"

# alist安装路径
readonly ALIST_SYSTEM_PATH="/usr/local/${ALIST_SERVICE_NAME}"

# alist进程标识路径
readonly ALIST_PID_PATH="/var/run/${ALIST_SERVICE_NAME}"

# alist服务进程标识
readonly ALIST_PID_FILE="${ALIST_PID_PATH}/${ALIST_SERVICE_NAME}.pid"

# alist运行文件
readonly ALIST_BIN_FILE="${ALIST_SYSTEM_PATH}/${ALIST_SERVICE_NAME}"

# alist配置文件
readonly ALIST_CONFIG_FILE="${ALIST_PRIVATE_ETC}/config.json"

# 下载alist安装包
download_alist()
{
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"armv7"}'
	local mapped_arch=$(jq -r ".\"${SYSTEM_ARCH}\" // empty" <<< "$arch_map")
	
	if [ -z "$mapped_arch" ]; then
		echo "[ERROR] 不支持的架构${SYSTEM_ARCH},请检查!" >&2
		return 1
	fi
	
	# 动态生成匹配条件
    local matcher_conditions=(
        "[[ \$name =~ ${SYSTEM_TYPE} ]]"
        "[[ \$name =~ ${mapped_arch} ]]"
    )
	
	# 检测musl
    if { ldd --version 2>&1 || true; } | grep -q "musl"; then
        matcher_conditions+=("[[ \$name =~ musl ]]")
    fi
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local alist_config=$(jq -n \
        --arg type "github" \
        --arg repo "AlistGo/alist" \
        --argjson asset_matcher "$(printf '%s' "${asset_matcher}" | jq -Rs .)" \
        '{
            type: $type,
            repo: $repo,
            asset_matcher: $asset_matcher
        }')
	
	# 调用下载函数
	local alist_file
	if ! alist_file=$(download_package "${alist_config}" "${WORK_DOWNLOADS_DIR}"); then
		return 2
	fi
	
	echo "${alist_file}"
	return 0
}

# 安装alist环境
install_alist_env()
{
	local arg=$1
	echo "[INFO] 安装${ALIST_SERVICE_NAME}服务环境..."
	
	if [ "$arg" = "init" ]; then
		local install_dir="${WORK_INSTALL_DIR}"
		local downloads_dir="${WORK_DOWNLOADS_DIR}"
		
		# 获取文件
		local latest_file
		latest_file=$(find_latest_archive "${downloads_dir}" "${ALIST_SERVICE_NAME}-*.tar.gz") || {
			latest_file=$(download_alist) || return 1
		}
		
		# 获取安装文件
		local alist_file=$(extract_and_validate \
					"${latest_file}" \
					"${downloads_dir}/output" \
					"${ALIST_SERVICE_NAME}*" \
					"${ALIST_SERVICE_NAME}") || return 2
			
		# 安装二进制文件
		install_binary "${alist_file}" \
					"${install_dir}/${ALIST_SERVICE_NAME}" || return 3

		# 清理临时文件
		rm -rf "${alist_file}" "${latest_file}"				
		
	elif [ "$arg" = "config" ]; then
		# 安装二进制文件
		install_binary "${WORK_INSTALL_DIR}/${ALIST_SERVICE_NAME}" \
					"${ALIST_BIN_FILE}" \
					"/usr/local/bin/${ALIST_SERVICE_NAME}" || return 3
	fi

	echo "安装${ALIST_SERVICE_NAME}完成!"
	return 0
}

# 设置alist配置
set_alist_conf()
{
	echo "设置${ALIST_SERVICE_NAME}配置文件..."
	local jwt_secret=`openssl rand -base64 12`

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
    "max_size": 50,
    "max_backups": 30,
    "max_age": 28,
    "compress": false
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
  "last_launched_version": "AList version"
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
		"${ALIST_SYSTEM_PATH}" \
        "${ALIST_PRIVATE_ETC}" \
        "${ALIST_PRIVATE_DATA}" \
		"${ALIST_PID_PATH}" 2>/dev/null || return 1
		
	chmod 750 \
		"${ALIST_SYSTEM_PATH}" \
        "${ALIST_PRIVATE_ETC}" \
        "${ALIST_PRIVATE_DATA}" \
		"${ALIST_PID_PATH}" 2>/dev/null || return 1

	echo "设置${ALIST_SERVICE_NAME}权限完成!"
	return 0		
}

# 设置alist环境
set_alist_env()
{
	local arg=$1
	echo "设置${ALIST_SERVICE_NAME}服务配置..."
	
	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${ALIST_PRIVATE_ETC}" "${ALIST_PRIVATE_DATA}"
		
		# 设置alist配置
		set_alist_conf
		
		# 设置alist用户
		if ! set_alist_user; then
			return 1
		fi
		
		if [ ! -f "${ALIST_BIN_FILE}" ]; then
			echo "[ERROR] ${ALIST_SERVICE_NAME}可执行文件不存在,请检查!"
			return 1
		fi
		
		# 查看alist管理员密码
		su-exec ${SERVICE_APP_USER} "${ALIST_BIN_FILE}" admin --data "${ALIST_PRIVATE_ETC}"

		# 设置alist缺省密码	
		su-exec ${SERVICE_APP_USER} "${ALIST_BIN_FILE}" admin --data "${ALIST_PRIVATE_ETC}" set "${ALIST_DEFAULT_PASSWD}"
	fi

	echo "设置${ALIST_SERVICE_NAME}完成!"
	return 0
}

# 初始化alist环境
init_alist_env()
{
	local arg=$1
	echo "【初始化${ALIST_SERVICE_NAME}服务】"
	
	if [ ! -e "${ALIST_BIN_FILE}" ]; then
		# 安装alist环境
		if ! install_alist_env "$arg"; then
			return 1
		fi
		
		# 设置alist环境
		if ! set_alist_env "$arg"; then
			return 1
		fi
	fi
	
	echo "[INFO] 初始化${ALIST_SERVICE_NAME}服务成功!"
	return 0
}

# 运行alist服务
run_alist_service()
{
	echo "【运行${ALIST_SERVICE_NAME}服务】"
	
	if [ ! -e "${ALIST_BIN_FILE}" ] && [ ! -e "${ALIST_PRIVATE_ETC}" ]; then
		echo "[ERROR] ${ALIST_SERVICE_NAME}服务运行失败,请检查!"
		return 1
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
				echo "[WARNING] ${ALIST_SERVICE_NAME}服务已经在运行!(PID:${pid})"
				return 0
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
        echo "[ERROR] ${ALIST_SERVICE_NAME}服务启动失败, 请检查!"
        return 1
    fi

	echo "${alist_pid}" > "${ALIST_PID_FILE}"
	echo "[INFO] 启动${ALIST_SERVICE_NAME}服务成功!"
}

# 停止alist服务
close_alist_service()
{
	echo "【关闭${ALIST_SERVICE_NAME}服务】"
	
	if [ ! -x "${ALIST_BIN_FILE}" ]; then
		echo "[ERROR] ${ALIST_SERVICE_NAME}服务不存在,请检查!"
		return
	fi
	
	# 检查alist服务进程
	if [ -e "${ALIST_PID_FILE}" ]; then
		# 关闭alist服务进程
		for PID in $(cat "${ALIST_PID_FILE}"); do
			echo "[INFO] ${ALIST_SERVICE_NAME}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "${ALIST_PID_FILE}"
	fi
	
	for PID in $(pidof ${ALIST_SERVICE_NAME}); do
		echo "[INFO] ${ALIST_SERVICE_NAME}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${ALIST_SERVICE_NAME}服务成功!"
}