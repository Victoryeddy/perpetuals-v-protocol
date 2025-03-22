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

    ERC20Mock mockUSDToken;

    //Actors
    address public user = makeAddr("firstUser");
    address public user2 = makeAddr("secondUser");
    address public LP = makeAddr("LPProvider");

    // Amount
    uint256 startingAmount = 5e18;

    function setUp() public {
        mockAggregator = new MockV3Aggregator(8, 2000);
        mockUSDToken = new ERC20Mock();
        perpetuals = new PerpetualVault(mockUSDToken, address(mockAggregator));
        mockUSDToken.mint(user, startingAmount);
        mockUSDToken.mint(user2, startingAmount);

        //Kick Start Protocol
        mockUSDToken.mint(address(this), startingAmount);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.depositLiquidity(startingAmount);
    }

    function testUsersCanOpenPositions() public {
        vm.startPrank(user);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2000e18, leverage: 3, isLong: true});

        uint256 userCount = perpetuals.getUserPosition();

        console2.log(userCount, "first current user count");
        vm.stopPrank();

        vm.startPrank(user2);

        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2000e18, leverage: 3, isLong: true});

        uint256 userCount2 = perpetuals.getUserPosition();

        console2.log(userCount2, "second current user count");
        vm.stopPrank();

        console2.log(mockUSDToken.balanceOf(address(perpetuals)), "total amount of tokens in perpetuals");
    }

    function testUserCanOpenPositionAndTakeProfit() public {
        vm.startPrank(user);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2000e18, leverage: 3, isLong: true});

        mockAggregator.updateAnswer(4000);

        perpetuals.closePosition(0);
        uint256 balanceAfterProfit = mockUSDToken.balanceOf(user);
        vm.stopPrank();
        console2.log(balanceAfterProfit, "balance After");
        assertGe(mockUSDToken.balanceOf(user), startingAmount);
    }

    function testLPCanProfitFromDepositing() public {
        vm.startPrank(user);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2e16, leverage: 3, isLong: true});

        mockAggregator.updateAnswer(2400);
        perpetuals.closePosition(0);
        vm.stopPrank();

        perpetuals.withdrawLiquidity(4e18);
        perpetuals.distributeLPRewards();
        perpetuals.claimLPRewards();

        uint256 fees = perpetuals.getAccumulatedFees();

        console2.log(mockUSDToken.balanceOf(address(this)), "lp provider");
        console2.log(mockUSDToken.balanceOf(user), "user balance");
        console2.log(mockUSDToken.balanceOf(address(perpetuals)), "Perpetual balance");
        console2.log(fees, "Fees to pay to LP");
    }

    function testAccumulatedFeesAddUp() public {
        vm.startPrank(user);
        mockUSDToken.approve(address(perpetuals), type(uint256).max);
        perpetuals.openPosition({collateral: 2e18, leverage: 3, isLong: true});
        vm.stopPrank();

        uint256 fees = perpetuals.getAccumulatedFees();
        assertEq(fees, 3e16);
        //Got this 45 000 000 000 000 000 000
    }
}
