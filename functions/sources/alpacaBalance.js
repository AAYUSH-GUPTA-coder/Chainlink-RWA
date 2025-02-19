// Alpaca Balance Script
// this will call our alpaca account and figure out how much money is in there 

if (secrets.alpacaKey == "" || secrets.alpacaSecret == "") {
  throw Error("Need alpaca Keys");
}

const alpacaRequest = Functions.makeHttpRequest({
  url: "https://paper-api.alpaca.markets/v2/account",
  headers: {
    accept: "application/json",
    "APCA-API-KEY-ID": secrets.alpacaKey,
    "APCA-API-SECRET-KEY": secrets.alpacaSecret,
  },
});

const [response] = await Promise.all([alpacaRequest]);

const portfolioBalance = response.data.portfolio_value;
console.log(`Alpaca Portfolio Balance: ${portfolioBalance}`);

return Functions.encodeUint256(Math.round(portfolioBalance * 100));
