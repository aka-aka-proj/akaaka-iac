-- Create the ai_chats table
create table public.ai_chats (
  id uuid not null default gen_random_uuid (),
  character_id uuid not null references public.ai_characters (id) on delete cascade,
  messages jsonb not null default '[]'::jsonb,
  created_at timestamp with time zone not null default now(),
  constraint ai_chats_pkey primary key (id)
);

-- Enable Row Level Security
alter table public.ai_chats enable row level security;

-- RLS Policies

-- Policy for SELECT: Users can view their own AI chats
create policy "Users can view their own AI chats"
  on public.ai_chats
  for select
  to authenticated
  using (
    exists (
      select 1 from public.ai_characters
      where ai_characters.id = ai_chats.character_id
      and ai_characters.user_id = auth.uid()
    )
  );

-- Policy for INSERT: Users can insert their own AI chats
create policy "Users can insert their own AI chats"
  on public.ai_chats
  for insert
  to authenticated
  with check (
    exists (
      select 1 from public.ai_characters
      where ai_characters.id = ai_chats.character_id
      and ai_characters.user_id = auth.uid()
    )
  );