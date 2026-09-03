-- Contract-step Phase B (#100): browser clients must use the controlled
-- refresh and unsubscribe RPCs instead of directly mutating subscriptions.

REVOKE UPDATE, DELETE ON public.push_subscriptions FROM authenticated;
