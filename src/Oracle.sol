// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


library OracleLibrary {
    /**
     * @dev Fetches the latest price from a Chainlink price feed.
     * @param priceFeed Address of the Chainlink price feed.
     * @return price Latest price scaled to 18 decimals.
     */
    function getLatestPrice(address priceFeed) internal view returns (uint256 price) {
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        
        // Get latest round data
        (, int256 priceRaw, , , ) = feed.latestRoundData();

        if(priceRaw < 0) revert("Invalid price data");

        // Scale price to 18 decimals
        uint8 decimals = feed.decimals();
        price = uint256(priceRaw) * (10 ** (18 - decimals));
    }
}