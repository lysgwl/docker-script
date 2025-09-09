#!/bin/bash

# 定义 verysync 配置数组
declare -A verysync_config=(
	["name"]="verysync"			# 服务名称
	["passwd"]="123456"			# 缺省密码
	["http_port"]="${VERYSYNC_HTTP_PORT:-8886}"				# WEB 端口号
	["trans_port"]="${VERYSYNC_TRANS_PORT:-22330}"			# 传输端口号
	["etc_path"]="${system_config[config_dir]}/verysync"	# 配置目录
	["data_path"]="${system_config[data_dir]}/verysync"		# 数据目录
	["sys_path"]="/usr/local/verysync"						# 安装路径
	["pid_path"]="/var/run/verysync"						# 标识路径
	["bin_file"]="/usr/local/verysync/verysync"				# 运行文件
	["log_file"]="${system_config[data_dir]}/verysync/verysync.log"		# 日志文件
	["conf_file"]="${system_config[config_dir]}/verysync/config.xml"	# 配置文件
)

readonly -A verysync_config

# 下载 verysync 安装包
download_verysync()
{
	local downloads_dir=$1
	echo "[INFO] 下载${verysync_config[name]}安装包" >&2
	
	local name="${verysync_config[name]}"
	local url="https://www.verysync.com/download.php?platform=linux-amd64"
	
	local json_config=$(jq -n \
		--arg type "static" \
		--arg name "$name" \
		--arg url "$url" \
		'{
			type: $type,
			name: $name,
			url: $url
		}')
		
	# 调用下载函数
	local latest_file
	if ! latest_file=$(download_package "$json_config" "$downloads_dir"); then
		return 2
	fi
	
	echo "$latest_file"
}

# 安装 verysync 环境
install_verysync_env()
{
	local arg=$1
	echo "[INFO] 安装${verysync_config[name]}服务环境"
	
	local target_path="${system_config[install_dir]}/${verysync_config[name]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "$target_path" ]; then
			local downloads_dir="${system_config[downloads_dir]}"
			
			# 获取安装包
			local latest_path
			latest_path=$(get_service_archive "${verysync_config[name]}" "$downloads_dir" download_verysync) || {
				echo "[ERROR] 获取 ${verysync_config[name]} 安装包失败,请检查!" >&2
				return 1
			}
			
			# 安装软件包
			install_binary "$latest_path" "$target_path" || {
				echo "[ERROR] 安装 ${verysync_config[name]} 失败,请检查!" >&2
				return 2
			}
					
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [[ ! -d "${verysync_config[sys_path]}" || ! -e "${verysync_config[bin_file]}" ]]; then
			local install_dir=$(dirname "${verysync_config[sys_path]}")
			
			# 安装软件包
			install_binary "$target_path" "$install_dir" || {
				echo "[ERROR] 安装 ${verysync_config[name]} 失败,请检查!" >&2
				return 2
			}
			
			# 创建符号链接
			install_binary "${verysync_config[bin_file]}" "" "$install_dir/bin/${verysync_config[name]}" || {
				echo "[ERROR] 创建 ${verysync_config[name]} 符号链接失败,请检查" >&2
				return 4
			}
			
			# 清理临时文件
			rm -rf "$target_path"
		fi
	fi

	echo "[INFO] 安装${verysync_config[name]}完成!"
	return 0
}

# 设置 verysync 配置
set_verysync_conf()
{
	echo "[INFO] 设置${verysync_config[name]}配置文件"
	
	if [ ! -f "${verysync_config[bin_file]}" ]; then
		echo "[ERROR] ${verysync_config[name]}可执行文件不存在,请检查!" >&2
		return 1
	fi
	
	# 生成配置
	"${verysync_config[bin_file]}" generate \
			--config="${verysync_config[etc_path]}" \
			--gui-user="admin" \
			--gui-password="${verysync_config[passwd]}"
	if [ $? -ne 0 ]; then
		echo "[ERROR] ${verysync_config[name]}配置文件生成失败, 请检查!" >&2
		return 2
	fi
	
	echo "[INFO] 设置${verysync_config[name]}配置完成!"
	return 0
}

# 设置 verysync 用户
set_verysync_user()
{
	echo "[INFO] 设置${verysync_config[name]}用户权限"
	mkdir -p "${verysync_config[pid_path]}"
	
	chown -R ${user_config[user]}:${user_config[group]} \
		"${verysync_config[sys_path]}" \
		"${verysync_config[etc_path]}" \
		"${verysync_config[data_path]}" \
		"${verysync_config[pid_path]}" 2>/dev/null || return 1

	echo "[INFO] 设置${verysync_config[name]}权限完成!"
	return 0
}

# 设置 verysync 环境
set_verysync_env()
{
	local arg=$1
	echo "[INFO] 设置${verysync_config[name]}服务环境"

	if [ "$arg" = "config" ]; then
		# 创建环境目录
		mkdir -p "${verysync_config[etc_path]}" "${verysync_config[data_path]}"
		
		# 设置 verysync 配置
		if ! set_verysync_conf; then
			return 1
		fi
		
		# 设置 verysync 用户
		if ! set_verysync_user; then
			return 1
		fi
	fi

	echo "[INFO] 设置${verysync_config[name]}完成!"
	return 0
}

