import { assertEquals, assertThrows } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { findProviderIdentity, normalizePlatform, toSocialIdentityRecord } from './social-identity.ts'

Deno.test('normalizes X provider aliases and keeps Facebook distinct', () => {
  assertEquals(normalizePlatform('x'), 'x')
  assertEquals(normalizePlatform('twitter'), 'x')
  assertEquals(normalizePlatform('facebook'), 'facebook')
  assertEquals(normalizePlatform('instagram'), null)
})

Deno.test('finds the identity for the requested platform', () => {
  const identity = findProviderIdentity([
    { provider: 'google', identity_id: 'google-1' },
    { provider: 'x', identity_id: 'x-1' },
  ], 'x')

  assertEquals(identity?.identity_id, 'x-1')
})

Deno.test('maps immutable subject and display data without tokens', () => {
  assertEquals(toSocialIdentityRecord('profile-1', {
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
  assertThrows(() => toSocialIdentityRecord('profile-1', {
    provider: 'x',
    identity_id: 'identity-1',
    identity_data: { preferred_username: 'aka_user' },
  }))
})
