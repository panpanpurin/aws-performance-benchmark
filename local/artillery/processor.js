const fs = require("fs");
const path = require("path");
const FormData = require("form-data");

// Prefer small local fixture; fall back to data.csv if present
const csvPath = fs.existsSync(path.resolve(__dirname, "pokes.csv"))
  ? path.resolve(__dirname, "pokes.csv")
  : path.resolve(__dirname, "data.csv");

module.exports = {
  buildCsvRequest: function (requestParams, context, ee, next) {
    const form = new FormData();
    form.append("file", fs.createReadStream(csvPath));
    form.append("filters", JSON.stringify({ level: { $gt: 20 } }));
    form.append("columns", JSON.stringify(["type", "attack", "defense"]));
    form.append("grouping", JSON.stringify(["type"]));
    form.append(
      "operations",
      JSON.stringify({ attack: "mean", defense: "sum" })
    );

    requestParams.body = form;
    requestParams.headers = form.getHeaders();

    return next();
  },
};
