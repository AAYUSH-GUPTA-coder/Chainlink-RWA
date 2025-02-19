// This is gonna simulate, what going to happen in chainlink Nodes / DON

const {
  simulateScript,
  decodeResult,
} = require("@chainlink/functions-toolkit");
const requestConfig = require("../configs/alpacaMintConfig");

async function main() {
  const { responseBytesHexstring, errorString } = await simulateScript(
    requestConfig
  );
  if (responseBytesHexstring) {
    console.log(
      `Response returned by script: ${decodeResult(
        responseBytesHexstring,
        requestConfig.expecetedReturnType
      ).toString()}\n`
    );
  }
  if (errorString) {
    console.log(`Error returned by script: ${errorString}\n`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
