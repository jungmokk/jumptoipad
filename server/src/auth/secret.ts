import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';

/**
 * JWT Secret Management Module
 * 
 * Resolution order:
 * 1. Environment variable JWT_SECRET_KEY
 * 2. Local file jwt_secret.txt (for development)
 * 3. Ephemeral random generation (single-instance only, logs warning)
 * 
 * SECURITY: Never hardcode secrets. In production, use KMS or environment variables.
 */

let cachedSecret: string | null = null;

export function getJwtSecret(): string {
  if (cachedSecret) {
    return cachedSecret;
  }

  // 1. Environment variable (production recommended)
  const envSecret = process.env.JWT_SECRET_KEY;
  if (envSecret && envSecret.length >= 32) {
    cachedSecret = envSecret;
    console.log('[Auth] JWT secret loaded from environment variable.');
    return cachedSecret;
  }
  if (envSecret && envSecret.length < 32) {
    console.warn('[Auth] WARNING: JWT_SECRET_KEY is too short (min 32 chars). Ignoring.');
  }

  // 2. Local file (development)
  const secretFilePath = path.resolve(__dirname, '../../jwt_secret.txt');
  if (fs.existsSync(secretFilePath)) {
    const fileSecret = fs.readFileSync(secretFilePath, 'utf-8').trim();
    if (fileSecret.length >= 32) {
      cachedSecret = fileSecret;
      console.log('[Auth] JWT secret loaded from jwt_secret.txt.');
      return cachedSecret;
    }
    console.warn('[Auth] WARNING: jwt_secret.txt contains a secret shorter than 32 chars. Ignoring.');
  }

  // 3. Ephemeral random generation (development fallback)
  console.warn('[Auth] WARNING: No JWT secret configured. Generating ephemeral secret.');
  console.warn('[Auth] WARNING: This instance is isolated — tokens are not portable across restarts.');
  cachedSecret = crypto.randomBytes(64).toString('hex');
  return cachedSecret;
}

/**
 * Get the configured JWT token expiration time in seconds.
 * Default: 24 hours (86400 seconds).
 */
export function getJwtExpiration(): number {
  const envExpiration = process.env.JWT_EXPIRATION;
  if (envExpiration) {
    const parsed = parseInt(envExpiration, 10);
    if (!isNaN(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return 86400; // 24 hours default
}
