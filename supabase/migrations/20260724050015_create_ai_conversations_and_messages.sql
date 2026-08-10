-- ai_conversations: 代表一場獨立對話
CREATE TABLE IF NOT EXISTS public.ai_conversations (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  character_id UUID NOT NULL REFERENCES public.ai_characters(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ai_conversations_pkey PRIMARY KEY (id)
);

-- ai_messages: 對話中的單一則訊息
CREATE TABLE IF NOT EXISTS public.ai_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.ai_conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ai_messages_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation_id
  ON ai_messages (conversation_id, created_at ASC);

-- 遷移現有 ai_chats 資料到新結構
-- 每筆 character 的最新 row 視為一組完整對話
DO $$
DECLARE
  char_record RECORD;
  latest_chat RECORD;
  new_conv_id UUID;
  msg_item RECORD;
BEGIN
  FOR char_record IN SELECT DISTINCT character_id FROM public.ai_chats LOOP
    -- 取該 character 最新的一筆 row（包含完整對話）
    SELECT id, messages, created_at INTO latest_chat
    FROM public.ai_chats
    WHERE character_id = char_record.character_id
    ORDER BY created_at DESC
    LIMIT 1;

    -- 建立 conversation
    INSERT INTO public.ai_conversations (character_id, created_at)
    VALUES (char_record.character_id, latest_chat.created_at)
    RETURNING id INTO new_conv_id;

    -- 逐筆訊息插入 ai_messages
    FOR msg_item IN SELECT * FROM jsonb_to_recordset(latest_chat.messages) AS x(role text, content text)
    LOOP
      INSERT INTO public.ai_messages (conversation_id, role, content, created_at)
      VALUES (new_conv_id, msg_item.role, msg_item.content, latest_chat.created_at);
    END LOOP;
  END LOOP;
END $$;

-- 刪除舊表
DROP TABLE IF EXISTS public.ai_chats;

-- RLS
ALTER TABLE public.ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_messages ENABLE ROW LEVEL SECURITY;

-- ai_conversations RLS
CREATE POLICY ai_conversations_select_owner ON public.ai_conversations FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.ai_characters ac
      WHERE ac.id = character_id AND ac.user_id = auth.uid()
    )
  );

CREATE POLICY ai_conversations_insert_owner ON public.ai_conversations FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.ai_characters ac
      WHERE ac.id = character_id AND ac.user_id = auth.uid()
    )
  );

CREATE POLICY ai_conversations_delete_owner ON public.ai_conversations FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.ai_characters ac
      WHERE ac.id = character_id AND ac.user_id = auth.uid()
    )
  );

-- ai_messages RLS（透過 conversation 連到 character 再連到 user）
CREATE POLICY ai_messages_select_owner ON public.ai_messages FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.ai_conversations acv
      JOIN public.ai_characters ac ON ac.id = acv.character_id
      WHERE acv.id = conversation_id AND ac.user_id = auth.uid()
    )
  );

CREATE POLICY ai_messages_insert_owner ON public.ai_messages FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.ai_conversations acv
      JOIN public.ai_characters ac ON ac.id = acv.character_id
      WHERE acv.id = conversation_id AND ac.user_id = auth.uid()
    )
  );

CREATE POLICY ai_messages_delete_owner ON public.ai_messages FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.ai_conversations acv
      JOIN public.ai_characters ac ON ac.id = acv.character_id
      WHERE acv.id = conversation_id AND ac.user_id = auth.uid()
    )
  );