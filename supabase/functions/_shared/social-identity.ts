export type SocialPlatform = 'x' | 'facebook'

export type AuthIdentity = {
  identity_id?: string
  provider: string
  identity_data?: Record<string, unknown> | null
}

export type SocialIdentityRecord = {
  profile_id: string
  platform: SocialPlatform
  provider_identity_id: string
  provider_subject: string
  provider_username: string | null
  display_url: string | null
}

export function normalizePlatform(provider: string): SocialPlatform | null {
  if (provider === 'x' || provider === 'twitter') return 'x'
  if (provider === 'facebook') return 'facebook'
  return null
}

export function findProviderIdentity(identities: AuthIdentity[], platform: SocialPlatform): AuthIdentity | null {
  return identities.find((identity) => normalizePlatform(identity.provider) === platform) ?? null
}

export function toSocialIdentityRecord(profileId: string, identity: AuthIdentity): SocialIdentityRecord {
  const platform = normalizePlatform(identity.provider)
  const data = identity.identity_data ?? {}
  const subject = String(data.sub ?? data.user_id ?? data.id ?? '')
  const username = typeof data.preferred_username === 'string'
    ? data.preferred_username
    : typeof data.user_name === 'string'
      ? data.user_name
      : typeof data.username === 'string'
        ? data.username
        : null

  if (!platform || !identity.identity_id || !subject) {
    throw new Error('identity is missing a supported provider, identity id, or immutable subject')
  }

  return {
    profile_id: profileId,
    platform,
    provider_identity_id: identity.identity_id,
    provider_subject: subject,
    provider_username: username,
    display_url: platform === 'x' && username ? `https://x.com/${encodeURIComponent(username)}` : null,
  }
}
