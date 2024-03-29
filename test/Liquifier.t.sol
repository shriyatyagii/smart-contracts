// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "../src/eigenlayer-interfaces/IDelegationManager.sol";

interface IWBETH {
    function exchangeRate() external view returns (uint256);
    function deposit(address referral) external payable;
}

contract LiquifierTest is TestSetup {

    uint256 public testnetFork;

    function setUp() public {
    }

    function _setUp(uint8 forkEnum) internal {
        initializeTestingFork(forkEnum);
        setUpLiquifier(forkEnum);

        vm.startPrank(owner);
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 0, 50, 1000); // 50 ether timeBoundCap, 1000 ether total cap
        if (forkEnum == MAINNET_FORK) {
            liquifierInstance.registerToken(address(cbEth), address(cbEthStrategy), true, 0, 50, 1000);
            liquifierInstance.registerToken(address(wbEth), address(wbEthStrategy), true, 0, 50, 1000);
        }
        vm.stopPrank();
    }

    function test_rando_deposit_fails() public {
        _setUp(MAINNET_FORK);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert("not allowed");
        payable(address(liquifierInstance)).call{value: 10 ether}("");
        vm.stopPrank();
    }

    function test_deposit_above_cap() public {
        _setUp(MAINNET_FORK);
        
        vm.startPrank(0x6D44bfB8432d17882bB6e84652f5C3B36fcC8280);
        cbEth.mint(alice, 100 ether);
        vm.stopPrank();

        vm.deal(alice, 1000 ether);

        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 50 ether), false);
        assertTrue(!liquifierInstance.isDepositCapReached(address(cbEth), 0));
        assertTrue(!liquifierInstance.isDepositCapReached(address(wbEth), 0));

        vm.startPrank(alice);
        stEth.submit{value: 1000 ether}(address(0));
        stEth.approve(address(liquifierInstance), 50 ether);
        liquifierInstance.depositWithERC20(address(stEth), 50 ether, address(0));
        vm.stopPrank();

        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 50 ether, 0.1 ether);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 1 ether), true);
        assertTrue(!liquifierInstance.isDepositCapReached(address(cbEth), 1 ether));
        assertTrue(!liquifierInstance.isDepositCapReached(address(wbEth), 1 ether));

        skip(3600);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 50 ether), false);

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 10, 1000);
        vm.stopPrank();

        vm.startPrank(alice);
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));
        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 60 ether, 0.1 ether);

        stEth.approve(address(liquifierInstance), 10 ether);
        vm.expectRevert("CAPPED");
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 10, 1000);
        vm.stopPrank();

        _moveClock(1000);

        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 10 ether), false);

        // Set the total cap to 100 ether
        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 100, 100);
        vm.stopPrank();

        // CHeck
        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 60 ether, 0.1 ether);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 40 ether), false);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 40 ether + 1 ether), true);
    }

    function test_deposit_stEth() public {
        _setUp(TESTNET_FORK);
        
        vm.deal(alice, 100 ether);

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 50, 1000000);
        vm.stopPrank();

        vm.startPrank(alice);
        stEth.submit{value: 1 ether}(address(0));
        stEth.approve(address(liquifierInstance), 1 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 1 ether - 0.01 ether);
    }

    function test_deopsit_stEth_and_swap() public {
        _setUp(MAINNET_FORK);

        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        stEth.submit{value: 20 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();

        liquifierInstance.swapStEthToEth(1 ether, 1 ether  - 0.01 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 1 ether - 0.01 ether);
        assertGe(address(liquifierInstance).balance, 1 ether - 0.01 ether);
        _assertWithinRange(liquidityPoolInstance.getTotalPooledEther(), lpTvl, 0.001 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();

        liquifierInstance.withdrawEther();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl);
        _assertWithinRange(liquifierInstance.getTotalPooledEther(), 0, 0.000001 ether);
    }

    function test_deopsit_stEth_with_explicit_permit() public {
        _setUp(TESTNET_FORK);

        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        
        // Alice minted 2 stETH
        stEth.submit{value: 2 ether}(address(0));

        // But, she noticed that eETH is a much better choice 
        // and decided to convert her stETH to eETH
        
        // Deposit 1 stETH after approvals
        stEth.approve(address(liquifierInstance), 1 ether - 1);
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));

        stEth.approve(address(liquifierInstance), 1 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));

        // Deposit 1 stETH with the approval signature
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 1 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permitInput2);

        permitInput = createPermitInput(2, address(liquifierInstance), 1 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permitInput2);
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        _setUp(MAINNET_FORK);
        
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 10 ether}(address(0));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 10 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 10 ether, address(0), permitInput2);

        // Aliice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The protocol admin initiates the redemption process for 3500 stETH
        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance, lpBalance);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        liquifierInstance.withdrawEther();
        vm.stopPrank();

        // the cycle completes
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertEq(liquifierInstance.getTotalPooledEther() / 100, 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance + liquifierInstance.getTotalPooledEther(), lpBalance + 10 ether - 0.1 ether);

    }

    // EigenLayer will depreate the delegated withdrawar feature
    // But still, we need to support minting eETH for the already queued ones
    // Improve the test for later
    // TODO: test it after m2 upgrade
    function test_withdrawal_of_restaked_stEth_succeeds() internal {
        _setUp(MAINNET_FORK);

        uint256 liquifierTVL = liquifierInstance.getTotalPooledEther();
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 10 ether}(address(0));

        stEth.approve(address(eigenLayerStrategyManager), 10 ether);
        eigenLayerStrategyManager.depositIntoStrategy(stEthStrategy, stEthStrategy.underlyingToken(), 10 ether);

        IDelegationManager.Withdrawal memory queuedWithdrawal = _get_queued_withdrawal_of_restaked_LST_before_m2();
        uint256 fee_charge = 1 * liquifierInstance.getFeeAmount();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertEq(stEth.balanceOf(address(liquifierInstance)), 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();
        liquifierTVL = liquifierInstance.getTotalPooledEther();

        _complete_queued_withdrawal_V2(queuedWithdrawal, stEthStrategy);

        assertGe(stEth.balanceOf(address(liquifierInstance)), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        _assertWithinRange(liquifierInstance.getTotalPooledEther(), liquifierTVL, 10);
        _assertWithinRange(liquidityPoolInstance.getTotalPooledEther(), lpTvl, 10);

        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        _finalizeLidoWithdrawals(reqIds);

        _assertWithinRange(liquifierInstance.getTotalPooledEther(), liquifierTVL, 10);
        _assertWithinRange(liquidityPoolInstance.getTotalPooledEther(), lpTvl, 10);
    }

    function test_erc20_queued_withdrawal_v2() public {
        _setUp(TESTNET_FORK);

        uint256 liquifierTVL = liquifierInstance.getTotalPooledEther();
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();

        // While this unit test works, after EL m2 upgrade,
        // this flow will be deprecated because setting 'wtihdrawer' != msg.sender won't be allowed within `queueWithdrawals`
        address actor = address(liquifierInstance);

        vm.deal(actor, 100 ether);
        vm.startPrank(actor);        
        stEth.submit{value: 1 ether}(address(0));

        stEth.approve(address(eigenLayerStrategyManager), 1 ether);
        eigenLayerStrategyManager.depositIntoStrategy(stEthStrategy, stEthStrategy.underlyingToken(), 1 ether);


        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = stEthStrategy;
        shares[0] = stEthStrategy.shares(actor);

        //  Queue withdrawal
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: actor
        });
        
        IDelegationManager.Withdrawal[] memory queuedWithdrawals = new IDelegationManager.Withdrawal[](1);
        queuedWithdrawals[0] = IDelegationManager.Withdrawal({
            staker: actor,
            delegatedTo: address(0),
            withdrawer: actor,
            nonce: uint96(eigenLayerDelegationManager.cumulativeWithdrawalsQueued(actor)),
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: shares
        });

        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        bytes32 withdrawalRoot = withdrawalRoots[0];

        assertTrue(eigenLayerDelegationManager.pendingWithdrawals(withdrawalRoot));

        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawals[0], address(0));
        vm.stopPrank();

        vm.roll(block.number + 7 days);

        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = stEthStrategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        bool[] memory receiveAsTokens = new bool[](1);
        receiveAsTokens[0] = true;

        vm.startPrank(owner);
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
        vm.stopPrank();

    }

    function _get_queued_withdrawal_of_restaked_LST_before_m2() internal returns (IDelegationManager.Withdrawal memory) {
        IStrategy strategy = stEthStrategy;

        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = strategy;
        shares[0] = strategy.shares(alice);

        // Step 1 - Queued withdrawal
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: address(liquifierInstance)
        });
        
        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        bytes32 withdrawalRoot = withdrawalRoots[0];
        assertEq(eigenLayerStrategyManager.withdrawalRootPending(withdrawalRoot), true);

        // Step 2 - Mint eETH
        IDelegationManager.Withdrawal memory queuedWithdrawal = IDelegationManager.Withdrawal({
            staker: alice,
            delegatedTo: address(0),
            withdrawer: address(liquifierInstance),
            nonce: uint96(eigenLayerStrategyManager.numWithdrawalsQueued(alice)),
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: shares
        });
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        // multipme mints using the same queued withdrawal fails
        vm.expectRevert("Deposited");
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        return queuedWithdrawal;
    }

    function _enable_deposit(address _strategy) internal {
        IEigenLayerStrategyTVLLimits strategyTVLLimits = IEigenLayerStrategyTVLLimits(_strategy);

        address role = strategyTVLLimits.pauserRegistry().unpauser();
        vm.startPrank(role);
        eigenLayerStrategyManager.unpause(0);
        strategyTVLLimits.unpause(0);
        strategyTVLLimits.setTVLLimits(1_000_000_0 ether, 1_000_000_0 ether);
        vm.stopPrank();
    }

    function _complete_queued_withdrawal(IStrategyManager.DeprecatedStruct_QueuedWithdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + 7 days);

        IStrategyManager.DeprecatedStruct_QueuedWithdrawal[] memory queuedWithdrawals = new IStrategyManager.DeprecatedStruct_QueuedWithdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        // liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);

        vm.expectRevert();
        // liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
    }

    function _complete_queued_withdrawal_V2(IDelegationManager.Withdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + 7 days);

        IDelegationManager.Withdrawal[] memory queuedWithdrawals = new IDelegationManager.Withdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);

        vm.expectRevert();
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
    }


    function test_pancacke_wbETH_swap() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        uint256 inputAmount = 650 ether;

        vm.startPrank(alice);

        vm.expectRevert("Too little received");
        liquifierInstance.pancakeSwapForEth(address(wbEth), inputAmount, 500, 2 * inputAmount, 3600);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeBalance = address(liquifierInstance).balance;

        uint256 exchangeRate = IWBETH(address(wbEth)).exchangeRate();
        uint256 maxSlippageBp = 100;
        uint256 minOutput = (exchangeRate * inputAmount * (10000 - maxSlippageBp)) / 10000 / 1e18;
        liquifierInstance.pancakeSwapForEth(address(wbEth), inputAmount, 500, minOutput, 3600);

        assertGe(address(liquifierInstance).balance, beforeBalance + minOutput);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), beforeTVL); // does not change till Oracle updates

        vm.stopPrank();
    }

    function test_pancacke_cbETH_swap() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        uint256 inputAmount = 1 ether;

        vm.startPrank(alice);

        vm.expectRevert("Too little received");
        liquifierInstance.pancakeSwapForEth(address(cbEth), inputAmount, 500, 2 * inputAmount, 3600);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeBalance = address(liquifierInstance).balance;

        uint256 exchangeRate = IWBETH(address(cbEth)).exchangeRate();
        uint256 maxSlippageBp = 1000; // 10%
        uint256 minOutput = (exchangeRate * inputAmount * (10000 - maxSlippageBp)) / 10000 / 1e18;
        liquifierInstance.pancakeSwapForEth(address(cbEth), inputAmount, 500, minOutput, 3600);

        assertGe(address(liquifierInstance).balance, beforeBalance + minOutput);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), beforeTVL); // does not change till Oracle updates

        vm.stopPrank();
    }

    function test_case1() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.startPrank(owner);

        liquifierInstance.CASE1();

        vm.expectRevert();
        liquifierInstance.CASE1();

        vm.stopPrank();
    }

}