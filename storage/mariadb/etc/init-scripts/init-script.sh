#!/bin/bash

# 监控的SQL目录
SQL_DIR="${MYSQL_WATCH_DIR:-/docker-entrypoint-initdb.d}"

# 执行记录文件
EXECUTED_FILE="${MYSQL_EXECUTED_LOG:-$MYSQL_INIT_DIR/sql-executed_log.log}"

# 检查间隔（秒）
CHECK_INTERVAL=30

# 提供默认密码
: "${MYSQL_ROOT_PASSWORD:=123456}"

# 构建mysql命令
MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASSWORD"
MYSQLADMIN_CMD="mysqladmin -u root -p$MYSQL_ROOT_PASSWORD ping"

# 等待MariaDB启动
wait_for_mariadb()
{
	local attempt=1
	local max_attempts=60
	
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 等待MariaDB启动..."
	
	until $MYSQLADMIN_CMD --silent; do
		if [ $attempt -ge $max_attempts ]; then
			echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] MariaDB启动超时!"
			return 1
		fi
		
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] 尝试 $attempt/$max_attempts: MariaDB尚未就绪，等待2秒..."
		
		sleep 2
		attempt=$((attempt + 1))
	done
	
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] MariaDB已启动成功"
	return 0
}

# 执行 SQL 脚本
exec_runtime_scripts()
{
	local sql_file="$1"
	local filename=$(basename "$sql_file")
	
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 正在执行SQL脚本: $filename"
	
	# 执行SQL脚本
	if ! $MYSQL_CMD < "$sql_file" 2>&1; then
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] 执行SQL脚本失败: $filename"
		return 1
	fi
	
	# 记录执行成功的脚本
	echo "$filename:$(date '+%Y-%m-%d %H:%M:%S')" >> "$EXECUTED_FILE"

	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 成功执行SQL脚本: $filename"
	return 0
}

# 监控 SQL 脚本
monitor_sql_scripts()
{
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 开始监控SQL目录: $SQL_DIR"
	
	# 创建执行记录文件
	if [ -f "$EXECUTED_FILE" ]; then
		rm -f "$EXECUTED_FILE"
	fi
	
	touch "$EXECUTED_FILE"
	
	while true; do
		# 遍历所有 .sql 文件
		find "$SQL_DIR" -maxdepth 1 -type f -name "*.sql" | while read -r sql_file; do
			if [ -f "$sql_file" ]; then
				local filename=$(basename "$sql_file")
				
				# 检查是否已执行过
				if ! grep -q "$filename" "$EXECUTED_FILE"; then
					exec_runtime_scripts "$sql_file"
				fi
			fi
		done
		
		sleep $CHECK_INTERVAL
	done
}

# 主函数
main()
{
	if ! wait_for_mariadb; then
		return
	fi
	
	monitor_sql_scripts
}

# 运行主函数
main