-- Выполняется администратором после создания или восстановления схемы.
-- Пароль inspector задан в учебном задании; это не пароль личного аккаунта.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END $$;
GRANT ALL PRIVILEGES ON SCHEMA lukovkin_food TO inspector;
GRANT USAGE ON SCHEMA exts, information_schema, pg_catalog TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA lukovkin_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA lukovkin_food TO inspector;
GRANT ALL PRIVILEGES ON ALL ROUTINES IN SCHEMA lukovkin_food TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA lukovkin_food GRANT ALL ON TABLES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA lukovkin_food GRANT ALL ON ROUTINES TO inspector;
ALTER ROLE inspector SET search_path = lukovkin_food, exts, pg_catalog;
