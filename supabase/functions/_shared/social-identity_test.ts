import { findProviderIdentity, normalizePlatform, toSocialIdentityRecord } from './social-identity.ts'

function assertDeepEqual(actual: unknown, expected: unknown): void {
  const actualJson = JSON.stringify(actual)
  const expectedJson = JSON.stringify(expected)
  if (actualJson !== expectedJson) {
    throw new Error(`expected ${expectedJson}, got ${actualJson}`)
  }
}

Deno.test('normalizes X provider aliases and keeps Facebook distinct', () => {
  if (normalizePlatform('x') !== 'x') throw new Error("expected 'x' for 'x'")
  if (normalizePlatform('twitter') !== 'x') throw new Error("expected 'x' for 'twitter'")
  if (normalizePlatform('facebook') !== 'facebook') throw new Error("expected 'facebook' for 'facebook'")
  if (normalizePlatform('instagram') !== null) throw new Error("expected null for 'instagram'")
})

Deno.test('finds the identity for the requested platform', () => {
  const identity = findProviderIdentity([
    { provider: 'google', identity_id: 'google-1' },
    { provider: 'x', identity_id: 'x-1' },
  ], 'x')

  if (identity?.identity_id !== 'x-1') throw new Error('expected x-1 identity')
})

Deno.test('maps immutable subject and display data without tokens', () => {
  assertDeepEqual(toSocialIdentityRecord('profile-1', {
    provider: 'x',
    identity_id: 'identity-1',
    identity_data: { sub: 'x-subject', preferred_username: 'aka_user', access_token: 'must-not-be-used' },
  }), {
    profile_id: 'profile-1',
    platform: 'x',
    provider_identity_id: 'identity-1',
    provider_subject: 'x-subject',
    provider_username: 'aka_user',
    display_url: 'https://x.com/aka_user',
  })
})

Deno.test('rejects identities without an immutable subject', () => {
  let threw = false
  try {
    toSocialIdentityRecord('profile-1', {
      provider: 'x',
      identity_id: 'identity-1',
      identity_data: { preferred_username: 'aka_user' },
    })
  } catch {
    threw = true
  }
  if (!threw) throw new Error('expected rejection for missing subject')
})
