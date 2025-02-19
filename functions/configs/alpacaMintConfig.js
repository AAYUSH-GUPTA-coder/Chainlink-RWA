// config file
// this is the config file for the chainlink functions 
// which tell our simulator how to work

const fs = require("fs");
const {
  Location,
  ReturnType,
  CodeLanguage,
} = require("@chainlink/functions-toolkit");

const requestConfig = {
  source: fs.readFileSync("./functions/sources/alpacaBalance.js").toString(),
  codeLocation: Location.Inline,
  secrets: {
    alpacaKey: process.env.ALPACA_KEY,
    alpacaSecret: process.env.ALPACA_SECRET,
  },
  secretsLocation: Location.DONHosted, // this is where we store our secrets in our DON
  args: [],
  codeLanguage: CodeLanguage.JavaScript,
  expectedReturnType: ReturnType.uint256,
};

module.exports = requestConfig;
