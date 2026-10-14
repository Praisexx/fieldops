class ApiError extends Error {
  constructor(status, code, message, fields) {
    super(message);
    Object.assign(this, { status, code, fields });
  }
}
// Express 4 does not catch rejected promises; wrap async handlers.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
module.exports = { ApiError, wrap };
