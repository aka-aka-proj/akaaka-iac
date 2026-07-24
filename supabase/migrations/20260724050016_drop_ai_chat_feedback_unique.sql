-- Drop the UNIQUE constraint on (character_id, user_id) to allow multiple feedback entries
alter table public.ai_chat_feedback drop constraint if exists ai_chat_feedback_character_user_unique;

-- Drop the updated_at column and trigger since we no longer UPDATE rows
drop trigger if exists trg_ai_chat_feedback_updated_at on public.ai_chat_feedback;
drop function if exists public.update_ai_chat_feedback_updated_at;
alter table public.ai_chat_feedback drop column if exists updated_at;

-- Drop the UPDATE policy since we only INSERT new rows
drop policy if exists "Users can update their own feedback" on public.ai_chat_feedback;
