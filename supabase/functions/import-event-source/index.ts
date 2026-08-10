const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAX_RESPONSE_BYTES = 512 * 1024
const FETCH_TIMEOUT_MS = 5000

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}

function allowedSourceUrl(value: string): boolean {
  try {
    const url = new URL(value)
    if (url.protocol !== 'https:' || url.port || url.username || url.password) return false
    if ((url.hostname === 'x.com' || url.hostname === 'twitter.com')) {
      return /^\/[^/]+\/status\/[0-9]+$/.test(url.pathname)
    }
    return url.hostname === 'todo.smertw.com' && /^\/events\/[0-9]+$/.test(url.pathname)
  } catch {
    return false
  }
}

function decodeHtml(value: string): string {
  return value.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
}

function metadata(html: string, property: string): string | null {
  const pattern = new RegExp(`<meta[^>]+(?:property|name)=["']${property}["'][^>]+content=["']([^"']*)["'][^>]*>`, 'i')
  const reversePattern = new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${property}["'][^>]*>`, 'i')
  const match = html.match(pattern) ?? html.match(reversePattern)
  return match?.[1] ? decodeHtml(match[1]).trim().slice(0, 2000) : null
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ error: { code: 'validation_error', message: 'Only POST is supported' } }, 400)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return jsonResponse({ error: { code: 'unauthorized', message: 'Missing authorization header' } }, 401)

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    if (!supabaseUrl || !anonKey) return jsonResponse({ error: { code: 'internal_error', message: 'Server configuration is incomplete' } }, 500)
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return jsonResponse({ error: { code: 'unauthorized', message: 'Invalid or expired token' } }, 401)

    const body = await req.json() as { source_url?: string }
    const sourceUrl = body.source_url?.trim() ?? ''
    if (!allowedSourceUrl(sourceUrl)) return jsonResponse({ error: { code: 'validation_error', message: 'Unsupported source URL' } }, 400)

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS)
    let response: Response
    try {
      response = await fetch(sourceUrl, { signal: controller.signal, redirect: 'manual', headers: { Accept: 'text/html' } })
    } finally {
      clearTimeout(timer)
    }
    if (!response.ok || response.status >= 300 && response.status < 400) {
      return jsonResponse({ error: { code: 'dependency_unavailable', message: 'Source page could not be read' } }, 502)
    }
    const contentType = response.headers.get('content-type') ?? ''
    if (!contentType.includes('text/html')) return jsonResponse({ error: { code: 'validation_error', message: 'Source is not an HTML page' } }, 422)
    const contentLength = Number(response.headers.get('content-length') ?? 0)
    if (contentLength > MAX_RESPONSE_BYTES) return jsonResponse({ error: { code: 'validation_error', message: 'Source page is too large' } }, 422)
    const html = (await response.text()).slice(0, MAX_RESPONSE_BYTES)
    const title = metadata(html, 'og:title') ?? metadata(html, 'twitter:title') ?? metadata(html, 'title')
    const description = metadata(html, 'og:description') ?? metadata(html, 'description')
    return jsonResponse({ source_url: sourceUrl, provider: new URL(sourceUrl).hostname, preview: { title, description } }, 200)
  } catch (error) {
    console.error('import-event-source failed', error instanceof Error ? error.name : 'unknown')
    return jsonResponse({ error: { code: 'dependency_unavailable', message: 'Source page could not be read' } }, 502)
  }
})
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
