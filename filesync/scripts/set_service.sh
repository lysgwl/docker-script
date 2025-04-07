#!/bin/bash

# ssh端口号
readonly SSHD_PORT=${SSHD_PORT:-8022}

# ssh监听地址
readonly SSHD_LISTEN_ADDRESS="0.0.0.0"

# ssh秘钥key文件
readonly SSHD_RSAKEY="/etc/ssh/ssh_host_rsa_key"

# root用户密码
readonly ROOT_PASSWORD="123456"

# app用户
readonly SERVICE_APP_USER=${APP_USER:-appuser}

# app用户组
readonly SERVICE_APP_GROUP=${APP_GROUP:-appgroup}

# 默认app UID
readonly SERVICE_APP_UID=${APP_UID:-1000}

# 默认app GID
readonly SERVICE_APP_GID=${APP_GID:-1000}

# 安装服务
install_service_env()
{
	local arg=$1
	echo "[INFO] 安装系统服务..."
	
	case "$arg" in
		"init")
			# 编译选项
			apk add --no-cache build-base linux-headers pcre-dev zlib-dev openssl-dev libaio-dev
			;;
		"config")
			# ssh服务
			apk add --no-cache openssh openssh-server-pam shadow
			
			# 其他工具
			apk add --no-cache netcat-openbsd
			;;
	esac
	
	echo "[INFO] 安装服务完成!"
}

