BEGIN;

SELECT plan(30);

SELECT ok(to_regclass('public.ai_encryption_devices') IS NOT NULL, 'device table exists');
SELECT ok(to_regclass('public.ai_encryption_vault_keys') IS NOT NULL, 'wrapped vault key table exists');
SELECT ok(to_regclass('public.ai_encryption_migrations') IS NOT NULL, 'migration state table exists');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.ai_encryption_devices'::regclass), 'device table has RLS');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.ai_encryption_vault_keys'::regclass), 'vault key table has RLS');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.ai_encryption_migrations'::regclass), 'migration table has RLS');
SELECT ok(has_table_privilege('authenticated', 'public.ai_encryption_devices', 'SELECT,INSERT,UPDATE,DELETE'), 'authenticated has device Data API privileges');
SELECT ok(has_table_privilege('authenticated', 'public.ai_encryption_vault_keys', 'SELECT,INSERT,UPDATE,DELETE'), 'authenticated has vault key Data API privileges');
SELECT ok(has_table_privilege('authenticated', 'public.ai_encryption_migrations', 'SELECT,INSERT,UPDATE,DELETE'), 'authenticated has migration Data API privileges');
SELECT ok(NOT has_table_privilege('anon', 'public.ai_encryption_devices', 'SELECT'), 'anon cannot read devices');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_encryption_devices' AND policyname = 'ai_encryption_devices_select_owner' AND qual LIKE '%auth.uid%'), 'device select is owner scoped');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_encryption_devices' AND policyname = 'ai_encryption_devices_update_owner' AND with_check LIKE '%auth.uid%'), 'device update has owner check');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_encryption_vault_keys' AND policyname = 'ai_encryption_vault_keys_insert_owner' AND with_check LIKE '%auth.uid%'), 'wrapped key insert is owner scoped');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_encryption_vault_keys' AND policyname = 'ai_encryption_vault_keys_insert_owner' AND with_check LIKE '%ai_encryption_devices%'), 'wrapped key insert requires active owner device');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_encryption_migrations' AND policyname = 'ai_encryption_migrations_update_owner' AND with_check LIKE '%auth.uid%'), 'migration update has owner check');
SELECT ok(has_column_privilege('authenticated', 'public.ai_messages', 'content_ciphertext', 'INSERT'), 'messages allow encrypted content insert');
SELECT ok(NOT has_column_privilege('authenticated', 'public.ai_messages', 'content', 'INSERT'), 'messages deny legacy plaintext insert');
SELECT ok(has_column_privilege('authenticated', 'public.ai_messages', 'content_ciphertext', 'UPDATE'), 'messages allow encrypted content update');
SELECT ok(NOT has_column_privilege('authenticated', 'public.ai_messages', 'content', 'UPDATE'), 'messages deny legacy plaintext update');
SELECT ok(has_column_privilege('authenticated', 'public.ai_characters', 'memory_ciphertext', 'UPDATE'), 'characters allow encrypted memory update');
SELECT ok(NOT has_column_privilege('authenticated', 'public.ai_characters', 'memory', 'UPDATE'), 'characters deny legacy plaintext memory update');
SELECT ok((SELECT is_nullable = 'YES' FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'ai_messages' AND column_name = 'content'), 'legacy message content is nullable for encrypted inserts');
SELECT ok((SELECT is_nullable = 'YES' FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'ai_characters' AND column_name = 'memory'), 'legacy character memory is nullable for encrypted writes');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_messages' AND policyname = 'ai_messages_update_owner' AND qual LIKE '%auth.uid%' AND with_check LIKE '%auth.uid%'), 'messages encrypted update is owner scoped');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_encryption_devices'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%status%active%revoked%'), 'device status is constrained');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_encryption_migrations'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%pending%in_progress%complete%'), 'migration status is constrained');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_encryption_migrations'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%failure_code%'), 'migration failure code is constrained');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_encryption_devices'::regclass AND conname = 'ai_encryption_devices_public_key_is_public'), 'device table rejects private JWK members');
SELECT ok((SELECT obj_description('public.ai_encryption_devices'::regclass, 'pg_class') LIKE '%never private keys%'), 'device table documents private-key exclusion');
SELECT ok((SELECT obj_description('public.ai_encryption_vault_keys'::regclass, 'pg_class') LIKE '%never raw data keys%'), 'vault table documents raw-key exclusion');

SELECT * FROM finish();
ROLLBACK;
