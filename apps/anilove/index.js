// Lambda handler: same Express app via serverless-express
const serverlessExpress = require('@vendia/serverless-express');
const app = require('./src/app');
const { recordColdStartOnce } = require('./src/metrics');

// Cached proxy for warm container invocations
let proxy;

exports.handler = async (event, context) => {
  recordColdStartOnce();
  if (!proxy) proxy = serverlessExpress({ app });
  return proxy(event, context);
};
