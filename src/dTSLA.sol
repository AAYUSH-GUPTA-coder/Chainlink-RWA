// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title dTSLA
 * @notice This is our contract to make requests to the Alpaca API to mint TSLA-backed dTSLA tokens
 */
contract dTSLA is FunctionsClient, ConfirmedOwner, ERC20, Pausable {
    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;
    using Strings for uint256;

    error dTSLA__NotEnoughCollateral();
    error dTSLA__BelowMinimumRedemption();
    error dTSLA__RedemptionFailed();

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error UnexpectedRequestID(bytes32 requestId);

    /// enum to track, either we want to mint to Mint dTSLA token against TSLA STOCK and redeem TSLA Stock against dTSLA token
    enum MintOrRedeem {
        mint,
        redeem
    }

    /// Struct to store Mint or Reddem Request details
    struct dTslaRequest {
        uint256 amountOfToken; // amount of token to be minted or redeemed
        address requester; // address of the user who initiated the request
        MintOrRedeem mintOrRedeem; // whether to mint or redeem
    }

    /*//////////////////////////////////////////////////////////////
                                CONTANTS
    //////////////////////////////////////////////////////////////*/
    uint32 private constant GAS_LIMIT = 300_000;
    uint64 immutable i_subId;

    /*//////////////////////////////////////////////////////////////
                           STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Check to get the router address for your supported network
    // https://docs.chain.link/chainlink-functions/supported-networks
    address s_functionsRouter;
    string s_mintSource;
    string s_redeemSource;

    // Check to get the donID for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    bytes32 s_donID;
    uint256 s_portfolioBalance;
    uint64 s_secretVersion;
    uint8 s_secretSlot;

    /// @dev mapping to keep track of request ID (ID given by Chainlink function client when we initiate a request) and request ID Details
    mapping(bytes32 requestId => dTslaRequest request) private s_requestIdToRequest;

    /// @dev Mapping to keep track of user and their withdrawal amount
    mapping(address user => uint256 amountAvailableForWithdrawal) private s_userToWithdrawalAmount;

    address public i_tslaUsdFeed;
    address public i_usdcUsdFeed;
    address public i_redemptionCoin;

    // This hard-coded value isn't great engineering. Please check with your brokerage
    // and update accordingly
    // For example, for Alpaca: https://alpaca.markets/support/crypto-wallet-faq
    uint256 public constant MINIMUM_REDEMPTION_COIN_REDEMPTION_AMOUNT = 100e18;

    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PORTFOLIO_PRECISION = 1e18;
    uint256 public constant COLLATERAL_RATIO = 200; // 200% collateral ratio
    uint256 public constant COLLATERAL_PRECISION = 100;

    uint256 private constant TARGET_DECIMALS = 18;
    uint256 private constant PRECISION = 1e18;
    uint256 private immutable i_redemptionCoinDecimals;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Response(bytes32 indexed requestId, uint256 character, bytes response, bytes err);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes the contract with the Chainlink router address and sets the contract owner
     */
    constructor(
        uint64 subId, // chainlink function subscription ID
        string memory mintSource, // // Raw javascript code for API
        string memory redeemSource,
        address functionsRouter, // address of functionsRouter
        bytes32 donId, // chainlink function DON ID
        address tslaPriceFeed,
        address usdcPriceFeed,
        address redemptionCoin,
        uint64 secretVersion,
        uint8 secretSlot
    ) FunctionsClient(functionsRouter) ConfirmedOwner(msg.sender) ERC20("dTSLA", "dTSLA") {
        s_mintSource = mintSource;
        s_redeemSource = redeemSource;
        s_functionsRouter = functionsRouter;
        s_donID = donId;
        i_tslaUsdFeed = tslaPriceFeed;
        i_usdcUsdFeed = usdcPriceFeed;
        i_subId = subId;
        i_redemptionCoin = redemptionCoin;
        i_redemptionCoinDecimals = ERC20(redemptionCoin).decimals();

        s_secretVersion = secretVersion;
        s_secretSlot = secretSlot;
    }

    function setSecretVersion(uint64 secretVersion) external onlyOwner {
        s_secretVersion = secretVersion;
    }

    function setSecretSlot(uint8 secretSlot) external onlyOwner {
        s_secretSlot = secretSlot;
    }

    /**
     * @notice Send an HTTP / Chainlink Functions request to:
     * 1. See how much TSLA is brought
     * 2. If enough TSLA is in alpaca account
     * 3. mint dTSLA
     * 2 transcation function, Request and Receive.
     * we are going to send the MINT request or chainlink oracle going to check our bank account and to see if there is enough tesla is there and in the second transcation it's going to call back to our contract and say Yes or NO you have / haven't enough tesla to mint dTSLA token.
     * @dev If you pass 0, that will act just as a way to get an updated portfolio balance
     * @param amountOfTokensToMint The amount of tokens to mint
     * @return requestId The ID of the request
     */
    function sendMintRequest(uint256 amountOfTokensToMint)
        external
        onlyOwner
        whenNotPaused
        returns (bytes32 requestId)
    {
        // they want to mint $100 and the portfolio has $200 - then that's cool
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSource); // Initialize the request with JS code
        req.addDONHostedSecrets(s_secretSlot, s_secretVersion);

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, s_donID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountOfTokensToMint, msg.sender, MintOrRedeem.mint);
        return requestId;
    }

    /**
     * @notice user sends a Chainlink Functions request to sell TSLA for redemptionCoin (USDC)
     * @notice This will, have the chainlink function call our alpaca (bank)
     * and do the following
     * 1. Burn dTSLA
     * 2. Sell TSLA on the brokerage
     * 3. Buy USDC on the brokerage
     * 4. Send USDC to this contract for the user to withdraw
     * @notice this will put the redemptionCoin in a withdrawl queue that the user must call to redeem
     * @param amountdTsla - the amount of dTSLA to redeem
     */
    function sendRedeemRequest(uint256 amountdTsla) external whenNotPaused returns (bytes32 requestId) {
        // Should be able to just always redeem?
        // @audit potential exploit here, where if a user can redeem more than the collateral amount
        // Checks
        // Remember, this has 18 decimals
        uint256 amountTslaInUsdc = getUsdcValueOfUsd(getUsdValueOfTsla(amountdTsla));
        if (amountTslaInUsdc < MINIMUM_REDEMPTION_COIN_REDEMPTION_AMOUNT) {
            revert dTSLA__BelowMinimumRedemption();
        }

        // Internal Effects
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSource); // Initialize the request with JS code
        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        // The transaction will fail if it's outside of 2% slippage
        // This could be a future improvement to make the slippage a parameter by someone
        args[1] = amountTslaInUsdc.toString();
        req.setArgs(args);

        // Send the request and store the request ID
        // We are assuming requestId is unique
        requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, s_donID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountdTsla, msg.sender, MintOrRedeem.redeem);

        // External Interactions
        _burn(msg.sender, amountdTsla);
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @dev why internal override, because Chainlink Node will call handleOracleFulfillment() in FunctionsClient.sol contract that is calling fulfillRequest() in the same contract. We are overriding that fulfillRequest()
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /* err */ )
        internal
        override
        whenNotPaused
    {
        if (s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint) {
            _mintFulFillRequest(requestId, response);
        } else {
            _redeemFulFillRequest(requestId, response);
        }
    }

    function withdraw() external whenNotPaused {
        uint256 amountToWithdraw = s_userToWithdrawalAmount[msg.sender];
        s_userToWithdrawalAmount[msg.sender] = 0;
        // Send the user their USDC
        bool succ = ERC20(i_redemptionCoin).transfer(msg.sender, amountToWithdraw);
        if (!succ) {
            revert dTSLA__RedemptionFailed();
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// Return the amount of TSLA value ( in USD ) is stored in our brokerage
    /// if we have enough TSLA token, mint the dTSLA
    function _mintFulFillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }

        if (amountOfTokensToMint != 0) {
            _mint(s_requestIdToRequest[requestId].requester, amountOfTokensToMint);
        }
        // Do we need to return anything?
    }

    /**
     * @notice the callback for the redeem request
     * At this point, USDC should be in this contract, and we need to update the user
     * That they can now withdraw their USDC
     *
     * @param requestId - the requestId that was fulfilled
     * @param response - the response from the request, it'll be the amount of USDC that was sent
     */
    function _redeemFulFillRequest(bytes32 requestId, bytes memory response) internal {
        // This is going to have redemptioncoindecimals decimals
        uint256 usdcAmount = uint256(bytes32(response));
        uint256 usdcAmountWad;
        if (i_redemptionCoinDecimals < 18) {
            usdcAmountWad = usdcAmount * (10 ** (18 - i_redemptionCoinDecimals));
        }
        if (usdcAmount == 0) {
            // revert dTSLA__RedemptionFailed();
            // Redemption failed, we need to give them a refund of dTSLA
            // This is a potential exploit, look at this line carefully!!
            uint256 amountOfdTSLABurned = s_requestIdToRequest[requestId].amountOfToken;
            _mint(s_requestIdToRequest[requestId].requester, amountOfdTSLABurned);
            return;
        }

        s_userToWithdrawalAmount[s_requestIdToRequest[requestId].requester] += usdcAmount;
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(amountOfTokensToMint);
        return (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW AND PURE
    //////////////////////////////////////////////////////////////*/
    function getPortfolioBalance() public view returns (uint256) {
        return s_portfolioBalance;
    }

    // TSLA USD has 8 decimal places, so we add an additional 10 decimal places
    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_tslaUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @dev function to get the value of USDC in USD. Note: Price of USDC also fluctuate with time
     */
    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_usdcUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @dev function to get the value of TSLA Share in USD
     * @param tslaAmount - the amount of TSLA to convert to USD in WAD
     */
    function getUsdValueOfTsla(uint256 tslaAmount) public view returns (uint256) {
        return (tslaAmount * getTslaPrice()) / PRECISION;
    }

    /**
     * @dev function to get the value of USD in terms of USDC. Note: Price of USDC also fluctuate with time
     * @param usdAmount - Pass the USD amount with 18 decimals
     * @return the amount of USDC (redemptionCoin) with 18 decimals (WAD)
     */
    function getUsdcValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * PRECISION) / getUsdcPrice();
    }

    function getTotalUsdValue() public view returns (uint256) {
        return (totalSupply() * getTslaPrice()) / PRECISION;
    }

    /// The new expected total value in USD of all the dTSLA tokens combined
    /// @param addedNumberOfTsla amount of TSLA token minted
    function getCalculatedNewTotalValue(uint256 addedNumberOfTsla) public view returns (uint256) {
        return ((totalSupply() + addedNumberOfTsla) * getTslaPrice()) / PRECISION;
    }

    function getRequest(bytes32 requestId) public view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }

    function getWithdrawalAmount(address user) public view returns (uint256) {
        return s_userToWithdrawalAmount[user];
    }
}
