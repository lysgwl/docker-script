#!/bin/bash

# syncthing服务
readonly SYNCTHING_SERVICE_NAME="syncthing"

# syncthing服务端口
readonly SYNCTHING_HTTP_PORT=${SYNCTHING_HTTP_PORT:-8384}

# syncthing传输端口
readonly SYNCTHING_TRANS_PORT=${SYNCTHING_TRANS_PORT:-22000}

# syncthing缺省密码
readonly SYNCTHING_DEFAULT_PASSWD="123456"

# syncthing配置目录
readonly SYNCTHING_PRIVATE_ETC="${SYSTEM_CONFIG_DIR}/${SYNCTHING_SERVICE_NAME}"

# syncthing数据目录
readonly SYNCTHING_PRIVATE_DATA="${SYSTEM_DATA_DIR}/${SYNCTHING_SERVICE_NAME}"

# syncthing安装路径
readonly SYNCTHING_SYSTEM_PATH="/usr/local/${SYNCTHING_SERVICE_NAME}"

# syncthing进程标识路径
readonly SYNCTHING_PID_PATH="/var/run/${SYNCTHING_SERVICE_NAME}"

# syncthing服务进程标识
readonly SYNCTHING_PID_FILE="${SYNCTHING_PID_PATH}/${SYNCTHING_SERVICE_NAME}.pid"

# syncthing运行文件
readonly SYNCTHING_BIN_FILE="${SYNCTHING_SYSTEM_PATH}/${SYNCTHING_SERVICE_NAME}"

# syncthing配置文件
readonly SYNCTHING_CONFIG_FILE="${SYNCTHING_PRIVATE_ETC}/config.xml"

# 下载syncthing安装包
download_syncthing()
{
	# 动态生成配置
	local arch_map='{"x86_64":"amd64","aarch64":"arm64","armv7l":"arm"}'
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
	
	# 拼接条件（安全格式化）
	local asset_matcher
	asset_matcher=$(printf "%s && " "${matcher_conditions[@]}" | sed 's/ && $//')
	
	local syncthing_config=$(jq -n \
        --arg type "github" \
        --arg repo "syncthing/syncthing" \
        --argjson asset_matcher "$(printf '%s' "${asset_matcher}" | jq -Rs .)" \
        '{
            type: $type,
            repo: $repo,
            asset_matcher: $asset_matcher
        }')
		
	# 调用下载函数
	local syncthing_file
	if ! syncthing_file=$(download_package "${syncthing_config}" "${WORK_DOWNLOADS_DIR}"); then
		return 2
	fi
	
	echo "$syncthing_file"
	return 0
}

# 安装syncthing环境
install_syncthing_env()
{
	local arg=$1
	echo "[INFO] 安装${SYNCTHING_SERVICE_NAME}服务环境..."
	
	if [ "$arg" = "init" ]; then
		local install_dir="${WORK_INSTALL_DIR}"
		local downloads_dir="${WORK_DOWNLOADS_DIR}"
		
		# 获取文件
		local latest_file
		latest_file=$(find_latest_archive "${downloads_dir}" "${SYNCTHING_SERVICE_NAME}-*.tar.gz") || {
			latest_file=$(download_syncthing) || return 1
		}
		
		# 获取安装目录
		local syncthing_dir=$(extract_and_validate \
					"${latest_file}" \
					"${downloads_dir}/output" \
					"${SYNCTHING_SERVICE_NAME}-${SYSTEM_TYPE}-*" \
					"${SYNCTHING_SERVICE_NAME}") || return 2
					
		# 安装二进制文件
		install_binary "${syncthing_dir}/${SYNCTHING_SERVICE_NAME}" \
					"${install_dir}/${SYNCTHING_SERVICE_NAME}" || return 3
					
		# 清理临时文件
		rm -rf "${syncthing_dir}" "${latest_file}"	

	elif [ "$arg" = "config" ]; then
		# 安装二进制文件
		install_binary "${WORK_INSTALL_DIR}/${SYNCTHING_SERVICE_NAME}" \
					"${SYNCTHING_BIN_FILE}" \
					"/usr/local/bin/${SYNCTHING_SERVICE_NAME}" || return 3
	fi

	echo "[INFO] 安装${SYNCTHING_SERVICE_NAME}完成!"
	return 0
}

