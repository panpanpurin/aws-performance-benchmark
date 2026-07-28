const fs = require("fs");
const path = require("path");
const FormData = require("form-data");

const imagePath = path.resolve(__dirname, "fixtures", "sample.jpg");

module.exports = {
  buildFormData: function (requestParams, context, ee, next) {
    const form = new FormData();
    form.append("image", fs.createReadStream(imagePath));

    requestParams.body = form;
    requestParams.headers = form.getHeaders();

    return next();
  },
};
