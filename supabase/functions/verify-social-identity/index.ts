import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { findProviderIdentity, normalizePlatform, toSocialIdentityRecord } from '../_shared/social-identity.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  const authorization = req.headers.get('Authorization')
  if (!authorization) return jsonResponse({ error: 'unauthorized' }, 401)

  try {
    const body = await req.json() as { platform?: string; action?: string }
    const platform = normalizePlatform(body.platform ?? '')
    const action = body.action ?? 'sync'
    if (!platform || (action !== 'sync' && action !== 'revoke')) {
      return jsonResponse({ error: 'invalid_request' }, 400)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const caller = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } })
    const { data: { user }, error: userError } = await caller.auth.getUser()
    if (userError || !user) return jsonResponse({ error: 'unauthorized' }, 401)

    const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
    if (action === 'revoke') {
      const { error } = await admin.from('profile_social_identities').delete().eq('profile_id', user.id).eq('platform', platform)
      if (error) return jsonResponse({ error: 'persistence_failed' }, 500)
      return jsonResponse({ platform, verified: false }, 200)
    }

    const { data: identityData, error: identityError } = await caller.auth.getUserIdentities()
    if (identityError) return jsonResponse({ error: 'identity_lookup_failed' }, 502)
    const identity = findProviderIdentity(identityData.identities, platform)
    if (!identity) return jsonResponse({ error: 'identity_not_linked' }, 409)

    const record = toSocialIdentityRecord(user.id, identity)
    const { data, error } = await admin
      .from('profile_social_identities')
      .upsert(record, { onConflict: 'profile_id,platform' })
      .select('platform, provider_username, display_url, verified_at')
      .single()
    if (error) {
      const conflict = error.code === '23505'
      return jsonResponse({ error: conflict ? 'identity_conflict' : 'persistence_failed' }, conflict ? 409 : 500)
    }

    return jsonResponse({ verified: true, identity: data }, 200)
  } catch {
    return jsonResponse({ error: 'invalid_request' }, 400)
  }
})