# 设置syncthing配置
set_syncthing_conf()
{
	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}配置文件..."
	
	if [ ! -f "${SYNCTHING_BIN_FILE}" ]; then
		echo "[ERROR] ${SYNCTHING_SERVICE_NAME}可执行文件不存在,请检查!"
		return 1
	fi
	
	if [ ! -f "${SYNCTHING_CONFIG_FILE}" ]; then
		#echo '<?xml version="1.0" encoding="UTF-8"?><configuration version="37"></configuration>' > "${SYNCTHING_CONFIG_FILE}"

		"${SYNCTHING_BIN_FILE}" generate \
			--home="${SYNCTHING_PRIVATE_ETC}" \
			--gui-user="admin" \
			--gui-password="${SYNCTHING_DEFAULT_PASSWD}"
		if [ $? -ne 0 ]; then
			echo "[ERROR] ${SYNCTHING_SERVICE_NAME}配置文件生成失败, 请检查!"
			return 1
		fi
	fi
	
	# 等待3次，每次5秒
	for ((retry=3; retry>0; retry--)); do
	  [ -f "${SYNCTHING_CONFIG_FILE}" ] && break
	  sleep 5
	done
	
	echo "[INFO] ${SYNCTHING_SERVICE_NAME}配置文件:${SYNCTHING_CONFIG_FILE}"
	
	# 修改 Syncthing 配置
	if [ -f "${SYNCTHING_CONFIG_FILE}" ]; then
		# 停止正在运行的进程
        pkill -f "${SYNCTHING_BIN_FILE}"
        sleep 2
		
		# GUI配置
		xmlstarlet ed -L \
			--subnode '/configuration[not(gui)]' -t elem -n 'gui' -v "" \
			--subnode '/configuration/gui[not(address)]' -t elem -n 'address' -v "" \
			--subnode '/configuration/gui[not(tls)]' -t elem -n 'tls' -v "" \
			--subnode '/configuration/gui[not(urlbase)]' -t elem -n 'urlbase' -v "" \
			-u '/configuration/gui/address' -v "0.0.0.0:${SYNCTHING_HTTP_PORT}" \
			-u '/configuration/gui/tls' -v "false" \
			-u '/configuration/gui/urlbase' -v "/syncthing" \
			"${SYNCTHING_CONFIG_FILE}" || {
			echo "[ERROR] ${SYNCTHING_SERVICE_NAME} GUI配置失败, 请检查!"
			return 1
		}
	
		# 全局选项配置
        local options_config=(
            # 格式："元素名:元素值"
            "globalAnnounceEnabled:false"
            "localAnnounceEnabled:true"
            "natEnabled:true"
            "urAccepted:2"
            "startBrowser:false"
            "listenAddresses:tcp://0.0.0.0:${SYNCTHING_TRANS_PORT}, quic://0.0.0.0:${SYNCTHING_TRANS_PORT}"
            "connectionLimitEnough:32"
            "connectionLimitMax:64"
            "maxSendKbps:0"
            "maxRecvKbps:0"
            "fsWatcherEnabled:true"
            "fsWatcherDelayS:5"
            "maxConcurrentWrites:4"
            "dbBlockCacheSize:8388608"
            "setLowPriority:true"
            "maxFolderConcurrency:4"
            "sendFullIndexOnUpgrade:false"
            "stunKeepaliveStartS:300"
        )

		local options_args=(-s '/configuration[not(options)]' -t elem -n 'options')
		for item in "${options_config[@]}"; do
            IFS=":" read -r name value <<< "$item"
            options_args+=(
                -s "/configuration/options[not($name)]" -t elem -n "$name" -v ""
                -u "/configuration/options/$name" -v "$value"
            )
        done
		
		xmlstarlet ed -L \
            "${options_args[@]}" \
            "${SYNCTHING_CONFIG_FILE}" || {
            echo "[ERROR] ${SYNCTHING_SERVICE_NAME}全局选项配置失败, 请检查!"
            return 1
        }
			
		# 文件夹配置
		xmlstarlet ed -L --pf \
            -s "/configuration[not(folder[@id='default'])]" -t elem -n "folder" \
            -i "/configuration/folder[last()][not(@id)]" -t attr -n "id" -v "default" \
            -i "/configuration/folder[@id='default'][not(@path)]" -t attr -n "path" -v "${SYNCTHING_PRIVATE_DATA}/default" \
            -u "/configuration/folder[@id='default']/@path" -v "${SYNCTHING_PRIVATE_DATA}/default" \
			-s "/configuration/folder[@id='default'][not(label)]" -t elem -n "label" -v "默认目录" \
            -s "/configuration/folder[@id='default'][not(minDiskFree)]" -t elem -n "minDiskFree" -v "5" \
            -s "/configuration/folder[@id='default'][not(copiers)]" -t elem -n "copiers" -v "4" \
            -s "/configuration/folder[@id='default'][not(pullerMaxPendingKiB)]" -t elem -n "pullerMaxPendingKiB" -v "102400" \
            "${SYNCTHING_CONFIG_FILE}" || {
            echo "[ERROR] ${SYNCTHING_SERVICE_NAME}文件夹配置失败, 请检查!"
            return 1
        }		
	fi
	
	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}配置完成!"
	return 0
}

