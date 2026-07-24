-- Create the ai_characters table
create table public.ai_characters (
  id uuid not null default gen_random_uuid (),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  persona text not null,
  created_at timestamp with time zone not null default now(),
  constraint ai_characters_pkey primary key (id)
);

-- Enable Row Level Security
alter table public.ai_characters enable row level security;

-- RLS Policies

-- Policy for SELECT: Users can view their own AI characters
create policy "Users can view their own AI characters"
  on public.ai_characters
  for select
  to authenticated
  using ( (select auth.uid()) = user_id );

-- Policy for INSERT: Users can insert their own AI characters
create policy "Users can insert their own AI characters"
  on public.ai_characters
  for insert
  to authenticated
  with check ( (select auth.uid()) = user_id );

-- Policy for UPDATE: Users can update their own AI characters
create policy "Users can update their own AI characters"
  on public.ai_characters
  for update
  to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- Policy for DELETE: Users can delete their own AI characters
create policy "Users can delete their own AI characters"
  on public.ai_characters
  for delete
  to authenticated
  using ( (select auth.uid()) = user_id );