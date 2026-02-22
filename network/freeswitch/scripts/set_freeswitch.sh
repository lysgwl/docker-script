#!/bin/bash

# freeswitch 源码配置
declare -A FREESWITCH_SOURCES=(
	["libks"]='{"repo":"signalwire/libks", "version":"latest"}'
	["sofia-sip"]='{"repo":"freeswitch/sofia-sip", "version":"latest"}'
	["spandsp"]='{"repo":"freeswitch/spandsp", "version":"0d2e6ac65e0e8f53d652665a743015a88bf048d4"}'
	["signalwire-c"]='{"repo":"signalwire/signalwire-c", "version":"latest"}'
	["freeswitch"]='{"repo":"signalwire/freeswitch", "version":"latest"}'
)

# 获取 freeswitch 源码
fetch_freeswitch_source()
{
	logger "INFO" "[freeswitch] 获取相关源码"
	local downloads_dir=$1

	for key in "${!FREESWITCH_SOURCES[@]}"; do
		local name="$key"
		local source_config="${FREESWITCH_SOURCES[$name]}"
		
		[[ -z "$source_config" ]] && continue
		
		# 解析 JSON 配置
		local repo=$(jq -r '.repo' <<< "$source_config")
		local version=$(jq -r '.version' <<< "$source_config")
		
		# 如果repo为空, 跳过该源码获取
		if [[ -z "$repo" ]]; then
			logger "WARNING" "[freeswitch] 跳过获取 $name 源码,未配置仓库"
			continue
		fi
		
		local url="https://github.com/$repo.git"
		logger "INFO" "[freeswitch] 正在获取 $name 源码 ..." 
		
		# 构建克隆仓库的配置
		local json_config=$(jq -n \
				--arg type "github" \
				--arg name "$name" \
				--arg repo "$repo" \
				--arg version "$version" \
				--arg url "${url}" \
				'{
					type: $type,
					name: $name,
					repo: $repo,
					version:$version,
					url: $url
				}')
				
		# 获取源码路径
		local source_path
		source_path=$(get_service_sources "$name" "$downloads_dir" "$json_config")
		
		local ret=$?
		if [ $ret -ne 0 ]; then
			logger "ERROR" "[freeswitch] 获取 $name 源码失败, 错误码: $ret"
			break
		fi
	
		FREESWITCH_SOURCES[$key]=$(jq --arg path "$source_path" '. + {path: $path}' <<< "$source_config")
	done 
	
	return $ret
}

