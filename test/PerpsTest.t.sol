//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "./mocks/MockAggregatorV3Interface.sol";
import {PerpetualVault} from "../src/PerpetualVault.sol";

contract PerpsTest is Test {
    PerpetualVault perpetuals;
    MockV3Aggregator mockAggregator;

    ERC20Mock mockWETHToken;
    ERC20Mock mockUSDToken;

    //Actors
    address public user = makeAddr("firstUser");
    address public user2 = makeAddr("secondUser");

    address public LP = makeAddr("LPProvider");

    // Amount
    uint256 startingUsersAmount = 5000e18; //USD
    uint256 startingLPAmount = 6000e18; //ETH

    function setUp() public {
        mockAggregator = new MockV3Aggregator(8, 3000e8); //ETH/USD
        // Tokens
        mockWETHToken = new ERC20Mock();
        mockUSDToken = new ERC20Mock();

        perpetuals = new PerpetualVault(mockUSDToken, address(mockAggregator));

        mockUSDToken.mint(user, startingUsersAmount);
        mockUSDToken.mint(user2, startingUsersAmount);

        //Kick Start Protocol
        mockUSDToken.mint(address(this), startingLPAmount);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.depositLiquidity(startingLPAmount);
     

    }

    function testLPBalanceIsCorrect() public {
       console2.log(mockUSDToken.balanceOf(address(perpetuals)));
    }

       function testUsersCanOpenPositions() public {
        vm.startPrank(user);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2000e18, leverage: 3, isLong: true});


        vm.stopPrank();

        vm.startPrank(user2);

        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2000e18, leverage: 3, isLong: true});


        vm.stopPrank();

        console2.log(mockUSDToken.balanceOf(address(perpetuals)), "total amount of tokens in perpetuals");
    }

    function testUserCanOpenPositionAndTakeProfit() public {}

    function testLPCanProfitFromDepositing() public {}

    function testAccumulatedFeesAddUp() public {}
}
