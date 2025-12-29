\echo '授予数据库权限...'

-- 设置数据库权限函数
CREATE OR REPLACE FUNCTION setup_database_privileges(db_name text, role_name text, set_owner boolean DEFAULT true)
RETURNS void AS $$
BEGIN
	RAISE NOTICE '正在设置数据库 % 的权限...', db_name;
	
	-- 验证数据库
	IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = db_name) THEN
		RAISE EXCEPTION '❌ 数据库 % 不存在', db_name;
	END IF;
	
	-- 验证角色
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
		RAISE EXCEPTION '❌ 角色 % 不存在', role_name;
	END IF;
	
	-- 设置数据库所有者
	IF set_owner THEN
		EXECUTE format('ALTER DATABASE %I OWNER TO %I', db_name, role_name);
	END IF;
	
	-- 授予所有数据库权限
	EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', db_name, role_name);
	
	-- 授予连接权限
	EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', db_name, role_name);
	
	-- 授予创建模式权限
	EXECUTE format('GRANT CREATE ON DATABASE %I TO %I', db_name, role_name);
	
	RAISE NOTICE '✓ 数据库权限设置完成';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 执行
SELECT setup_database_privileges('baikal', 'baikal', false);