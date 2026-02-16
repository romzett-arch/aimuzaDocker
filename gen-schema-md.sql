-- Генерация database-schema.md в формате Markdown
\pset tuples_only on
\pset format unaligned

SELECT '# AI Planet Sound — Полная структура базы данных';
SELECT '';
SELECT '> Автоматически сгенерировано: ' || current_date;
SELECT '> Таблиц: ' || (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE');
SELECT '';
SELECT '---';
SELECT '';

-- Enum types
SELECT '## Enum-типы';
SELECT '';
SELECT '| Тип | Значения |';
SELECT '|-----|----------|';

SELECT '| `' || t.typname || '` | ' || string_agg('`' || e.enumlabel || '`', ', ' ORDER BY e.enumsortorder) || ' |'
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE n.nspname = 'public'
GROUP BY t.typname
ORDER BY t.typname;

SELECT '';
SELECT '---';
SELECT '';

-- Tables with columns
SELECT '## Таблицы';
SELECT '';

-- Generate table docs
DO $$
DECLARE
  tbl RECORD;
  col RECORD;
BEGIN
  FOR tbl IN 
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema='public' AND table_type='BASE TABLE'
    ORDER BY table_name
  LOOP
    RAISE NOTICE '### %', tbl.table_name;
    RAISE NOTICE '| Колонка | Тип | Nullable | Default |';
    RAISE NOTICE '|---------|-----|----------|---------|';
    
    FOR col IN
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema='public' AND table_name=tbl.table_name
      ORDER BY ordinal_position
    LOOP
      RAISE NOTICE '| % | % | % | % |', 
        col.column_name, col.data_type, col.is_nullable, COALESCE(col.column_default, '—');
    END LOOP;
    
    RAISE NOTICE '';
  END LOOP;
END $$;
