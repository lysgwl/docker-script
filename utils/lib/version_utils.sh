#!/bin/bash
# 版本工具模块

if [[ -n "${VERSION_UTILS_LOADED:-}" ]]; then
	return 0
fi
export VERSION_UTILS_LOADED=1


# 版本比较
compare_versions()
{
	local ver1="$1"
	local ver2="$2"
	
	# 验证版本格式
	if [[ ! "$ver1" =~ ^[0-9.]+$ ]] || [[ ! "$ver2" =~ ^[0-9.]+$ ]]; then
		return 3	# 3: 版本格式错误
	fi
	
	# 将版本拆分为数组
	local IFS=.
	local -a ver1_arr=($ver1)
	local -a ver2_arr=($ver2)
	unset IFS
	
	# 比较每个部分
	local max_length=$(( ${#ver1_arr[@]} > ${#ver2_arr[@]} ? ${#ver1_arr[@]} : ${#ver2_arr[@]} ))
	
	for ((i=0; i<max_length; i++)); do
		local num1=${ver1_arr[i]:-0}
		local num2=${ver2_arr[i]:-0}
		
		# 比较数字部分
		if (( num1 > num2 )); then
			return 1	# 1: 版本1大于版本2
		elif (( num1 < num2 )); then
			return 2	# 2: 版本1小于版本2
		fi
	done
	
	# 0: 两个版本相等
	return 0
}