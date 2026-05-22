import { WebSocketServer, WebSocket } from 'ws';
import { createServer, IncomingMessage } from 'http';
import { v4 as uuidv4 } from 'uuid';
import { verifyToken, extractTokenFromRequest, generateToken, JwtPayload } from './auth/jwt';

/**
 * Jump Desktop Clone — WebSocket Signaling Server
 * 
 * Handles:
 * - Room creation and management (host creates, client joins)
 * - SDP Offer/Answer relay between host and client
 * - ICE Candidate relay
 * - JWT-based authentication on connection
 * - Connection heartbeat/timeout for stale clients
 * 
 * SECURITY:
 * - All connections require valid JWT token
 * - Server listens on 127.0.0.1 for testing, configurable for production
 * - No secrets in code, no sensitive data in logs
 * - Input validation on all messages
 */

// ─── Types ───

interface ConnectedPeer {
  ws: WebSocket;
  deviceId: string;
  role: 'host' | 'client';
  roomId: string | null;
  lastPing: number;
}

interface Room {
  id: string;
  host: ConnectedPeer | null;
  client: ConnectedPeer | null;
  createdAt: number;
}

type SignalingMessageType = 'create_room' | 'join_room' | 'sdp_offer' | 'sdp_answer' | 'ice_candidate' | 'ping' | 'leave_room';

interface SignalingMessage {
  type: SignalingMessageType;
  roomId?: string;
  payload?: unknown;
}

// ─── Server State ───

const rooms = new Map<string, Room>();
const peers = new Map<WebSocket, ConnectedPeer>();

// ─── Configuration ───

const PORT = parseInt(process.env.PORT || '8443', 10);
const HOST = process.env.HOST || '127.0.0.1'; // SECURITY: localhost for testing
const HEARTBEAT_INTERVAL_MS = 30_000;
const PEER_TIMEOUT_MS = 60_000;
const MAX_MESSAGE_SIZE = 64 * 1024; // 64KB max for signaling messages
const MAX_ROOMS = 100;

// ─── HTTP Server ───

const httpServer = createServer((_req, res) => {
  // Health check endpoint
  if (_req.url === '/health') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Cache-Control': 'no-store',
    });
    res.end(JSON.stringify({ status: 'ok', rooms: rooms.size, peers: peers.size }));
    return;
  }

  // Token generation endpoint (for development/testing only)
  // TODO(security): In production, token generation should be done via a separate admin service
  if (_req.url?.startsWith('/generate-token') && _req.method === 'GET') {
    try {
      const url = new URL(_req.url, `http://${_req.headers.host || 'localhost'}`);
      const deviceId = url.searchParams.get('deviceId');
      const role = url.searchParams.get('role') as 'host' | 'client' | null;

      if (!deviceId || !role || (role !== 'host' && role !== 'client')) {
        res.writeHead(400, { 'Content-Type': 'application/json', 'X-Content-Type-Options': 'nosniff' });
        res.end(JSON.stringify({ error: 'Missing or invalid deviceId/role parameter' }));
        return;
      }

      const token = generateToken(deviceId, role);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Cache-Control': 'no-store',
      });
      res.end(JSON.stringify({ token }));
    } catch {
      res.writeHead(500, { 'Content-Type': 'application/json', 'X-Content-Type-Options': 'nosniff' });
      res.end(JSON.stringify({ error: 'Internal server error' }));
    }
    return;
  }

  res.writeHead(404, { 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY' });
  res.end();
});

// ─── WebSocket Server ───

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: MAX_MESSAGE_SIZE,
  verifyClient: (info: { req: IncomingMessage }, callback: (result: boolean, code?: number, message?: string) => void) => {
    const token = extractTokenFromRequest(info.req);
    if (!token) {
      console.warn('[WS] Connection rejected: No token provided.');
      callback(false, 401, 'Authentication required');
      return;
    }

    const payload = verifyToken(token);
    if (!payload) {
      console.warn('[WS] Connection rejected: Invalid token.');
      callback(false, 401, 'Invalid or expired token');
      return;
    }

    // Attach payload to request for use in connection handler
    (info.req as any)._jwtPayload = payload;
    callback(true);
  },
});

wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
  const jwtPayload: JwtPayload = (req as any)._jwtPayload;
  
  const peer: ConnectedPeer = {
    ws,
    deviceId: jwtPayload.sub,
    role: jwtPayload.role,
    roomId: null,
    lastPing: Date.now(),
  };

  peers.set(ws, peer);
  console.log(`[WS] Connected: ${peer.role} (${peer.deviceId}). Total peers: ${peers.size}`);

  // Send welcome message
  sendMessage(ws, {
    type: 'welcome',
    deviceId: peer.deviceId,
    role: peer.role,
  });

  ws.on('message', (data) => {
    try {
      const raw = data.toString();
      
      // Input validation: check size
      if (raw.length > MAX_MESSAGE_SIZE) {
        sendError(ws, 'Message too large');
        return;
      }

      const message: SignalingMessage = JSON.parse(raw);

      // Input validation: check required fields
      if (!message.type || typeof message.type !== 'string') {
        sendError(ws, 'Missing or invalid message type');
        return;
      }

      handleMessage(peer, message);
    } catch {
      sendError(ws, 'Invalid JSON message');
    }
  });

  ws.on('close', () => {
    handleDisconnect(peer);
  });

  ws.on('error', (error) => {
    console.error(`[WS] Error for ${peer.role} (${peer.deviceId}):`, error.message);
    handleDisconnect(peer);
  });
});

// ─── Message Handler ───

function handleMessage(peer: ConnectedPeer, message: SignalingMessage): void {
  peer.lastPing = Date.now();

  switch (message.type) {
    case 'create_room':
      handleCreateRoom(peer);
      break;

    case 'join_room':
      if (!message.roomId || typeof message.roomId !== 'string') {
        sendError(peer.ws, 'Missing or invalid roomId');
        return;
      }
      handleJoinRoom(peer, message.roomId);
      break;

    case 'sdp_offer':
    case 'sdp_answer':
    case 'ice_candidate':
      handleRelay(peer, message);
      break;

    case 'ping':
      sendMessage(peer.ws, { type: 'pong', timestamp: Date.now() });
      break;

    case 'leave_room':
      handleLeaveRoom(peer);
      break;

    default:
      sendError(peer.ws, `Unknown message type: ${message.type}`);
  }
}

// ─── Room Management ───

function handleCreateRoom(peer: ConnectedPeer): void {
  if (peer.role !== 'host') {
    sendError(peer.ws, 'Only host devices can create rooms');
    return;
  }

  if (peer.roomId) {
    sendError(peer.ws, 'Already in a room. Leave first.');
    return;
  }

  if (rooms.size >= MAX_ROOMS) {
    sendError(peer.ws, 'Maximum number of rooms reached');
    return;
  }

  const roomId = uuidv4().substring(0, 8).toUpperCase(); // Short room code for easy sharing
  const room: Room = {
    id: roomId,
    host: peer,
    client: null,
    createdAt: Date.now(),
  };

  rooms.set(roomId, room);
  peer.roomId = roomId;

  console.log(`[Room] Created: ${roomId} by host ${peer.deviceId}. Total rooms: ${rooms.size}`);

  sendMessage(peer.ws, {
    type: 'room_created',
    roomId: roomId,
  });
}

function handleJoinRoom(peer: ConnectedPeer, roomId: string): void {
  if (peer.role !== 'client') {
    sendError(peer.ws, 'Only client devices can join rooms');
    return;
  }

  if (peer.roomId) {
    sendError(peer.ws, 'Already in a room. Leave first.');
    return;
  }

  // Input validation: sanitize roomId
  const sanitizedRoomId = roomId.replace(/[^A-Za-z0-9-]/g, '').substring(0, 36);
  const room = rooms.get(sanitizedRoomId);

  if (!room) {
    sendError(peer.ws, 'Room not found');
    return;
  }

  if (room.client) {
    sendError(peer.ws, 'Room is full');
    return;
  }

  room.client = peer;
  peer.roomId = sanitizedRoomId;

  console.log(`[Room] Joined: ${sanitizedRoomId} by client ${peer.deviceId}`);

  // Notify both peers
  sendMessage(peer.ws, {
    type: 'room_joined',
    roomId: sanitizedRoomId,
  });

  if (room.host?.ws.readyState === WebSocket.OPEN) {
    sendMessage(room.host.ws, {
      type: 'peer_joined',
      deviceId: peer.deviceId,
    });
  }
}

