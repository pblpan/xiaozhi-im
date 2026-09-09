const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const config = require('./config');

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}

function verifyPassword(password, stored) {
  const [salt, hash] = (stored || '').split(':');
  if (!salt || !hash) return false;
  const calc = crypto.scryptSync(password, salt, 64).toString('hex');
  return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(calc, 'hex'));
}

function signToken(payload) {
  return jwt.sign(payload, config.JWT_SECRET, { expiresIn: '30d' });
}

function verifyToken(token) {
  if (!token) return null;
  try { return jwt.verify(token, config.JWT_SECRET); }
  catch { return null; }
}

module.exports = { hashPassword, verifyPassword, signToken, verifyToken };