# 编译 libks 源码
build_libks_source()
{
	logger "INFO" "[libks] 编译源码 ..."
	
	# 获取 libks 源码路径
	local path=$(jq -r '.path // empty' <<< "${FREESWITCH_SOURCES[libks]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		logger "ERROR" "[libks] 获取源码失败: ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 CMake -DWITH_LIBBACKTRACE=1
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		logger "ERROR" "[libks] 源码CMake配置失败"
		return 2
	}
	
	# 编译 libks
	make -j$(nproc) || {
		logger "ERROR" "[libks] 源码编译失败"
		return 3
	}
	
	# 安装 libks
	make install || {
		logger "ERROR" "[libks] 安装失败"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
}

# 编译 sofia-sip 源码
build_sofia-sip_source()
{
	logger "INFO" "[sofia-sip] 编译源码 ..."
	
	# 获取 sofia-sip 源码路径
	local path=$(jq -r '.path // empty' <<< "${FREESWITCH_SOURCES[sofia-sip]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		logger "ERROR" "[sofia-sip] 获取源码失败: ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 configure 源码编译环境
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" \
		--with-pic \
		--with-glib=no \
		--without-doxygen \
		--disable-stun \
		--prefix=/usr/local
	
	# 编译 sofia-sip
	make -j$(nproc) || {
		logger "ERROR" "[sofia-sip] 源码编译失败"
		return 3
	}
	
	# 安装 sofia-sip
	make install || {
		logger "ERROR" "[sofia-sip] 安装失败"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
}

# 编译 spandsp 源码
build_spandsp_source()
{
	logger "INFO" "[spandsp] 编译源码 ..."
	
	# 获取 spandsp 源码路径
	local path=$(jq -r '.path // empty' <<< "${FREESWITCH_SOURCES[spandsp]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		logger "ERROR" "[spandsp] 获取源码失败: ($path)"
		return 1
	fi
	
	# git clone https://github.com/freeswitch/spandsp.git
	# git checkout -b compatible_version 0d2e6ac65e0e8f53d652665a743015a88bf048d4
	
	cd "$path"
	
	# 配置 configure 源码编译环境
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" \
		--with-pic \
		--prefix=/usr/local
		
	# 编译 spandsp
	make -j$(nproc) || {
		logger "ERROR" "[spandsp] 源码编译失败"
		return 3
	}
	
	# 安装 spandsp
	make install || {
		logger "ERROR" "[spandsp] 安装失败"
		return 4
	}
	
	# 设置临时环境变量
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
	
	# 永久生效
	echo "export PKG_CONFIG_PATH=\"/usr/local/lib/pkgconfig:\$PKG_CONFIG_PATH\"" >> /etc/profile
	
	# 确保动态库路径生效
	echo "/usr/local/lib" >> /etc/ld.so.conf
	ldconfig
	
	# 清理源码
	rm -rf "$path"
}

# 编译 signalwire-c 源码
build_signalwire-c_source()
{
	logger "INFO" "[signalwire-c] 编译源码 ..."
	
	# 获取 signalwire-c 源码路径
	local path=$(jq -r '.path // empty' <<< "${FREESWITCH_SOURCES[signalwire-c]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		logger "ERROR" "[signalwire-c] 获取源码失败: ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 CMake
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		logger "ERROR" "[signalwire-c] 源码CMake配置失败"
		return 2
	}
	
	# 编译 signalwire-c
	make -j$(nproc) || {
		logger "ERROR" "[signalwire-c] 源码编译失败"
		return 3
	}
	
	# 安装 signalwire-c
	make install || {
		logger "ERROR" "[signalwire-c] 安装失败"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
}

# 编译 freeswitch 源码
build_freeswitch_source()
{
	logger "INFO" "[freeswitch] 编译源码 ..."
	
	# 获取 signalwire-c 源码路径
	local path=$(jq -r '.path // empty' <<< "${FREESWITCH_SOURCES[freeswitch]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		logger "ERROR" "[freeswitch] 获取源码失败: ($path)"
		return 1
	fi
	
	cd "$path"
	
	# mod_av mod_verto mod_xml_curl mod_python
	sed -i 's|#formats/mod_shout|formats/mod_shout|' build/modules.conf.in
	sed -i '/^applications\/mod_signalwire$/s/^/#/' build/modules.conf.in
	
	# --sysconfdir=/etc --localstatedir=/var -with-python --with-erlang
	./bootstrap.sh -j
	
	# 配置 configure 源码编译环境
	./configure --enable-portable-binary \
				--prefix="${freeswitch_cfg[sys_path]}" \
				--sysconfdir="${freeswitch_cfg[etc_path]}" \
				--localstatedir="${freeswitch_cfg[data_path]}" \
				--with-gnu-ld \
				--with-openssl \
				--enable-core-odbc-support \
				--enable-zrtp \
				--disable-signalwire
				
	# 编译 freeswitch
	make -j$(nproc)|| {
		logger "ERROR" "[freeswitch] 源码编译失败"
		return 3
	}
	
	# 安装 freeswitch
	make install || {
		logger "ERROR" "[freeswitch] 安装失败"
		return 4
	}
	
	make sounds-install			# 安装所有语音提示音 (8kHz / 16kHz)
	make moh-install			# 安装所有音乐保持音
	
	#make hd-sounds-install  	# 安装 HD 质量提示音 (16kHz)
	#make hd-moh-install 		# 安装 HD 质量保持音
	
	#make uhd-sounds-install 	# 安装 UHD 质量提示音 (Ultra HD, 48kHz)
	#make uhd-moh-install 		# 安装 UHD 质量保持音
	
	#make cd-sounds-install  	# 安装 CD 质量提示音 (16-bit, 44.1kHz)
	#make cd-moh-install 		# 安装 CD 质量保持音 
	
	# 清理源码
	rm -rf "$path"
}

# 编译 freeswitch 源码
setup_freeswitch_source()
{
	logger "INFO" "编译 freeswitch 相关源码"
	
	# 编译 libks 源码
	if ! build_libks_source; then
		return 1
	fi
	
	# 编译 sofia-sip 源码
	if ! build_sofia-sip_source; then
		return 2
	fi
	
	# 编译 spandsp 源码
	if ! build_spandsp_source; then
		return 3
	fi
	
	# 编译 signalwire-c 源码
	if ! build_signalwire-c_source; then
		return 4
	fi

	# 编译 freeswitch 源码
	if ! build_freeswitch_source; then
		return 5
	fi
}

# 安装 freeswitch 环境
install_freeswitch_env()
{
	logger "INFO" "[freeswitch] 安装服务环境"
	local arg=$1
	
	local target_dir="${freeswitch_cfg[sys_path]}"
	if [ "$arg" = "init" ]; then
	
		if [ ! -d "${target_dir}" ]; then
			local downloads_dir="${SYSTEM_CONFIG[downloads_dir]}"
			
			# 获取 freeswitch 源码
			if ! fetch_freeswitch_source "$downloads_dir"; then
				logger "ERROR" "[freeswitch] 获取源码失败"
				return 1
			fi
			
			# 编译 freeswitch 源码
			if ! setup_freeswitch_source; then
				logger "ERROR" "[freeswitch] 编译源码失败" 
				return 2
			fi
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
		
	elif [ "$arg" = "config" ]; then
	
		if [ -d "${target_dir}" ]; then
			# 创建符号链接
			install_binary "${freeswitch_cfg[bin_path]}/freeswitch" "" "${freeswitch_cfg[symlink_path]}/freeswitch"

			# 创建fs_cli符号链接
			install_binary "${freeswitch_cfg[bin_path]}/fs_cli" "" "${freeswitch_cfg[symlink_path]}/fs_cli"
		fi
	fi
	
	logger "INFO" "[freeswitch] 服务安装完成"
}

# 设置 freeswitch 用户
set_freeswitch_user()
{
	logger "INFO" "[freeswitch] 设置服务用户权限"
	
	local user="${USER_CONFIG[user]}"
	local group="${USER_CONFIG[group]}"
	
	# 获取配置路径
	local sys_path="${freeswitch_cfg[sys_path]}"
	local etc_path="${freeswitch_cfg[etc_path]}"
	local data_path="${freeswitch_cfg[data_path]}"
	
	# 设置目录权限
	for dir in "$sys_path" "$etc_path" "$data_path"; do
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[freeswitch] 目录 $dir 变量为空"
			return 1
		fi
		
		chown -R "$user:$group" "$dir" 2>/dev/null || {
			logger "ERROR" "[freeswitch] 设置目录权限失败: $dir"
			return 2
		}
	done
	
	logger "INFO" "[freeswitch] 服务权限完成"
}

# 设置配置文件变量
set_freeswitch_vars()
{
	logger "INFO" "[freeswitch] 设置配置变量"
	
	local vars_conf="${freeswitch_cfg[etc_path]}/freeswitch/vars.xml"
	if [ -f "$vars_conf" ]; then
	
		modify_xml_config -f "$vars_conf" -m replace \
			-o '//X-PRE-PROCESS[@data="default_password=1234"]' \
			-n '<X-PRE-PROCESS cmd="set" data="default_password='"${freeswitch_cfg[passwd]}"'"/>' \
			-p after
			
		if [ -n "${freeswitch_cfg[external_ip]}" ]; then
		
			modify_xml_config -f "$vars_conf" -m insert \
				-o '//X-PRE-PROCESS[@data="domain=$${local_ip_v4}"]' \
				-n '<X-PRE-PROCESS cmd="set" data="local_ip_v4='"${freeswitch_cfg[external_ip]}"'"/>' \
				-p before
			
			# '"${freeswitch_cfg[external_ip]}"'
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_rtp_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_rtp_ip=$${local_ip_v4}"/>' \
				-p after
				
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_sip_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_sip_ip=$${local_ip_v4}"/>' \
				-p after
		fi	
	fi
	
	local event_socket_conf="${freeswitch_cfg[etc_path]}/freeswitch/autoload_configs/event_socket.conf.xml"
	if [ -f "$event_socket_conf" ]; then
	
		modify_xml_config -f "$event_socket_conf" -m update \
			-o '//param[@name="listen-ip"]' \
			-n 'value="0.0.0.0"'
		
		modify_xml_config -f "$event_socket_conf" -m update \
			-o '//param[@name="password"]' \
			-n 'value="ClueCon"'
	fi
}

# 同步配置数据
sync_freeswitch_conf()
{
	local src="$1"
	local dst="$2"
	local desc="$3"
	
	[[ ! -d "$src" ]] && return 1
	
	if find "$src" -mindepth 1 -maxdepth 1 -quit 2>/dev/null; then
	
		if ! rsync -a --remove-source-files "$src"/ "$dst"/ >/dev/null 2>&1; then
			logger "ERROR" "[freeswitch] 复制 $desc 失败"
			return 1
		fi
		
		rm -rf "$src" 
		logger "DEBUG" "[freeswitch] 复制 $desc 完成: $src → $dst"
	fi
	
	return 0
}

# 设置 freeswitch 配置
set_freeswitch_conf()
{
	logger "INFO" "[freeswitch] 设置服务配置文件"
	
	# freeswitch 预设数据(data)
	sync_freeswitch_conf "${SYSTEM_CONFIG[conf_dir]}/data" "${freeswitch_cfg[data_path]}" "数据文件" || return 1
	
	# freeswitch 预设配置(etc)
	sync_freeswitch_conf "${SYSTEM_CONFIG[conf_dir]}/etc" "${freeswitch_cfg[etc_path]}" "配置文件" || return 1
	
	
	# 设置配置文件变量
	set_freeswitch_vars
	
	logger "INFO" "[freeswitch] 服务配置完成"
}

# 设置 freeswitch 路径
set_freeswitch_paths()
{
	logger "INFO" "[freeswitch] 设置服务环境目录"
	
	# 获取配置路径
	local etc_path="${freeswitch_cfg[etc_path]}"
	local data_path="${freeswitch_cfg[data_path]}"
	
	# 创建目录
	for dir in "$etc_path" "$data_path"; do
	
		if [[ -z "$dir" ]]; then
			logger "ERROR" "[freeswitch] 目录 $dir 变量为空"
			return 1
		fi
		
		if ! mkdir -p "$dir"; then
			logger "ERROR" "[freeswitch] 目录创建失败: $dir"
			return 2
		fi
		
	done
	
	logger "INFO" "[freeswitch] 设置目录完成"
}

# 设置 freeswitch 环境
set_freeswitch_env()
{
	logger "INFO" "[freeswitch] 设置服务环境"
	
	# 设置路径
	if ! set_freeswitch_paths; then
		logger "ERROR" "[freeswitch] 路径设置失败"
		return 1
	fi
	
	if [ "$1" = "config" ]; then
		# 设置 freeswitch 配置
		set_freeswitch_conf
		
		# 设置 freeswitch 用户
		set_freeswitch_user
	fi
	
	logger "INFO" "[freeswitch] 设置服务完成"
}

# 设置 freeswitch 模板
set_freeswitch_template()
{
	# 获取配置路径
	local data_dir="${SYSTEM_CONFIG[data_dir]}"
	local etc_dir="${SYSTEM_CONFIG[config_dir]}"
	local sys_dir="/usr/local/freeswitch"
	local bin_dir="${sys_dir}/bin"
	local lib_dir="${data_dir}/lib/freeswitch"
	local log_dir="${data_dir}/log/freeswitch"
	local run_dir="${data_dir}/run/freeswitch"
	local symlink_dir="/usr/local/bin"
	local external_ip="$(echo "${EXTERNAL_IP:-}" | tr -d '"')"
	
	local freeswitch_json=$(jq -n \
		--arg name "freeswitch" \
		--arg passwd "123456" \
		--arg etc "${etc_dir}" \
		--arg data "${data_dir}" \
		--arg sys "${sys_dir}" \
		--arg bin "${bin_dir}" \
		--arg symlink "${symlink_dir}" \
		--arg lib "${lib_dir}" \
		--arg log "${log_dir}" \
		--arg run "${run_dir}" \
		--arg external "${external_ip}" \
		'{
			name: $name,
			passwd: $passwd,
			etc_path: $etc,
			data_path: $data,
			sys_path: $sys,
			bin_path: $bin,
			symlink_path: $symlink,
			lib_path: $lib,
			log_path: $log,
			run_path: $run,
			external_ip: $external
		}')
		
	import_service_config "freeswitch" "" "" "$freeswitch_json"
	return $?
}

# 初始化 freeswitch 环境
init_freeswitch_service()
{
	logger "INFO" "[freeswitch] 初始化服务"
	
	# 设置 freeswitch 模板
	if ! set_freeswitch_template; then
		logger "ERROR" "[freeswitch] 设置模板失败"
		return 1
	fi
	
	# 获取服务配置
	get_service_config "freeswitch" "config" "freeswitch_cfg" || {
		logger "ERROR" "[freeswitch] 无法获取服务配置"
		return 2
	}
	
	# 编译 freeswitch 源码
	if ! install_freeswitch_env "$1"; then
		logger "ERROR" "[freeswitch] 安装环境失败"
		return 3
	fi
	
	# 设置 freeswitch 环境
	if ! set_freeswitch_env "$1"; then
		logger "ERROR" "[freeswitch] 设置环境失败"
		return 4
	fi
	
	logger "INFO" "[freeswitch] ✓ 初始化服务完成"
}

# 运行 freeswitch 服务
run_freeswitch_service()
{
	local -n pid_ref="${1:-}"
	logger "INFO" "[freeswitch] 运行服务"
	
	# 获取服务配置
	get_service_config "freeswitch" "config" "freeswitch_cfg" || {
		logger "ERROR" "[freeswitch] 无法获取服务配置"
		return 1
	}
	
	local bin_file="${freeswitch_cfg[bin_path]}/freeswitch"
	local fs_cli="${freeswitch_cfg[bin_path]}/fs_cli"
	local pid_file="${freeswitch_cfg[run_path]}/freeswitch.pid"
	
	[[ ! -f "$bin_file" ]] && { logger "ERROR" "[freeswitch] 可执行文件不存在"; return 1; }
	[[ ! -f "$fs_cli" ]] && { logger "ERROR" "[fs_cli] 可执行文件不存在"; return 1; }
	
	# 检查是否已运行
	if check_service_alive "freeswitch"; then
		logger "WARNING" "[freeswitch] 检测服务已经在运行!"
		return 0
	fi
	
	# 启动服务
	exec_as_user ${USER_CONFIG[user]} "
		\"$bin_file\" -nonat -nc >/dev/null 2>&1 &
	" || {
		logger "ERROR" "[freeswitch] 执行启动命令失败"
		return 2
	}

	# 等待进程
	if ! wait_for_pid 5 "$pid_file"; then
		return 3
	fi
	
	pid_ref=$(cat "$pid_file" 2>/dev/null | tr -d ' \n')
	logger "INFO" "[freeswitch] ✓ 启动服务完成!"
}

# 停止 freeswitch 服务
close_freeswitch_service()
{
	logger "INFO" "[freeswitch] 开始停止服务"
	
	# 获取服务配置
	get_service_config "freeswitch" "config" "freeswitch_cfg" || {
		logger "ERROR" "[freeswitch] 无法获取服务配置"
		return 1
	}
	
	# 标识文件
	local pid_file="${freeswitch_cfg[run_path]}/freeswitch.pid"
	
	# 获取PID
	local pid=$(get_service_pid "freeswitch" 2>/dev/null)
	[[ -z "$pid" && -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null)
	
	# 停止服务
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		logger "INFO" "[freeswitch] 停止进程 (PID: $pid)"
		
		# 优雅停止
		kill -TERM "$pid" 2>/dev/null
		
		# 等待最多5秒
		for i in {1..5}; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 1
		done
		
		# 强制停止
		if kill -0 "$pid" 2>/dev/null; then
			logger "WARNING" "[freeswitch] 进程未响应, 强制停止"
			kill -KILL "$pid" 2>/dev/null
		fi
	fi
	
	# 清理PID文件
	rm -f "$pid_file" 2>/dev/null
	logger "INFO" "[freeswitch] ✓ 服务已停止"
}