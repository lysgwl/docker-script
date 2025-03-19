#!/bin/bash

# syncthing服务
SYNCTHING_SERVICE_NAME="syncthing"

# syncthing服务端口
SYNCTHING_HTTP_PORT=${SYNCTHING_HTTP_PORT:-8384}

# syncthing传输端口
SYNCTHING_TRANS_PORT=${SYNCTHING_TRANS_PORT:-22000}

# syncthing缺省密码
SYNCTHING_DEFAULT_PASSWD="123456"

# syncthing配置目录
SYNCTHING_PRIVATE_ETC="${SYSTEM_CONFIG_DIR}/${SYNCTHING_SERVICE_NAME}"

# syncthing数据目录
SYNCTHING_PRIVATE_DATA="${SYSTEM_DATA_DIR}/${SYNCTHING_SERVICE_NAME}"

# syncthing安装路径
SYNCTHING_SYSTEM_PATH="/usr/local/bin"

# syncthing进程标识路径
SYNCTHING_PID_PATH="/var/run/${SYNCTHING_SERVICE_NAME}"

# syncthing服务进程标识
SYNCTHING_PID_FILE="${SYNCTHING_PID_PATH}/${SYNCTHING_SERVICE_NAME}.pid"

# syncthing运行文件
SYNCTHING_BIN_FILE="${SYNCTHING_SYSTEM_PATH}/${SYNCTHING_SERVICE_NAME}"

# syncthing配置文件
SYNCTHING_CONFIG_FILE="${SYNCTHING_PRIVATE_ETC}/config.xml"

# syncthing下载文件
SYNCTHING_DOWNLOADS_FILE=""

# syncthing版本URL
SYNCTHING_VERSION_URL="https://api.github.com/repos/syncthing/syncthing/releases/latest"

# 下载syncthing安装包
download_syncthing()
{
	echo "下载${SYNCTHING_SERVICE_NAME}安装包"
	
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
			arch="arm"
			;;
		*)
			echo "Unsupported architecture: $arch"
			return 1
			;;
	esac
	
	# 系统信息
	local system_type=$SYSTEM_TYPE
	
	# 获取最新release信息
	local latest_release=$(curl -s "${SYNCTHING_VERSION_URL}")
	
	# 获取最新版本号
	local latest_tag=$(echo $latest_release | jq -r '.tag_name')
	
	# assets信息
	local assets=$(echo $latest_release | jq -r '.assets[] | @base64')
	
	if [ -z "$latest_tag" ] || [ -z "$assets" ]; then
		echo "无法获取${SYNCTHING_SERVICE_NAME}版本信息, 请检查!"
		return 1
	fi
	
	# syncthing下载URL
	local syncthing_download_url=""

	# 遍历assets数组，寻找匹配的文件
	for asset in $assets; do
		_jq() {
			echo ${asset} | base64 --decode | jq -r ${1}
		}
		
		name=$(_jq '.name')
		url=$(_jq '.browser_download_url')
		
		# 根据系统和架构匹配文件名
		if [[ "$name" == *"${system_type}"* && "$name" == *"${arch}"* ]]; then
			syncthing_download_url=$url
			break
		fi
	done

	echo "下载URL:${syncthing_download_url}"
	
	if [ -z "${syncthing_download_url}" ]; then
		echo "无法获取${SYNCTHING_SERVICE_NAME}下载URL, 请检查!"
		return 1
	fi
	
	echo "正在下载${SYNCTHING_SERVICE_NAME}..."
	
	# syncthing下载文件
	SYNCTHING_DOWNLOADS_FILE="${WORK_DOWNLOADS_DIR}/${SYNCTHING_SERVICE_NAME}-${system_type}-${arch}-${latest_tag}.tar.gz"
	
	# 下载syncthing
	curl -L -o "${SYNCTHING_DOWNLOADS_FILE}" "${syncthing_download_url}" >/dev/null 2>&1
	
	if [ ! -f "${SYNCTHING_DOWNLOADS_FILE}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}下载失败，请检查!"
		return 1
	fi
	
	echo "下载${SYNCTHING_SERVICE_NAME}完成!"
	return 0
}

