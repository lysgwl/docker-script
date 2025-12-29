\echo '授予模式权限...'

\c baikal

-- 设置角色权限函数
CREATE OR REPLACE FUNCTION setup_role_privileges(role_name text)
RETURNS void AS $$
BEGIN
	RAISE NOTICE '正在为数据库: % 角色 % 设置模式权限...', current_database(), role_name;
	
	-- 验证角色
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
		RAISE EXCEPTION '❌ 角色 % 不存在', role_name;
	END IF;
	
	-- 授予模式权限
	EXECUTE format('GRANT ALL ON SCHEMA public TO %I', role_name);
	
	-- 授予对象权限
	EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA public TO %I', role_name);
	EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO %I', role_name);
	EXECUTE format('GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO %I', role_name);
	
	-- 设置默认权限
	EXECUTE format(
		'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO %I', role_name);
	
	EXECUTE format(
		'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO %I', role_name);
	
	EXECUTE format(
		'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO %I', role_name);
		
	RAISE NOTICE '✓ 模式权限设置完成';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 设置模式权限
SELECT setup_role_privileges('baikal')