# 设置syncthing用户
set_syncthing_user()
{
	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}用户权限..."
	
	mkdir -p "${SYNCTHING_PID_PATH}"
	
	chown -R ${SERVICE_APP_USER}:${SERVICE_APP_GROUP} \
		"${SYNCTHING_SYSTEM_PATH}" \
        "${SYNCTHING_PRIVATE_ETC}" \
        "${SYNCTHING_PRIVATE_DATA}" \
		"${SYNCTHING_PID_PATH}" 2>/dev/null || return 1
		
	chmod 750 \
		"${SYNCTHING_SYSTEM_PATH}" \
        "${SYNCTHING_PRIVATE_ETC}" \
        "${SYNCTHING_PRIVATE_DATA}" \
		"${SYNCTHING_PID_PATH}" 2>/dev/null || return 1

	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}权限完成!"
	return 0		
}

# 设置syncthing环境
set_syncthing_env()
{
	local arg=$1
	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}服务环境..."

	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${SYNCTHING_PRIVATE_ETC}" "${SYNCTHING_PRIVATE_DATA}"
		
		# 设置syncthing配置
		if ! set_syncthing_conf; then
			return 1
		fi
		
		# 设置syncthing用户
		if ! set_syncthing_user; then
			return 1
		fi
	fi

	echo "[INFO] 设置${SYNCTHING_SERVICE_NAME}完成!"
	return 0
}

# 初始化syncthing环境
init_syncthing_env()
{
	local arg=$1
	echo "【初始化${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ ! -e "${SYNCTHING_BIN_FILE}" ]; then
		# 安装syncthing环境
		if ! install_syncthing_env "$arg"; then
			return 1
		fi
		
		# 设置syncthing环境
		if ! set_syncthing_env "$arg"; then
			return 1
		fi
	fi
	
	echo "[INFO] 初始化${SYNCTHING_SERVICE_NAME}服务成功!"
	return 0
}

# 运行syncthing服务
run_syncthing_service()
{
	echo "【运行${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ ! -e "${SYNCTHING_BIN_FILE}" ]; then
		echo "[ERROR] ${SYNCTHING_SERVICE_NAME}服务运行失败,请检查!"
		return 1
	fi
	
	# 检查服务是否已运行
	if [ -f "${SYNCTHING_PID_FILE}" ]; then
		local pid=$(cat "${SYNCTHING_PID_FILE}")
		if ! kill -0 "${pid}" >/dev/null 2>&1; then
			rm -f "${SYNCTHING_PID_FILE}"
		else
			if ! grep -qF "${SYNCTHING_SERVICE_NAME}" "/proc/${pid}/cmdline" 2>/dev/null; then
				rm -f "${SYNCTHING_PID_FILE}"
			else
				echo "[WARNING] ${SYNCTHING_SERVICE_NAME}服务已经在运行(PID:${pid}), 请检查!"
				return 0
			fi
		fi
	fi
	
	# 后台运行syncthing服务		# sudo -u ${SERVICE_APP_USER} --
	nohup "${SYNCTHING_BIN_FILE}" \
			--config "${SYNCTHING_PRIVATE_ETC}" \
			--data "${SYNCTHING_PRIVATE_DATA}" \
			--no-browser \
			--gui-address="0.0.0.0:${SYNCTHING_HTTP_PORT}" \
			> "${SYNCTHING_PRIVATE_DATA}/${SYNCTHING_SERVICE_NAME}.log" 2>&1 &
	
	# 获取后台进程的 PID
	local syncthing_pid=$!

	# 等待 2 秒
	sleep 2
	
	# 验证 PID 有效性
	if ! kill -0 "${syncthing_pid}" >/dev/null; then
        echo "[ERROR] ${SYNCTHING_SERVICE_NAME}服务启动失败, 请检查!"
        return 1
    fi
	
	echo "${syncthing_pid}" > "${SYNCTHING_PID_FILE}"
	echo "[INFO] 启动${SYNCTHING_SERVICE_NAME}服务成功!"
}

# 停止syncthing服务
close_syncthing_service()
{
	echo "【关闭${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ ! -x "${SYNCTHING_BIN_FILE}" ]; then
		echo "[ERROR] ${SYNCTHING_SERVICE_NAME}服务不存在,请检查!"
		return
	fi
	
	# 检查syncthing服务进程
	if [ -e "${SYNCTHING_PID_FILE}" ]; then
		# 关闭syncthingt服务进程
		for PID in $(cat "${SYNCTHING_PID_FILE}"); do
			echo "[INFO] ${SYNCTHING_SERVICE_NAME}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "${SYNCTHING_PID_FILE}"
	fi
	
	for PID in $(pidof ${SYNCTHING_SERVICE_NAME}); do
		echo "[INFO] ${SYNCTHING_SERVICE_NAME}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${SYNCTHING_SERVICE_NAME}服务成功!"
}