# 安装syncthing环境
install_syncthing_env()
{
	echo "安装${SYNCTHING_SERVICE_NAME}服务环境..."
	
	# 检索文件列表
	local fileList=$(find "${WORK_DOWNLOADS_DIR}" -name "${SYNCTHING_SERVICE_NAME}*.tar.gz" | sort -s | tail -n 1)
	
	# 获取文件压缩包
	local filePath=""
	if [ -n "${fileList}" ]; then
		filePath="${fileList}"
	else
		
		if ! download_syncthing; then
			return 1
		fi
		
		filePath="${SYNCTHING_DOWNLOADS_FILE}"
	fi
	
	if [ ! -f "${filePath}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}压缩文件不存在,请检查!"
		return 1
	fi
	
	if [ -d "${SYNCTHING_BIN_FILE}" ]; then
		rm -rf "${SYNCTHING_BIN_FILE}"
	fi
	
	echo "正在安装${SYNCTHING_SERVICE_NAME}..."

	# 解压 syncthing
	if ! tar -zxvf "${filePath}" -C "${WORK_DOWNLOADS_DIR}" >/dev/null 2>&1; then
		echo "${SYNCTHING_SERVICE_NAME}安装失败，请检查!"
			
		rm -f "${filePath}"
		return 1
	fi
	
	local syncthing_dir=$(find "${WORK_DOWNLOADS_DIR}" -type d -name "${SYNCTHING_SERVICE_NAME}-${SYSTEM_TYPE}*")
	if [ -z "${syncthing_dir}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}安装文件出错，请检查!"
		
		rm -f "${filePath}"
		return 1
	fi
	
	# 查找syncthing文件
	if [ ! -f "${syncthing_dir}/${SYNCTHING_SERVICE_NAME}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}文件不存在，请检查!"
		
		rm -f "${filePath}"
		return 1
	fi
	
	cp -rf "${syncthing_dir}/${SYNCTHING_SERVICE_NAME}" "${SYNCTHING_SYSTEM_PATH}"
	rm -rf "${syncthing_dir}"

	echo "安装${SYNCTHING_SERVICE_NAME}完成!"
	return 0
}

# 设置syncthing配置
set_syncthing_conf()
{
	echo "设置${SYNCTHING_SERVICE_NAME}配置文件..."
	
	if [ ! -f "${SYNCTHING_CONFIG_FILE}" ]; then
		#echo '<?xml version="1.0" encoding="UTF-8"?><configuration version="37"></configuration>' > "${SYNCTHING_CONFIG_FILE}"

		"${SYNCTHING_BIN_FILE}" generate \
			--home="${SYNCTHING_PRIVATE_ETC}" \
			--gui-user="admin" \
			--gui-password="${SYNCTHING_DEFAULT_PASSWD}"
		if [ $? -ne 0 ]; then
			echo "${SYNCTHING_SERVICE_NAME}配置文件生成失败, 请检查!"
			return 1
		fi
	fi
	
	# 等待3次，每次5秒
	for ((retry=3; retry>0; retry--)); do
	  [ -f "${SYNCTHING_CONFIG_FILE}" ] && break
	  sleep 5
	done
	
	echo "${SYNCTHING_SERVICE_NAME}配置文件:${SYNCTHING_CONFIG_FILE}"
	
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
			echo "${SYNCTHING_SERVICE_NAME} GUI配置失败, 请检查!"
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
            echo "${SYNCTHING_SERVICE_NAME}全局选项配置失败, 请检查!"
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
            echo "${SYNCTHING_SERVICE_NAME}文件夹配置失败, 请检查!"
            return 1
        }		
	fi
	
	echo "设置${SYNCTHING_SERVICE_NAME}配置完成!"
	return 0
}

# 设置syncthing用户
set_syncthing_user()
{
	echo "设置${SYNCTHING_SERVICE_NAME}用户权限..."
	
	mkdir -p "${SYNCTHING_PID_PATH}"
	
	chown -R ${SERVICE_APP_USER}:${SERVICE_APP_GROUP} \
        "${SYNCTHING_PRIVATE_ETC}" \
        "${SYNCTHING_PRIVATE_DATA}" \
		"${SYNCTHING_PID_PATH}"
		
	chmod 750 \
        "${SYNCTHING_PRIVATE_ETC}" \
        "${SYNCTHING_PRIVATE_DATA}" \
		"${SYNCTHING_PID_PATH}"

	echo "设置${SYNCTHING_SERVICE_NAME}权限完成!"
	return 0		
}

# 设置syncthing环境
set_syncthing_env()
{
	echo "设置${SYNCTHING_SERVICE_NAME}服务环境..."

	mkdir -p "${SYNCTHING_PRIVATE_ETC}" "${SYNCTHING_PRIVATE_DATA}"
	
	# 设置syncthing配置
	if ! set_syncthing_conf; then
		return 1
	fi
	
	# 设置syncthing用户
	if ! set_syncthing_user; then
		return 1
	fi

	echo "设置${SYNCTHING_SERVICE_NAME}完成!"
	return 0
}

# 初始化syncthing环境
init_syncthing_env()
{
	local arg=$1
	echo "【初始化${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ -e "${SYNCTHING_BIN_FILE}" ]; then
		return 0
	fi
	
	if [ "$arg" = "init" ]; then
		# 设置安装路径
		SYNCTHING_SYSTEM_PATH="${WORK_INSTALL_DIR}"
		
		# 安装syncthing环境
		if ! install_syncthing_env; then
			return 1
		fi
	elif [ "$arg" = "config" ]; then
		if [ ! -f "${WORK_INSTALL_DIR}/${SYNCTHING_SERVICE_NAME}" ]; then
			echo "安装目录中无法找到${SYNCTHING_SERVICE_NAME}!"
			return 1
		else
			cp "${WORK_INSTALL_DIR}/${SYNCTHING_SERVICE_NAME}" "${SYNCTHING_SYSTEM_PATH}"
			chmod +x "${SYNCTHING_BIN_FILE}"
		fi
		
		# 设置syncthing环境
		if ! set_syncthing_env; then
			return 1
		fi
	fi
	
	echo "初始化${SYNCTHING_SERVICE_NAME}服务成功!"
	return 0
}

# 运行syncthing服务
run_syncthing_service()
{
	echo "【运行${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ ! -x "${SYNCTHING_BIN_FILE}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}服务运行失败,请检查!"
		return
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
				echo "${SYNCTHING_SERVICE_NAME}服务已经在运行(PID:${pid}), 请检查!"
				return
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
        echo "${SYNCTHING_SERVICE_NAME}服务启动失败, 请检查!"
        return 1
    fi
	
	echo "${syncthing_pid}" > "${SYNCTHING_PID_FILE}"
	echo "启动${SYNCTHING_SERVICE_NAME}服务成功!"
}

# 停止syncthing服务
close_syncthing_service()
{
	echo "【关闭${SYNCTHING_SERVICE_NAME}服务】"
	
	if [ ! -x "${SYNCTHING_BIN_FILE}" ]; then
		echo "${SYNCTHING_SERVICE_NAME}服务不存在,请检查!"
		return
	fi
	
	# 检查syncthing服务进程
	if [ -e "${SYNCTHING_PID_FILE}" ]; then
		# 关闭syncthingt服务进程
		for PID in $(cat "${SYNCTHING_PID_FILE}"); do
			echo "${SYNCTHING_SERVICE_NAME}服务进程:${PID}"
			kill $PID
		done
		
		rm -rf "${SYNCTHING_PID_FILE}"
	fi
	
	for PID in $(pidof ${SYNCTHING_SERVICE_NAME}); do
		echo "${SYNCTHING_SERVICE_NAME}服务进程:${PID}"
		kill $PID
	done
	
	echo "关闭${SYNCTHING_SERVICE_NAME}服务成功!"
}