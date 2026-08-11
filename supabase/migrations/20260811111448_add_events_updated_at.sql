-- Publication RPCs and the canonical schema contract both require an event
-- updated_at timestamp. The initial schema predates that contract, so add it
-- as an idempotent forward migration before linting or using those functions.
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL
  DEFAULT TIMEZONE('utc', NOW());

DROP TRIGGER IF EXISTS trg_events_updated_at ON public.events;
CREATE TRIGGER trg_events_updated_at
BEFORE UPDATE ON public.events
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();
