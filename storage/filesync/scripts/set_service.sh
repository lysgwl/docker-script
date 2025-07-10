#!/bin/bash

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定时计划
readonly UPDATE_CHECK_SCHEDULE="*/1 * * * *"

# 初始标识
readonly RUN_FIRST_LOCK="/var/run/run_init_flag.pid"

# 更新标识
readonly RUN_UPDATE_LOCK="/var/run/run_update_flag.pid"

# 定义用户配置数组
declare -A user_config=(
	["uid"]="${PUID:-0}"
	["gid"]="${PGID:-0}"
	["user"]="${USERNAME:-root}"
	["group"]="${GROUPNAME:-root}"
)

# 定义 SSHD 配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["usr_dir"]="/mnt/usr"							# 用户目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
)

umask ${UMASK:-022}

# 加载 feature 脚本
source $WORK_DIR/scripts/feature.sh

readonly -A user_config
readonly -A sshd_config
readonly -A system_config

# 设置系统用户
set_service_user()
{
	echo "[INFO] 设置系统用户"
	
	# 创建用户目录
	echo "[DEBUG] 正在创建用户目录"
	mkdir -p "${system_config[downloads_dir]}" \
			 "${system_config[install_dir]}" \
			 "${system_config[config_dir]}" \
			 "${system_config[data_dir]}" \
			 "${system_config[usr_dir]}"
	
	# 设置目录拥有者
	echo "[DEBUG] 正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} \
			"${system_config[config_dir]}" \
			"${system_config[data_dir]}"
			
	chown "${user_config[user]}:${user_config[group]}" \
			"${system_config[usr_dir]}"
			
	echo "[INFO] 设置用户完成!"
}

# 设置系统配置
set_service_conf()
{
	echo "[INFO] 设置系统配置文件"
	
	# nginx 应用配置
	local target_dir="${system_config[conf_dir]}"
	local dest_dir="${system_config[config_dir]}/nginx/extra/proxy-config"
	
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
		if [[ ! -d "$dest_dir" ]] ||  ! rsync -av --remove-source-files --include='*.conf' --exclude='*' "$target_dir"/ "$dest_dir"/ >/dev/null; then
			echo "[ERROR] nginx 配置文件设置失败, 请检查!"
			return 1
		fi
	fi
	
	# nginx server配置
	local target_file="${system_config[config_dir]}/nginx/extra/www.conf"
	if [[ -f "$target_file" ]]; then
		local reference_content=$(cat <<'EOF'
root   html;
index  index.html index.htm player.html;
EOF
		)

		local new_content=$(cat <<'EOF'
proxy_pass http://filesync:8080;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
EOF
		)

		modify_nginx_location "$target_file" "/" "$reference_content" "$new_content" true
	fi
	
	return 0
}

# 设置服务
set_service_env()
{
	local arg=$1
	echo "[INFO] 设置系统服务"
	
	# 设置系统用户
	set_service_user
	
	if [ "$arg" = "config" ]; then
: <<'COMMENT_BLOCK'
		# 设置SSH服务
		local params=("${sshd_config[port]}" "${sshd_config[listen]}" "${sshd_config[confile]}" "${sshd_config[hostkey]}")
		if ! set_ssh_service "${params[@]}"; then
			return 1
		fi
COMMENT_BLOCK

		# 设置系统配置
		set_service_conf
		
		# 设置 root 用户密码
		echo "root:$ROOT_PASSWORD" | chpasswd
	fi

	echo "[INFO] 设置服务完成!"
	return 0
}

# 初始化服务
init_service()
{
	local arg=$1
	echo "[INFO] 初始化系统服务"
	
	# 设置服务
	if ! set_service_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化系统服务成功!"
	return 0
}

# 运行服务
run_service()
{
	echo "[INFO] 运行系统服务"
	
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd > /dev/null; then
		echo "[INFO] 正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${sshd_config[logfile]}"

		#nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${sshd_config[logfile]}"
	fi
	
	echo "[INFO] 启动系统服务成功!"
}

# 停止服务
close_service()
{
	echo "[INFO] 关闭系统服务"
	
	if pgrep -x "sshd" > /dev/null; then
		echo "[INFO] sshd服务即将关闭中..."
		killall -q "sshd"
	fi
	
	echo "[INFO] 关闭系统服务成功!"
}