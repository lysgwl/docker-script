#!/bin/bash

# freeswitch配置数组
declare -A freeswitch_config=(
	["name"]="freeswitch"
	["sys_path"]="/usr/local/freeswitch"
	["etc_path"]="/usr/local/freeswitch/etc"
	["data_path"]="/usr/local/freeswitch/var"
	["bin_path"]="/usr/local/freeswitch/bin"
)

# freeswitch源码数组
declare -A freeswitch_sources=(
	["libks"]='{"repo":"signalwire/libks", "version":"latest"}'
	["sofia-sip"]='{"repo":"freeswitch/sofia-sip", "version":"latest"}'
	["spandsp"]='{"repo":"freeswitch/spandsp", "version":"0d2e6ac65e0e8f53d652665a743015a88bf048d4"}'
	["signalwire-c"]='{"repo":"signalwire/signalwire-c", "version":"latest"}'
	["freeswitch"]='{"repo":"signalwire/freeswitch", "version":"latest"}'
)

readonly -A freeswitch_config

# 获取freeswitch源码
fetch_freeswitch_source()
{
	local downloads_dir=$1
	echo "[INFO] 获取${freeswitch_config[name]}源码" >&2
	
	local ret=0
	local dest_path="${downloads_dir}/output"
	mkdir -p "${dest_path}"
	
	for key in "${!freeswitch_sources[@]}"; do
		local source_config="${freeswitch_sources[$key]}"
		
		echo "[INFO] 正在获取${key}源码..." >&2
		
		# 解析JSON配置
		local repo=$(jq -r '.repo' <<< "$source_config")
		local version=$(jq -r '.version' <<< "$source_config")
		
		local findpath latest_path
		if ! findpath=$(find_latest_archive "${downloads_dir}" "${key}*"); then
			echo "[WARNING] 未匹配到${key}软件包..." >&2
			
			local json_config=$(jq -n \
					--arg type "github" \
					--arg name "${key}" \
					--arg repo "${repo}" \
					--arg version "${version}" \
					'{
						type: $type,
						name: $name,
						repo: $repo,
						version:$version
					}')
			
			local clone_path
			if ! clone_path=$(clone_repo "${json_config}" "${downloads_dir}"); then
				ret=1;break
			fi
			
			local clone_name=$(basename "${clone_path}")
			
			if [ ! -d "${dest_path}/${clone_name}" ]; then
				cp -rf "${clone_path}" "${dest_path}"
			fi
			
			latest_path="${dest_path}/${clone_name}"
		else
			local latest_type=$(jq -r '.type' <<< "$findpath")
			if [[ -z "${latest_type}" ]] || ! [[ "${latest_type}" =~ ^(file|directory)$ ]]; then
				ret=1;break
			fi
			
			local latest_name=$(jq -r '.name' <<< "$findpath")
			
			if [ "${latest_type}" = "file" ]; then
				local latest_file=$(jq -r '.path' <<< "$findpath")
				
				if ! latest_path=$(extract_and_validate "${latest_file}" "${dest_path}" "${key}.*"); then
					ret=1;break
				fi
			else
				local src_path=$(jq -r '.path' <<< "$findpath")
				
				if [ ! -d "${clone_path}/${latest_name}" ]; then
					cp -rf "${src_path}" "${dest_path}"
				fi
				
				latest_path="${dest_path}/${latest_name}"
			fi
		fi
		
		freeswitch_sources[$key]=$(jq --arg path "$latest_path" '. + {path: $path}' <<< "$source_config")
	done 
	
	return $ret
}

# 编译libks源码
build_libks_source()
{
	# 编译libks源码
	local json_config="${freeswitch_sources[libks]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] libks源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] libks源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	
	# 配置CMake	-DWITH_LIBBACKTRACE=1
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] libks源码CMake配置失败,请检查!"
		return 1
	}
	
	# 编译libks
	make -j$(nproc) || {
		echo "[ERROR] libks源码编译失败,请检查!"
		return 1
	}
	
	# 安装libks
	make install || {
		echo "[ERROR] libks安装失败,请检查!"
		return 1
	}
	
	return 0
}

# 编译sofia-sip源码
build_sofia-sip_source()
{
	local json_config="${freeswitch_sources[sofia-sip]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] sofia-sip源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] sofia-sip源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" --with-pic --with-glib=no --without-doxygen --disable-stun --prefix=/usr/local
	
	# 编译sofia-sip
	make -j$(nproc) || {
		echo "[ERROR] sofia-sip源码编译失败,请检查!"
		return 1
	}
	
	# 安装sofia-sip
	make install || {
		echo "[ERROR] sofia-sip安装失败,请检查!"
		return 1
	}
	
	return 0
}