# 初始化 verysync 环境
init_verysync_service()
{
	local arg=$1
	echo "[INFO] 初始化${verysync_config[name]}服务"
	
	# 安装 verysync 环境
	if ! install_verysync_env "$arg"; then
		return 1
	fi
	
	# 设置 verysync 环境
	if ! set_verysync_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${verysync_config[name]}服务成功!"
	return 0
}

# 运行 verysync 服务
run_verysync_service()
{
	echo "[INFO] 运行${verysync_config[name]}服务"
	
	if [ ! -e "${verysync_config[bin_file]}" ]; then
		echo "[ERROR] ${verysync_config[name]}服务运行失败,请检查!" >&2
		return 1
	fi
	
	# 标识文件
	local pid_file="${verysync_config[pid_path]}/${verysync_config[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${verysync_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${verysync_config[name]}服务已经在运行(PID:$pid), 请检查!" >&2
				return 0
			fi
		fi
	fi
	
	# 后台运行 verysync 服务		# sudo -u ${SERVICE_APP_USER} --
	nohup "${verysync_config[bin_file]}" \
			--config "${verysync_config[etc_path]}" \
			--data "${verysync_config[data_path]}" \
			--no-browser \
			--gui-address="0.0.0.0:${verysync_config[http_port]}" \
			--logfile="${verysync_config[log_file]}" \
			> /dev/null 2>&1 &

	# 获取后台进程的 PID
	local verysync_pid=$!

	# 等待 PID 生效
	if ! wait_for_pid 10 "$verysync_pid"; then
		return 1
	fi
	
	# 启动端口检测
	if ! wait_for_ports "${verysync_config[http_port]}" "${verysync_config[trans_port]}"; then
		echo "[ERROR] ${verysync_config[name]}端口未就绪,查看服务日志!" >&2
		return 1
	fi
	
	echo "$verysync_pid" > "$pid_file"
	echo "[INFO] 启动${verysync_config[name]}服务成功!"
}

# 更新 verysync 服务
update_verysync_service()
{
	echo "[INFO] 更新${verysync_config[name]}服务"
	local downloads_dir="${system_config[usr_dir]}/downloads"
	
	# 获取安装包
	local latest_path
	latest_path=$(get_service_archive "${verysync_config[name]}" "$downloads_dir" download_verysync) || {
		echo "[ERROR] 获取 ${verysync_config[name]} 安装包失败" >&2
		return 1
	}
	
	# 安装软件包
	if [ ! -f "${verysync_config[bin_file]}" ]; then
		install_binary "$latest_path" "${verysync_config[bin_file]}" "/usr/local/bin/${verysync_config[name]}" || {
			echo "[ERROR] 安装 ${verysync_config[name]} 失败" >&2
			return 2
		}
		return 0
	fi
	
	local current_version=$(${verysync_config[bin_file]} --version | awk '{print $2}' | tr -d 'v')
	local new_version=$($latest_path --version | awk '{print $2}' | tr -d 'v')
	
	# 版本比较
	compare_versions "$new_version" "$current_version"
	local result=$?
	
	case $result in
		0)
			echo "[INFO] ${verysync_config[name]} 已是最新版本 (v$current_version)"
			return 0 
			;;
		1)
			# 停止 verysync 运行
			close_verysync_service
			
			# 安装软件包
			install_binary "$latest_path" "${verysync_config[bin_file]}" || {
				echo "[ERROR] 更新 ${verysync_config[name]} 失败" >&2
				return 3
			}
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
			
			echo "[INFO] ${verysync_config[name]} 已更新至 v$new_version"
			return 0
			;;
		2)
			echo "[INFO] 当前版本 (v$current_version) 比下载版本 (v$new_version) 更高"
			return 0
			;;
		*)
			echo "[ERROR] 版本比较异常 $current_version -> $new_version" >&2
			return 2
			;;
	esac
}

# 停止 verysync 服务
close_verysync_service()
{
	echo "[INFO] 关闭${verysync_config[name]}服务"
	
	if [ ! -x "${verysync_config[bin_file]}" ]; then
		echo "[ERROR] ${verysync_config[name]}服务不存在,请检查!" >&2
		return
	fi
	
	# 标识文件
	local pid_file="${verysync_config[pid_path]}/${verysync_config[name]}.pid"
	
	# 检查 verysync 服务进程
	if [ -f "$pid_file" ]; then
		# 关闭 verysync 服务进程
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${verysync_config[name]}服务进程:$PID"
			kill "$PID"
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${verysync_config[name]}); do
		echo "[INFO] ${verysync_config[name]}服务进程:$PID"
		kill "$PID"
	done
	
	echo "[INFO] 关闭${verysync_config[name]}服务成功!"
}