# 设置SSH服务
set_ssh_service()
{
	echo "[INFO] 设置SSH服务"
	
	local sshd_config="/etc/ssh/sshd_config"
	if [ ! -f "${sshd_config}" ]; then
		echo "[ERROR] SSH服务没有安装,请检查!"
		return 1
	fi
	
	# 备份配置
    cp -f "${sshd_config}" "${sshd_config}.bak"
	
	# 设置ssh端口号
	if [ -n "${SSHD_PORT}" ]; then
		ssh_port=$(grep -E '^(#?)Port [[:digit:]]*$' "${sshd_config}")
		if [ -n "${ssh_port}" ]; then
			sed -E -i "s/^(#?)Port [[:digit:]]*$/Port ${SSHD_PORT}/" "${sshd_config}"
		else
			echo -e "Port ${SSHD_PORT}" >> "${sshd_config}"
		fi
	else
		sed -i -E '/^Port[[:space:]]+[0-9]+/s/^/#/' "${sshd_config}"
	fi
	
	# 设置监听IP地址
	if [ -n "${SSHD_LISTEN_ADDRESS}" ]; then
		# grep -Po '^.*ListenAddress\s+([^\s]+)' "${sshd_config}" | grep -Po '([0-9]{1,3}\.){3}[0-9]{1,3}'
		# grep -Eo '^.*ListenAddress[[:space:]]+([^[:space:]]+)' ${sshd_config} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
		ipv4_address=$(awk '/ListenAddress[[:space:]]+/ {print $2}' ${sshd_config} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		if [ -n "${ipv4_address}" ]; then
			sed -i -E 's/^(\s*)#?(ListenAddress)\s+([0-9]{1,3}\.){3}[0-9]{1,3}/\1\2 '"${SSHD_LISTEN_ADDRESS}"'/' "${sshd_config}"
		else
			echo "ListenAddress ${SSHD_LISTEN_ADDRESS}" >> "${sshd_config}"
		fi
	else
		sed -i -E '/^ListenAddress\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/s/^/#/' "${sshd_config}"
	fi
	
	# 设置ssh密钥KEY
	if [ ! -f "${SSHD_RSAKEY}" ]; then
		ssh-keygen -t rsa -N "" -f "${SSHD_RSAKEY}"
	fi
	
	# 注释密钥ssh_host_ecdsa_key
	if [ -z "`sed -n '/^#.*HostKey .*ecdsa_key/p' ${sshd_config}`" ]; then
		sed -i '/^HostKey .*ecdsa_key$/s/^/#/' "${sshd_config}"
	fi
	
	# 注释密钥ssh_host_ed25519_key
	if [ -z "`sed -n '/^#.*HostKey .*ed25519_key/p' ${sshd_config}`" ]; then
		sed -i '/^HostKey .*ed25519_key$/s/^/#/' "${sshd_config}"
	fi
	
	# 设置PermitRootLogin管理员权限登录
	if grep -q -E "^#?PermitRootLogin" "${sshd_config}"; then
		sed -i -E 's/^(#?PermitRootLogin).*/PermitRootLogin yes/' "${sshd_config}"
	else
		echo "PermitRootLogin yes" >> "${sshd_config}"
	fi
	
	# 设置PasswordAuthentication密码身份验证
	if grep -q -E "^#?PasswordAuthentication" "${sshd_config}"; then
		sed -i -E 's/^(#?PasswordAuthentication).*/PasswordAuthentication yes/' "${sshd_config}"
	else
		echo "PasswordAuthentication yes" >> "${sshd_config}"
	fi
	
	# 设置SSHD进程pid文件路径
	if [ -z "$(awk '/#PidFile /{getline a; print a}' "${sshd_config}" | sed -n '/^PidFile \/var\/run\/sshd.pid/p')" ]; then
		sed -i '/^#PidFile / a\PidFile \/var\/run\/sshd.pid' "${sshd_config}"
	fi
	
	ssh_dir="/root/.ssh"
	if [ ! -d "${ssh_dir}" ]; then
		mkdir -p "${ssh_dir}"
	fi
	
	chmod 700 "${ssh_dir}"
	
	echo "[INFO] 设置SSH完成!"
	return 0
}

# 设置系统用户
set_service_user()
{
	echo "[INFO] 设置系统用户..."
	
	# 创建组
    if ! getent group ${SERVICE_APP_GROUP} >/dev/null; then
        addgroup -g ${SERVICE_APP_GID} ${SERVICE_APP_GROUP} || {
            echo "[ERROR] 无法创建组${SERVICE_APP_GROUP}, 请检查!"
            return 1
        }
    fi
	
	# 创建用户
	if ! id -u ${SERVICE_APP_USER} >/dev/null 2>&1; then
        adduser -D -H -G ${SERVICE_APP_GROUP} -u ${SERVICE_APP_UID} ${SERVICE_APP_USER} || {
            echo "[ERROR] 无法创建用户${SERVICE_APP_USER}, 请检查!"
            return 1
        }
    fi
	
	# 设置目录权限
	mkdir -p "${SYSTEM_CONFIG_DIR}" "${SYSTEM_DATA_DIR}" "${SYSTEM_USR_DIR}"
	chown -R ${SERVICE_APP_USER}:${SERVICE_APP_GROUP} "${SYSTEM_CONFIG_DIR}" "${SYSTEM_DATA_DIR}" "${SYSTEM_USR_DIR}"
	chmod 755 "${SYSTEM_CONFIG_DIR}" "${SYSTEM_DATA_DIR}" "${SYSTEM_USR_DIR}"
	
	return 0
}

# 设置服务
set_service_env()
{
	local arg=$1
	echo "[INFO] 设置系统服务..."
	
	if [ "$arg" = "init" ]; then
		# 下载目录
		mkdir -p "${WORK_DOWNLOADS_DIR}"
	
		# 安装目录
		mkdir -p "${WORK_INSTALL_DIR}"
		
	elif [ "$arg" = "config" ]; then
		# 设置SSH服务
		if ! set_ssh_service; then
			return 1
		fi
		
		# 设置root用户密码
		echo "root:${ROOT_PASSWORD}" | chpasswd
		
		# 设置系统用户
		if ! set_service_user; then
			return 1
		fi
	fi

	echo "[INFO] 设置服务完成!"
	return 0
}

# 初始化服务
init_service_env()
{
	local arg=$1
	echo "【初始化系统服务】"
	
	# 安装服务
	install_service_env "${arg}"
	
	# 设置服务
	if ! set_service_env "${arg}"; then
		return 1
	fi
	
	# nginx服务
	if ! init_nginx_env "${arg}"; then
		return 1
	fi

	echo "[INFO] 初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	echo "【运行系统服务】"
	
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd > /dev/null; then
		echo "[INFO] 正在启动服务sshd..."
		# exec /usr/sbin/sshd -D
		nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
	fi
	
	# 启动 nginx 服务
	run_nginx_service
	
	echo "[INFO] 启动系统服务成功!"
}

# 停止服务
close_service()
{
	echo "【关闭系统服务】"
	
	if pgrep -x "sshd" > /dev/null; then
		echo "[INFO] sshd服务即将关闭中..."
		killall -q "sshd"
	fi
	
	# 关闭 nginx 服务
	close_nginx_service
	
	echo "[INFO] 关闭系统服务成功!"
}