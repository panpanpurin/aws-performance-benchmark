// Lambda handler: same Express app as server.js
const serverlessExpress = require('@vendia/serverless-express');
const app = require('./src/app');
const { recordColdStartIfNeeded } = require('./src/metrics');

// Cached handler for warm container invocations
let cachedHandler;

function getHandler() {
  if (!cachedHandler) cachedHandler = serverlessExpress({ app });
  return cachedHandler;
}

exports.handler = async (event, context) => {
  recordColdStartIfNeeded();
  try {
    return await getHandler()(event, context);
  } catch (err) {
    return {
      statusCode: 500,
      body: JSON.stringify({
        error: 'Internal Server Error',
        details: err.message,
      }),
    };
  }
};