function handleLeaveRoom(peer: ConnectedPeer): void {
  if (!peer.roomId) {
    return;
  }

  const room = rooms.get(peer.roomId);
  if (!room) {
    peer.roomId = null;
    return;
  }

  const otherPeer = peer.role === 'host' ? room.client : room.host;

  // Notify the other peer
  if (otherPeer?.ws.readyState === WebSocket.OPEN) {
    sendMessage(otherPeer.ws, {
      type: 'peer_left',
      deviceId: peer.deviceId,
    });
  }

  // Remove peer from room
  if (peer.role === 'host') {
    room.host = null;
  } else {
    room.client = null;
  }

  // Clean up empty room
  if (!room.host && !room.client) {
    rooms.delete(peer.roomId);
    console.log(`[Room] Destroyed: ${peer.roomId}. Total rooms: ${rooms.size}`);
  }

  peer.roomId = null;
}

// ─── SDP/ICE Relay ───

function handleRelay(peer: ConnectedPeer, message: SignalingMessage): void {
  if (!peer.roomId) {
    sendError(peer.ws, 'Not in a room');
    return;
  }

  const room = rooms.get(peer.roomId);
  if (!room) {
    sendError(peer.ws, 'Room not found');
    return;
  }

  // Determine target peer
  const targetPeer = peer.role === 'host' ? room.client : room.host;

  if (!targetPeer || targetPeer.ws.readyState !== WebSocket.OPEN) {
    sendError(peer.ws, 'Peer not connected');
    return;
  }

  // Relay the message to the other peer
  sendMessage(targetPeer.ws, {
    type: message.type,
    payload: message.payload,
    from: peer.role,
  });
}

// ─── Disconnect Handler ───

function handleDisconnect(peer: ConnectedPeer): void {
  console.log(`[WS] Disconnected: ${peer.role} (${peer.deviceId}). Total peers: ${peers.size - 1}`);

  handleLeaveRoom(peer);
  peers.delete(peer.ws);
}

// ─── Heartbeat (stale connection cleanup) ───

const heartbeatInterval = setInterval(() => {
  const now = Date.now();

  peers.forEach((peer) => {
    if (now - peer.lastPing > PEER_TIMEOUT_MS) {
      console.log(`[Heartbeat] Timeout: ${peer.role} (${peer.deviceId})`);
      peer.ws.terminate();
      handleDisconnect(peer);
    }
  });

  // Clean up stale empty rooms (older than 5 minutes)
  rooms.forEach((room, roomId) => {
    if (!room.host && !room.client && now - room.createdAt > 5 * 60 * 1000) {
      rooms.delete(roomId);
      console.log(`[Room] GC'd stale room: ${roomId}`);
    }
  });
}, HEARTBEAT_INTERVAL_MS);

// ─── Utility Functions ───

function sendMessage(ws: WebSocket, data: Record<string, unknown>): void {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

function sendError(ws: WebSocket, message: string): void {
  sendMessage(ws, { type: 'error', message });
}

// ─── Server Start ───

httpServer.listen(PORT, HOST, () => {
  console.log('═══════════════════════════════════════════════════');
  console.log('  Jump Desktop Clone — Signaling Server');
  console.log(`  Listening on wss://${HOST}:${PORT}`);
  console.log(`  Health check: http://${HOST}:${PORT}/health`);
  console.log('  Env: ' + (process.env.NODE_ENV || 'development'));
  console.log('═══════════════════════════════════════════════════');
});

// ─── Graceful Shutdown ───

function shutdown(): void {
  console.log('\n[Server] Shutting down gracefully...');

  clearInterval(heartbeatInterval);

  // Close all WebSocket connections
  peers.forEach((peer) => {
    sendMessage(peer.ws, { type: 'server_shutdown' });
    peer.ws.close(1001, 'Server shutting down');
  });

  wss.close(() => {
    httpServer.close(() => {
      console.log('[Server] Shutdown complete.');
      process.exit(0);
    });
  });

  // Force exit after 5 seconds
  setTimeout(() => {
    console.error('[Server] Forced shutdown after timeout.');
    process.exit(1);
  }, 5000);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
