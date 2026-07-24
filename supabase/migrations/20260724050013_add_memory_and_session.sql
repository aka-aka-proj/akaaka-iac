-- Add memory column to ai_characters for conversation summaries (max 500 chars)
alter table public.ai_characters add column if not exists memory text check (char_length(memory) <= 500);

-- Add session_id to ai_chats to support multiple conversation sessions
alter table public.ai_chats add column if not exists session_id uuid not null default gen_random_uuid();