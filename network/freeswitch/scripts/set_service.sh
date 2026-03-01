#!/bin/bash

# 获取服务配置
get_service_config()
{
	local service="$1"
	local field="${2:-config}"
	local ref_name="${3:-SERVICE_CONFIG}"
	
	# 获取配置JSON
	local field_value
	field_value=$(get_service_field "$service" "$field" 2>/dev/null)
	
	if [[ -z "$field_value" ]] || [[ "$field_value" == "null" ]]; then
		logger "WARNING" "服务 $service 的 $field 配置信息为空"
		return 1
	fi
	
	# 声明全局数组
	declare -gA "$ref_name"
	local -n config_array="$ref_name"
	
	# 清空内容
	config_array=()
	
	if ! echo "$field_value" | jq empty >/dev/null 2>&1; then
		config_array["$field"]="$field_value"
	else
		# 判断 JSON 类型
		local json_type=$(echo "$field_value" | jq -r 'type')
		
		case "$json_type" in
			object)
				# 加载到数组
				while IFS="=" read -r key value; do
					[[ -n "$key" ]] && config_array["$key"]="$value"
				done < <(
					echo "$field_value" | jq -r 'to_entries[] | "\(.key)=\(.value)"'
				)
				;;
			*)
				config_array["$field"]="$field_value"
				;;
		esac
	fi
}

# 执行所有服务
execute_services_action()
{
	local action="$1"
	local param="${2:-}"
	
	local failed=0
	local services=()
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		# 检查服务是否启用
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		services+=("$service")
	done
	
	if [[ ${#services[@]} -eq 0 ]]; then
		logger "WARNING" "没有启用的服务需要执行"
		return 0
	fi
	
	for service in "${services[@]}"; do
		# 执行函数
		if ! execute_service_func "$service" "$action" "main" "$param"; then
			logger "ERROR" "[$action] 服务 $service 执行失败"
			failed=1
		fi
	done
	
	return $failed
}

# 等待所有服务进程
wait_for_services()
{
	local timeout="${1:-0}"			# 0表示无限等待
	local check_interval="${2:-5}"	# 检查间隔(秒)
	
	local start_time=$(date +%s)
	local exit_code=0
	
	# 等待循环
	while true; do
		local pending_count=0
		
		for service in "${!SERVICE_REGISTRY[@]}"; do
			# 检查服务是否启用
			! check_service_enabled "$service" && continue
		
			# 获取服务的操作状态
			local action=$(get_service_action "$service")
		
			# 获取服务的pid
			local pid=$(get_service_pid "$service" 2>/dev/null)
			
			# 检查服务存活
			if [[ -n "$pid" ]] && check_service_alive "$service" "$pid"; then
				pending_count=$((pending_count + 1))
				continue
			fi
			
			# 进程退出, 检查操作状态
			case "$action" in
				"${SERVICE_ACTIONS[UPDATE]}")
					logger "INFO" "服务 $service 更新操作中, 忽略进程退出"
					pending_count=$((pending_count + 1))
					#update_service_pid "$service" "null"
					;;
				"${SERVICE_ACTIONS[RUN]}")
					logger "DEBUG" "[$service] RUN 阶段, 等待进程就绪"
					pending_count=$((pending_count + 1))
					;;
				"${SERVICE_ACTIONS[CLOSE]}")
					logger "INFO" "服务 $service 关闭操作中, 进程退出正常"
					update_service_pid "$service" "null"
					;;
				*)	# 异常退出
					exit_code=1
					logger "ERROR" "服务 $service 服务异常退出 (PID=$pid)"
					
					update_service_pid "$service" "null"
					update_service_states "$service" "${SERVICE_STATUS[FAILURE]}" "进程异常退出"
					;;
			esac
		done
		
		# 服务生命周期结束
		if [[ "$pending_count" -eq 0 ]]; then
			logger "INFO" "所有服务进程已退出"
			break
		fi
		
		# 超时控制
		if [[ "$timeout" -gt 0 ]]; then
			local now=$(date +%s)
			local elapsed=$((now - start_time))
			
			if [[ $elapsed -ge $timeout ]]; then
				exit_code=124
				logger "WARNING" "等待服务退出超时 (${timeout}s)"
				break
			fi
		fi
		
		sleep "$check_interval"
	done
	
	return $exit_code
}

