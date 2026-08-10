-- Create the ai_chat_feedback table for storing like/dislike on AI responses
-- Each click inserts a new row (no UNIQUE constraint — users can record feedback many times)
create table public.ai_chat_feedback (
  id uuid not null default gen_random_uuid (),
  character_id uuid not null references public.ai_characters (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  model_name text not null,
  feedback text not null check (feedback in ('like', 'dislike')),
  created_at timestamp with time zone not null default now(),
  constraint ai_chat_feedback_pkey primary key (id)
);

-- Enable Row Level Security
alter table public.ai_chat_feedback enable row level security;

-- RLS Policies

-- Policy for SELECT: Users can view their own feedback
create policy "Users can view their own feedback"
  on public.ai_chat_feedback
  for select
  to authenticated
  using (user_id = auth.uid());

-- Policy for INSERT: Users can insert their own feedback
create policy "Users can insert their own feedback"
  on public.ai_chat_feedback
  for insert
  to authenticated
  with check (user_id = auth.uid());
