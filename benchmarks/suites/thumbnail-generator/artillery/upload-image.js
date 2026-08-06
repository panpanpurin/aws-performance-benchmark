const fs = require("fs");
const path = require("path");
const FormData = require("form-data");

const fixturesDir = path.resolve(__dirname, "fixtures");
const IMAGE_RE = /\.(jpe?g|png|webp)$/i;

// Sorted so the order does not depend on the filesystem.
const images = fs
  .readdirSync(fixturesDir)
  .filter((f) => IMAGE_RE.test(f))
  .sort()
  .map((f) => path.join(fixturesDir, f));

if (images.length === 0) {
  throw new Error(`No jpg/png/webp fixture found in ${fixturesDir}`);
}

// 1 MB is the ALB request body limit for Lambda targets, so an oversize fixture
// fails on Lambda alone and the loss reads as a platform result. 5 MB is
// multer's limit and fails everywhere. Checked at load time, not mid-run.
const ALB_LAMBDA_MAX_BYTES = 1024 * 1024;
const MULTER_MAX_BYTES = 5 * 1024 * 1024;

const mb = (bytes) => (bytes / 1024 / 1024).toFixed(2);

for (const file of images) {
  const bytes = fs.statSync(file).size;
  const name = path.basename(file);

  if (bytes > MULTER_MAX_BYTES) {
    console.warn(`[fixtures] ${name} is ${mb(bytes)} MB, over multer's 5 MB limit: HTTP 400 everywhere`);
  } else if (bytes > ALB_LAMBDA_MAX_BYTES) {
    console.warn(`[fixtures] ${name} is ${mb(bytes)} MB, over the 1 MB ALB-to-Lambda limit: fails on Lambda only`);
  }
}

console.log(`[fixtures] ${images.length}: ${images.map((f) => path.basename(f)).join(", ")}`);

// One image per arrival. With more than one, Artillery may split arrivals
// across worker threads, each holding its own cursor, so the platforms share
// the mix over a phase but not the exact per-request order.
let cursor = 0;

module.exports = {
  buildFormData: function (requestParams, context, ee, next) {
    const imagePath = images[cursor % images.length];
    cursor += 1;

    const form = new FormData();
    form.append("image", fs.createReadStream(imagePath));

    requestParams.body = form;
    requestParams.headers = form.getHeaders();

    return next();
  },
};
