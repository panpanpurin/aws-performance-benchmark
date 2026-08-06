const fs = require("fs");
const path = require("path");
const FormData = require("form-data");

const fixturesDir = path.resolve(__dirname, "fixtures");
const IMAGE_RE = /\.(jpe?g|png|webp)$/i;

// Mirrors the AWS suite's processor so local exercises the same fixture.
const images = fs
  .readdirSync(fixturesDir)
  .filter((f) => IMAGE_RE.test(f))
  .sort()
  .map((f) => path.join(fixturesDir, f));

if (images.length === 0) {
  throw new Error(`No jpg/png/webp fixture found in ${fixturesDir}`);
}

console.log(`[fixtures] ${images.length}: ${images.map((f) => path.basename(f)).join(", ")}`);

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