# 安装服务
install_service_env()
{
	logger "INFO" "安装系统服务"
	
	if [ "$1" = "init" ]; then
		apt update
		
		# 构建工具
		logger "SECTION" "安装构建工具"
		
		# swig
		apt-get install -y --no-install-recommends autoconf automake bison build-essential cmake libspeex-dev libtool libtool-bin nasm pkg-config python3 python3-dev yasm || {
			logger "ERROR" "构建工具安装失败"
			return 1
		}
		
		# 音频处理
		logger "SECTION" "安装音频处理库"
		
		# libcodec2-dev libfftw3-dev libgsm1-dev (libavresample-dev)
		apt-get install -y --no-install-recommends libflac-dev libmp3lame-dev libmpg123-dev libogg-dev libogg-dev libopus-dev libsndfile1-dev libspeex-dev libspeexdsp-dev libswresample-dev libvorbis-dev || {
			logger "ERROR" "音频处理库安装失败"
			return 1
		}
		
		# 视频处理
		logger "SECTION" "安装视频处理库"
		
		# libavcodec-dev libavutil-dev libx264-dev libvpx-dev libyuv-dev
		apt-get install -y --no-install-recommends libavformat-dev libswscale-dev || {
			logger "ERROR" "视频处理库安装失败"
			return 1
		}
		
		# 图片处理
		logger "SECTION" "安装图片处理库"
		
		# libtiff5-dev
		apt-get install -y --no-install-recommends libjpeg-dev libtiff-dev || {
			logger "ERROR" "图片处理库安装失败"
			return 1
		}
		
		# 数据库支持
		logger "SECTION" "安装数据库支持库"
		
		# libpq-dev odbc-postgresql odbc-mysql libmysqlclient-dev
		apt-get install -y --no-install-recommends libdb-dev libgdbm-dev libpq-dev libsqlite3-dev unixodbc-dev || {
			logger "ERROR" "数据库支持库安装失败"
			return 1
		}
		
		# 网络协议支持
		logger "SECTION" "安装网络协议库"
		
		#  libsctp-dev libpcap-dev librabbitmq-dev libsrtp2-dev
		apt-get install -y --no-install-recommends libcurl4-openssl-dev libldns-dev libshout3-dev || {
			logger "ERROR" "网络协议库安装失败"
			return 1
		}
		
		# 系统库
		logger "SECTION" "安装系统基础库 "
		
		# libspandsp-dev (libtpl-dev)
		apt-get install -y --no-install-recommends erlang-dev libedit-dev libexpat1-dev liblua5.4-dev libncurses5-dev libpcre3-dev libssl-dev libxml2-dev lsb-release uuid-dev zlib1g-dev || {
			logger "ERROR" "系统基础库安装失败"
			return 1
		}
	fi
	
	logger "INFO" "安装服务完成!"
}

# 设置系统用户
set_service_user()
{
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	local dirs=(
		"${SYSTEM_CONFIG[data_dir]}"
		"${SYSTEM_CONFIG[config_dir]}"
		"${SYSTEM_CONFIG[install_dir]}"
		"${SYSTEM_CONFIG[downloads_dir]}"
	)
	
	# 设置目录权限
	for dir in "${dirs[@]}"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[openlist] 目录 $dir 变量为空"
			return 1
		fi
		
		chown -R "$user:$group" "$dir" 2>/dev/null || {
			logger "ERROR" "[openlist] 设置目录权限失败: $dir"
			return 2
		}
	done
}

# 设置环境路径
set_service_paths()
{
	# 获取配置路径
	local dirs=(
		"${SYSTEM_CONFIG[data_dir]}"
		"${SYSTEM_CONFIG[config_dir]}"
		"${SYSTEM_CONFIG[install_dir]}"
		"${SYSTEM_CONFIG[downloads_dir]}"
	)
	
	# 创建目录
	for dir in "${dirs[@]}"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "目录 $dir 变量为空"
			return 1
		fi
		
		if ! mkdir -p "$dir"; then
			logger "ERROR" "目录创建失败: $dir"
			return 2
		fi
	done
}

# 设置服务
set_service_env()
{
	# 设置环境路径
	if ! set_service_paths; then
		logger "ERROR" "设置环境路径失败"
		return 1
	fi
	
	if [ "$1" = "config" ]; then
		# 设置SSH服务
		local params=("${SSHD_CONFIG[port]}" "${SSHD_CONFIG[listen]}" "${SSHD_CONFIG[confile]}" "${SSHD_CONFIG[hostkey]}")
		
		if ! set_ssh_service "${params[@]}"; then
			logger "ERROR" "设置 SSHD 服务失败, 请检查!"
			return 1
		fi
		
		# 设置用户权限
		if ! set_service_user; then
			logger "ERROR" "设置路径权限失败"
			return 3
		fi
		
		# 设置root用户密码
		echo "root:${ROOT_PASSWORD}" | chpasswd	
		
		# perl模块
		# export PERL5LIB=/usr/local/perl/lib/perl5
		echo "export PERL5LIB=/usr/local/perl/lib/perl5" >> ~/.bashrc
		
		#
		export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}
		echo "export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}" >> /etc/profile
		ldconfig
	fi
}

# 初始化服务
init_service()
{
	# 安装服务
	if ! install_service_env "$1"; then
		return 1
	fi
	
	# 设置服务
	if ! set_service_env "$1"; then
		return 1
	fi
}

# 运行服务
run_service()
{
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd >/dev/null 2>&1; then
		logger "INFO" "正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${SSHD_CONFIG[logfile]}"

		# nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${SSHD_CONFIG[logfile]}"
	fi
}

# 停止服务
close_service()
{
	if pgrep -x "sshd" > /dev/null; then
		logger "INFO" "sshd服务即将关闭中..."
		killall -q "sshd"
	fi
}