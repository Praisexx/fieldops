const jwt = require('jsonwebtoken');
const { ApiError } = require('./errors');

const SECRET = process.env.JWT_SECRET;
if (!SECRET) throw new Error('JWT_SECRET is required');

const ACCESS_TTL_SECONDS = 15 * 60;
const signAccess = (user) => jwt.sign({ sub: user.id }, SECRET, { expiresIn: ACCESS_TTL_SECONDS });

function requireAuth(req, _res, next) {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  if (!m) return next(new ApiError(401, 'unauthorized', 'Missing access token'));
  try {
    req.userId = jwt.verify(m[1], SECRET).sub;
    next();
  } catch (e) {
    // Distinct code lets the app trigger a refresh instead of a logout.
    next(new ApiError(401, e.name === 'TokenExpiredError' ? 'token_expired' : 'unauthorized', 'Session expired or invalid'));
  }
}

module.exports = { signAccess, requireAuth, ACCESS_TTL_SECONDS };
