import * as jwt from 'jsonwebtoken';
import { getJwtSecret, getJwtExpiration } from './secret';
import { IncomingMessage } from 'http';
import { URL } from 'url';

/**
 * JWT Authentication Module for Signaling Server
 * 
 * SECURITY:
 * - Rejects 'none' algorithm
 * - Hardcodes expected algorithm (HS256) for verification
 * - Validates 'exp' claim
 * - Never derives algorithm from unverified token
 */

export interface JwtPayload {
  sub: string;       // Subject (device ID)
  role: 'host' | 'client';
  iat?: number;
  exp?: number;
}

/**
 * Generate a JWT token for a device.
 * Used by the server admin to pre-authorize devices.
 */
export function generateToken(deviceId: string, role: 'host' | 'client'): string {
  const secret = getJwtSecret();
  const expiresIn = getJwtExpiration();

  const payload: JwtPayload = {
    sub: deviceId,
    role: role,
  };

  return jwt.sign(payload, secret, {
    algorithm: 'HS256',
    expiresIn: expiresIn,
  });
}

/**
 * Verify and decode a JWT token.
 * 
 * SECURITY: 
 * - Algorithm is hardcoded to HS256, never derived from token header.
 * - 'none' algorithm is implicitly rejected by specifying algorithms array.
 * - Token expiration is validated automatically by jsonwebtoken library.
 */
export function verifyToken(token: string): JwtPayload | null {
  try {
    const secret = getJwtSecret();
    const decoded = jwt.verify(token, secret, {
      algorithms: ['HS256'], // Hardcoded — rejects 'none' and other algorithms
    }) as JwtPayload;

    // Validate required fields
    if (!decoded.sub || !decoded.role) {
      console.warn('[Auth] Token missing required fields (sub, role).');
      return null;
    }

    if (decoded.role !== 'host' && decoded.role !== 'client') {
      console.warn('[Auth] Token has invalid role:', decoded.role);
      return null;
    }

    return decoded;
  } catch (error) {
    if (error instanceof jwt.TokenExpiredError) {
      console.warn('[Auth] Token expired.');
    } else if (error instanceof jwt.JsonWebTokenError) {
      console.warn('[Auth] Invalid token:', (error as Error).message);
    } else {
      console.error('[Auth] Unexpected token verification error.');
    }
    return null;
  }
}

/**
 * Extract JWT token from WebSocket upgrade request.
 * Token can be provided via:
 * 1. Query parameter: ws://host:port/?token=xxx
 * 2. Sec-WebSocket-Protocol header (for browser clients)
 * 
 * SECURITY: Query parameters may be logged by proxies.
 * In production, prefer Sec-WebSocket-Protocol or initial message auth.
 */
export function extractTokenFromRequest(req: IncomingMessage): string | null {
  // 1. Try query parameter
  try {
    const baseUrl = `http://${req.headers.host || 'localhost'}`;
    const url = new URL(req.url || '/', baseUrl);
    const queryToken = url.searchParams.get('token');
    if (queryToken) {
      return queryToken;
    }
  } catch {
    // URL parsing failed, continue to next method
  }

  // 2. Try Sec-WebSocket-Protocol header (format: "auth, <token>")
  const protocols = req.headers['sec-websocket-protocol'];
  if (protocols) {
    const parts = protocols.split(',').map(p => p.trim());
    const tokenPart = parts.find(p => p.startsWith('auth.'));
    if (tokenPart) {
      return tokenPart.substring(5); // Remove 'auth.' prefix
    }
  }

  return null;
}
