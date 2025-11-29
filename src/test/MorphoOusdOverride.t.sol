// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

import {OperationTest} from "./Operation.t.sol";
import {ShutdownTest} from "./Shutdown.t.sol";
import {OracleTest, StrategyAprOracle} from "./Oracle.t.sol";

import {MorphoAprOracle} from "../periphery/MorphoAprOracle.sol";
import {IMorphoCompounder} from "../Strategies/Morpho/interfaces/IMorphoCompounder.sol";
import {MorphoOusd, Id} from "../Strategies/Morpho/Mainnet/MorphoOusd.sol";
import {IMetaMorpho} from "../interfaces/Morpho/IMetaMorpho.sol";

import {AuctionFactory, Auction} from "@periphery/Auctions/AuctionFactory.sol";

abstract contract MorphoOusdSetup is Setup {

    address public MORPHO = 0x9D03bb2092270648d7480049d0E58d2FcF0E5123;

    address public swapToken;

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    address public OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;


    function setUp() public virtual override {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);
        minFuzzAmount = 1e6;
        maxFuzzAmount = 100_000e6;

        // Yearn USDC vault
        vault = 0xF9bdDd4A9b3A45f980e11fDDE96e16364dDBEc49;
        user = OUSD;

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        // MORPHO token
        swapToken = tokenAddrs["MORPHO"];

        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new MorphoOusd(
                    address(asset),
                    "Morpho OUSD Strategy",
                    vault,
                    OUSD
                )
            )
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);
        _strategy.setEmergencyAdmin(SMS);
        _strategy.setProfitMaxUnlockTime(60 * 60 * 24 * 3);
        // set to idle market
        MorphoOusd(address(_strategy)).setSupplyMarketId(Id.wrap(0x54efdee08e272e929034a8f26f7ca34b1ebe364b275391169b28c6d7db24dbc8));

        vm.prank(management);
        _strategy.acceptManagement();


        address usdcMorphoVaultOwner = 0xe5e2Baf96198c56380dDD5E992D7d1ADa0e989c0;
        vm.startPrank(usdcMorphoVaultOwner);
        IMetaMorpho(vault).setIsAllocator(address(_strategy), true);
        vm.stopPrank();

        return address(_strategy);
    }
}

contract MorphoOusdOperationTest is OperationTest, MorphoOusdSetup {

    function setUp() public virtual override(OperationTest, MorphoOusdSetup) {
        MorphoOusdSetup.setUp();

        vm.startPrank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            swapToken,
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        IMorphoCompounder(address(strategy)).setUniFees(
            swapToken,
            IMorphoCompounder(address(strategy)).base(),
            100
        );

        IMorphoCompounder(address(strategy)).setUniFees(
            IMorphoCompounder(address(strategy)).base(),
            address(asset),
            100
        );
        vm.stopPrank();
    }

    function setUpStrategy() public virtual override(Setup, MorphoOusdSetup) returns (address) {
        return MorphoOusdSetup.setUpStrategy();
    }

    function test_random_user_cant_deposit() public {
        uint256 amount = 1000e6;
        address randomUser = address(0x123);
        airdrop(ERC20(asset), randomUser, amount);
        vm.startPrank(randomUser);
        ERC20(asset).approve(address(strategy), amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(amount, randomUser);
    }

    function _test_uniswapV3_swap() public {
        uint256 amount = 1000e6;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setDoHealthCheck(false);

        airdrop(ERC20(swapToken), address(strategy), amount);

        assertEq(
            ERC20(swapToken).balanceOf(address(strategy)),
            amount,
            "!swap"
        );
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");

        vm.prank(keeper);
        strategy.report();

        assertEq(ERC20(swapToken).balanceOf(address(strategy)), 0, "!swap");
        assertGt(asset.balanceOf(address(strategy)), 0, "!asset");
    }

    function test_auctionSwap() public {
        uint256 amount = 1000e6;
        mintAndDepositIntoStrategy(strategy, user, amount);

        airdrop(ERC20(swapToken), address(strategy), amount);

        address auction = AuctionFactory(
            0xa076c247AfA44f8F006CA7f21A4EF59f7e4dc605
        ).createNewAuction(address(asset), address(strategy), management);

        vm.prank(management);
        Auction(auction).enable(swapToken);

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setSwapType(
            swapToken,
            IMorphoCompounder.SwapType.AUCTION
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setAuction(address(auction));

        assertEq(
            ERC20(swapToken).balanceOf(address(strategy)),
            amount,
            "!swap"
        );

        vm.prank(keeper);
        uint256 kicked = IMorphoCompounder(address(strategy)).kickAuction(
            swapToken
        );

        assertEq(kicked, amount, "!kicked");
        assertEq(ERC20(swapToken).balanceOf(address(strategy)), 0, "!swap");
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");
        assertTrue(Auction(auction).isActive(swapToken), "!active");
    }

    function test_allRewardTokens() public {
        vm.expectRevert();
        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            address(asset),
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        vm.expectRevert();
        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            address(vault),
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            1,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[0],
            swapToken,
            "!swapToken"
        );

        address toAdd = tokenAddrs["DAI"];

        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            toAdd,
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            2,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[1],
            toAdd,
            "!toAdd"
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).removeRewardToken(swapToken);

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            1,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[0],
            toAdd,
            "!toAdd"
        );
        assertEq(
            uint256(IMorphoCompounder(address(strategy)).swapType(swapToken)),
            0,
            "!swapType"
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).removeRewardToken(toAdd);

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            0,
            "!length"
        );
        assertEq(
            uint256(IMorphoCompounder(address(strategy)).swapType(toAdd)),
            0,
            "!swapType"
        );
    }
}

contract MorphoOusdShutdownTest is ShutdownTest, MorphoOusdSetup {
    function setUp() public virtual override(ShutdownTest, MorphoOusdSetup) {
        MorphoOusdSetup.setUp();
    }

    function setUpStrategy() public virtual override(Setup, MorphoOusdSetup) returns (address) {
        return MorphoOusdSetup.setUpStrategy();
    }
}

contract MorphoOusdOracleTest is OracleTest, MorphoOusdSetup {

    function setUp() public virtual override(OracleTest, MorphoOusdSetup) {
        MorphoOusdSetup.setUp();

        oracle = StrategyAprOracle(address(new MorphoAprOracle()));
        MorphoAprOracle(address(oracle)).setMorphoRate(vault, 6898500000000000);
    }

    function setUpStrategy() public virtual override(Setup, MorphoOusdSetup) returns (address) {
        return MorphoOusdSetup.setUpStrategy();
    }

    function test_oracle(uint256 _amount, uint16 _percentChange) public virtual override {
        uint256 rewardsRate = MorphoAprOracle(address(oracle)).getRewardsRate(vault);
        console.log("Rewards rate is ", rewardsRate);
        super.test_oracle(_amount, _percentChange);
    }
}