# 编译spandsp源码
build_spandsp_source()
{
	local json_config="${freeswitch_sources[spandsp]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] spandsp源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] spandsp源码路径不存在:$path"
		return 1
	fi
	
	# git clone https://github.com/freeswitch/spandsp.git
	# git checkout -b compatible_version 0d2e6ac65e0e8f53d652665a743015a88bf048d4
	
	cd "$path"
	
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" --with-pic --prefix=/usr/local
	
	# 编译spandsp
	make -j$(nproc) || {
		echo "[ERROR] spandsp源码编译失败,请检查!"
		return 1
	}
	
	# 安装spandsp
	make install || {
		echo "[ERROR] spandsp安装失败,请检查!"
		return 1
	}
	
	# 设置临时环境变量
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"
	
	# 永久生效
	echo "export PKG_CONFIG_PATH=\"/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH}\"" >> /etc/profile
	
	# 确保动态库路径生效
	echo "/usr/local/lib" >> /etc/ld.so.conf
	ldconfig
	
	return 0
}

# 编译signalwire-c源码
build_signalwire-c_source()
{
	local json_config="${freeswitch_sources[signalwire-c]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] signalwire-c源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] signalwire-c源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"; 
	
	# 配置CMake
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] signalwire-c源码CMake配置失败,请检查!"
		return 1
	}
	
	# 编译signalwire-c
	make -j$(nproc) || {
		echo "[ERROR] signalwire-c源码编译失败,请检查!"
		return 1
	}
	
	# 安装signalwire-c
	make install || {
		echo "[ERROR] signalwire-c安装失败,请检查!"
		return 1
	}
	
	return 0
}

# 编译freeswitch源码
build_freeswitch_source()
{
	local json_config="${freeswitch_sources[freeswitch]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] freeswitch源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] freeswitch源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	sed -i 's|#formats/mod_shout|formats/mod_shout|' build/modules.conf.in
	
	# --sysconfdir=/etc --localstatedir=/var -with-python --with-erlang
	./bootstrap.sh -j
	
	./configure --enable-portable-binary \
				--prefix=/usr/local/freeswitch \
				--sysconfdir="${system_config[config_dir]}" \
				--localstatedir="${system_config[data_dir]}" \
				--with-gnu-ld \
				--with-openssl \
				--enable-core-odbc-support \
				--enable-zrtp

	# 编译freeswitch
	make -j$(nproc)|| {
		echo "[ERROR] freeswitch源码编译失败,请检查!"
		return 1
	}
	
	# 安装sfreeswitch
	make install || {
		echo "[ERROR] freeswitch安装失败,请检查!"
		return 1
	}

	return 0
}

# 编译freeswitch源码
setup_freeswitch_source()
{
	echo "[INFO] 编译${freeswitch_config[name]}源码"
	
	# 编译libks源码
	if ! build_libks_source; then
		return 1
	fi
	
	# 编译sofia-sip源码
	if ! build_sofia-sip_source; then
		return 1
	fi
	
	# 编译spandsp源码
	if ! build_spandsp_source; then
		return 1
	fi
	
	# 编译signalwire-c源码
	if ! build_signalwire-c_source; then
		return 1
	fi
	
	# 编译freeswitch源码
	if ! build_freeswitch_source; then
		return 1
	fi
	
	return 0
}

# 安装freeswitch环境
install_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 安装${freeswitch_config[name]}服务..."
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	if [ "$arg" = "init" ]; then
		# 获取freeswitch源码
		if ! fetch_freeswitch_source "${downloads_dir}"; then
			echo "[ERROR] 获取${freeswitch_config[name]}失败,请检查!"
			return 1
		fi
		
		# 编译freeswitch源码
		if ! setup_freeswitch_source; then
			echo "[ERROR] 编译${freeswitch_config[name]}失败,请检查!"
			return 1
		fi
	elif [ "$arg" = "config" ]; then
		# 可执行文件
		install_binary "${freeswitch_config[bin_path]}/${freeswitch_config[name]}" "" "/usr/local/bin/${freeswitch_config[name]}"
		install_binary "${freeswitch_config[bin_path]}/fs_cli" "" "/usr/local/bin/fs_cli"
	fi
	
	echo "[INFO] 编译${freeswitch_config[name]}完成!"
	return 0
}

# 设置freeswitch配置
set_freeswitch_conf()
{
	echo "设置${freeswitch_config[name]}配置文件..."
	
	echo "设置${freeswitch_config[name]}配置完成!"
}

# 设置freeswitch用户
set_freeswitch_user()
{
	echo "设置${freeswitch_config[name]}用户权限..."

	chown -R ${user_config[user]}:${user_config[group]} "${freeswitch_config[sys_path]}"
	chmod 750 "${freeswitch_config[sys_path]}" 
		
	echo "设置${freeswitch_config[name]}权限完成!"
}

# 设置freeswitch环境
set_freeswitch_env()
{
	local arg=$1
	echo "设置${freeswitch_config[name]}服务配置..."
	
	if [ "$arg" = "config" ]; then	
		# 设置freeswitch配置
		set_freeswitch_conf
		
		# 设置freeswitch用户
		set_freeswitch_user
	fi
	
	echo "设置${freeswitch_config[name]}完成!"
	return 0
}

# 初始化freeswitch环境
init_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 初始化${freeswitch_config[name]}服务..."
	
	# 编译freeswitch源码
	if ! install_freeswitch_env "${arg}"; then
		return 1
	fi
	
	# 设置freeswitch环境
	if ! set_freeswitch_env "${arg}"; then
		return 1
	fi
	
	echo "[INFO] 初始化${freeswitch_config[name]}服务成功!"
	return 0
}