import { createClient } from '@supabase/supabase-js'
import {
  createProviderKey,
  deleteProviderKey,
  encryptProviderKey,
  metadataFromProvider,
  verifyProviderKey,
} from '../_shared/llm-key.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const CONFIRMATION = 'rotate-all-existing-user-keys'
const validResets = new Set(['daily', 'weekly', 'monthly'])

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, 'Content-Type': 'application/json' },
})

function readJwtPayload(authHeader: string): Record<string, unknown> | null {
  try {
    const encoded = authHeader.replace(/^Bearer\s+/i, '').split('.')[1]
    if (!encoded) return null
    const normalized = encoded.replace(/-/g, '+').replace(/_/g, '/')
    return JSON.parse(atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')))
  } catch {
    return null
  }
}

type KeyRecord = {
  id: string
  user_id: string
  provider_key_hash: string
  encrypted_key: string
  key_version: number
  limit_usd: number | string | null
  limit_reset: string | null
  disabled: boolean
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'unauthorized' }, 401)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const managementKey = Deno.env.get('OPENROUTER_MANAGEMENT_API_KEY')
  const encryptionSecret = Deno.env.get('OPENROUTER_KEY_ENCRYPTION_SECRET')
  const workspaceId = Deno.env.get('OPENROUTER_WORKSPACE_ID')
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !managementKey || !encryptionSecret || !workspaceId) {
    return json({ error: 'llm_key_service_not_configured' }, 500)
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })
  const { data: { user: caller }, error: authError } = await callerClient.auth.getUser()
  if (authError || !caller) return json({ error: 'unauthorized' }, 401)
  if (caller.app_metadata?.role !== 'admin' || readJwtPayload(authHeader)?.aal !== 'aal2') {
    return json({ error: 'forbidden_admin_aal2_required' }, 403)
  }

  let body: Record<string, unknown>
  try {
    body = await req.json() as Record<string, unknown>
  } catch {
    return json({ error: 'invalid_json' }, 400)
  }
  if (body.confirmation !== CONFIRMATION) return json({ error: 'confirmation_required' }, 400)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: records, error: fetchError } = await admin
    .from('user_llm_api_keys')
    .select('id, user_id, provider_key_hash, encrypted_key, key_version, limit_usd, limit_reset, disabled')
    .order('created_at', { ascending: true })
  if (fetchError) return json({ error: 'internal_error' }, 500)

  const results: Array<{ user_id: string; status: string; detail?: string }> = []
  for (const record of (records ?? []) as KeyRecord[]) {
    if (record.disabled) {
      results.push({ user_id: record.user_id, status: 'skipped_disabled' })
      continue
    }
    const limit = Number(record.limit_usd)
    if (!Number.isFinite(limit) || limit < 0 || !record.limit_reset || !validResets.has(record.limit_reset)) {
      results.push({ user_id: record.user_id, status: 'skipped_invalid_policy' })
      continue
    }

    let created: Awaited<ReturnType<typeof createProviderKey>> | null = null
    try {
      created = await createProviderKey(
        managementKey,
        `akaaka-user-${record.user_id.replaceAll('-', '')}`,
        limit,
        record.limit_reset,
        workspaceId,
      )
      await verifyProviderKey(created.plaintext)
      const encryptedKey = await encryptProviderKey(created.plaintext, encryptionSecret)
      const metadata = metadataFromProvider(created.provider)
      const { data: updated, error: updateError } = await admin
        .from('user_llm_api_keys')
        .update({ encrypted_key: encryptedKey, key_version: record.key_version + 1, ...metadata })
        .eq('id', record.id)
        .eq('provider_key_hash', record.provider_key_hash)
        .select('id')
        .maybeSingle()
      if (updateError || !updated) throw new Error('local_update_conflict')

      try {
        await deleteProviderKey(managementKey, record.provider_key_hash)
        results.push({ user_id: record.user_id, status: 'rotated' })
      } catch {
        results.push({ user_id: record.user_id, status: 'cleanup_pending' })
      }
      created = null
    } catch (error) {
      if (created) {
        try { await deleteProviderKey(managementKey, created.provider.hash) } catch { /* keep original failure */ }
      }
      results.push({
        user_id: record.user_id,
        status: 'failed',
        detail: error instanceof Error ? error.message : 'rotation_failed',
      })
    }
  }

  const summary = results.reduce<Record<string, number>>((counts, result) => {
    counts[result.status] = (counts[result.status] ?? 0) + 1
    return counts
  }, {})
  const { error: auditError } = await admin.from('audit_logs').insert({
    actor_id: caller.id,
    target_profile_id: null,
    action: 'llm_key_rotation',
    payload: { workspace_id_configured: true, summary },
  })
  if (auditError) console.error('[rotate-llm-keys] audit log failed', auditError.message)
  return json({ summary, results })
})
