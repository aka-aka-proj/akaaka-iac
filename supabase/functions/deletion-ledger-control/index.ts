import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { createCloudflareDeletionLedger } from '../_shared/cloudflare-deletion-ledger.ts'
import { isAdminAal2, parseStageLedgerRequest, readJwtPayload, toSafeLedgerRecord } from '../_shared/deletion-ledger-control.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}

function stableError(error: unknown): string {
  const code = error instanceof Error ? error.message : ''
  return /^[a-z0-9_]+$/.test(code) ? code : 'ledger_control_failed'
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  const mode = Deno.env.get('DELETION_LEDGER_CONTROL_MODE')
  const applicationUrl = Deno.env.get('SUPABASE_URL')
  const ledgerUrl = Deno.env.get('DELETION_LEDGER_URL')
  const ledgerToken = Deno.env.get('DELETION_LEDGER_AUTH_TOKEN')
  if (mode !== 'stage' || !applicationUrl || !ledgerUrl || !ledgerToken) return json({ error: 'ledger_service_not_configured' }, 500)

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'unauthorized' }, 401)
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!anonKey || !serviceRoleKey) return json({ error: 'ledger_service_not_configured' }, 500)

  const callerClient = createClient(applicationUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })
  const { data: { user: caller }, error: authError } = await callerClient.auth.getUser()
  if (authError || !caller) return json({ error: 'unauthorized' }, 401)
  if (!isAdminAal2(caller, readJwtPayload(authHeader))) {
    return json({ error: 'forbidden_admin_aal2_required' }, 403)
  }

  let request: ReturnType<typeof parseStageLedgerRequest>
  try {
    request = parseStageLedgerRequest(await req.json())
  } catch (error) {
    return json({ error: stableError(error) }, 400)
  }

  try {
    const ledger = createCloudflareDeletionLedger({ workerUrl: ledgerUrl, authToken: ledgerToken, applicationUrl })
    if (request.operation === 'append') {
      const record = await ledger.append({ ...request.event, auditActor: 'controlled_fixture' })
      return json({ record: toSafeLedgerRecord(record) })
    }
    if (request.operation === 'list') {
      const records = await ledger.listForRestore(request.subject)
      return json({ records: records.map(toSafeLedgerRecord), count: records.length })
    }
    const record = await ledger.transition(request)
    return json({ record: toSafeLedgerRecord(record) })
  } catch (error) {
    return json({ error: stableError(error) }, 502)
  }
})
