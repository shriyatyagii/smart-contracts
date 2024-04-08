// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IEigenPod.sol";
import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-libraries/BeaconChainProofs.sol";

import "../src/UUPSProxy.sol";
import "../src/EtherFiAvsOperator.sol";

import "./eigenlayer-utils/ProofParsing.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";
import {BitmapUtils} from "../src/eigenlayer-libraries/BitmapUtils.sol";
import {BN254} from "../src/eigenlayer-libraries/BN254.sol";
import {IBLSApkRegistry} from "../src/eigenlayer-interfaces/IBLSApkRegistry.sol";
// import {MockAVSDeployer} from "./eigenlayer-middleware/test/utils/MockAVSDeployer.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";


contract EigenLayerIntegraitonTest is TestSetup, ProofParsing {

    uint256 MAX_QUORUM_BITMAP = type(uint192).max;
    uint8 numQuorums = 192;
    uint256 maxOperatorsToRegister = 1;
    uint256 pseudoRandomNumber = 1;
    uint8 maxQuorumsToRegisterFor = 4;
    uint32 registrationBlockNumber = 100;
    uint32 blocksBetweenRegistrations = 10;
    address defaultOperator = address(1000);


    struct OperatorMetadata {
        uint256 quorumBitmap;
        address operator;
        bytes32 operatorId;
        BN254.G1Point pubkey;
        uint96[] stakes; // in every quorum for simplicity
    }

    EtherFiAvsOperator avsOperator;

    address p2p;
    address dsrv;

    uint256[] validatorIds;
    uint256 validatorId;
    IEigenPod eigenPod;
    address podOwner;
    bytes pubkey;
    EtherFiNode ws;

    // Params to _verifyWithdrawalCredentials
    uint64 oracleTimestamp;
    BeaconChainProofs.StateRootProof stateRootProof;
    uint40[] validatorIndices;
    bytes[] withdrawalCredentialProofs;
    bytes[] validatorFieldsProofs;
    bytes32[][] validatorFields;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        _perform_eigenlayer_upgrade();
        _perform_etherfi_upgrade();

        p2p = address(1000);
        dsrv = address(1001);

        // - Mainnet
        // https://beaconcha.in/validator/1293592#withdrawals
        // bid Id = validator Id = 21397
        validatorId = 21397;
        pubkey = hex"a9c09c47ad6c0c5c397521249be41c8b81b139c3208923ec3c95d7f99c57686ab66fe75ea20103a1291578592d11c2c2";

        // {EigenPod, EigenPodOwner} used in EigenLayer's unit test
        eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        podOwner = managerInstance.etherfiNodeAddress(validatorId);
        validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;
        ws = EtherFiNode(payable(podOwner));

        // Override with Mock
        vm.startPrank(eigenLayerEigenPodManager.owner());
        beaconChainOracleMock = new BeaconChainOracleMock();
        beaconChainOracle = IBeaconChainOracle(address(beaconChainOracleMock));
        eigenLayerEigenPodManager.updateBeaconChainOracle(beaconChainOracle);
        vm.stopPrank();

        vm.startPrank(owner);
        managerInstance.initializeOnUpgrade2(address(eigenLayerDelegationManager));
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        vm.stopPrank();
    }

    function _setWithdrawalCredentialParams() public {
        validatorIndices = new uint40[](1);
        withdrawalCredentialProofs = new bytes[](1);
        validatorFieldsProofs = new bytes[](1);
        validatorFields = new bytes32[][](1);

        // Set beacon state root, validatorIndex
        stateRootProof.beaconStateRoot = getBeaconStateRoot();
        stateRootProof.proof = getStateRootProof();
        validatorIndices[0] = uint40(getValidatorIndex());
        withdrawalCredentialProofs[0] = abi.encodePacked(getWithdrawalCredentialProof()); // Validator fields are proven here
        // validatorFieldsProofs[0] = abi.encodePacked(getValidatorFieldsProof());
        validatorFields[0] = getValidatorFields();

        // Get an oracle timestamp        
        vm.warp(block.timestamp + 1 days);
        oracleTimestamp = uint64(block.timestamp);
    }

    function _setOracleBlockRoot() internal {
        bytes32 latestBlockRoot = getLatestBlockRoot();
        beaconChainOracleMock.setOracleBlockRootAtTimestamp(latestBlockRoot);
    }

    function _beacon_process_1ETH_deposit() internal {
        setJSON("./test/eigenlayer-utils/test-data/ValidatorFieldsProof_1293592_8654000.json");
        
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();
    }

    function _beacon_process_32ETH_deposit() internal {
        setJSON("./test/eigenlayer-utils/test-data/ValidatorFieldsProof_1293592_8746783.json");
        
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();
    }

    function _beacon_process_partial_withdrawals() internal {
        // TODO
    }

    function create_validator() public returns (uint256, address, EtherFiNode) {        
        uint256[] memory validatorIds = launch_validator(1, 0, true);
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);
        EtherFiNode node = EtherFiNode(payable(nodeAddress));

        return (validatorIds[0], nodeAddress, node);
    }

    // What need to happen after EL mainnet launch
    // per EigenPod
    // - call `activateRestaking()` to empty the EigenPod contract and disable `withdrawBeforeRestaking()`
    // - call `verifyWithdrawalCredentials()` to register the validator by proving that it is active
    // - call `delegateTo` for delegation

    // Call EigenPod.activateRestaking()
    function test_activateRestaking() public {
        bytes4 selector = bytes4(keccak256("activateRestaking()"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);

        vm.prank(owner);
        managerInstance.callEigenPod(validatorIds, data);
    }

    function test_verifyWithdrawalCredentials_1ETH() public {
        _beacon_process_1ETH_deposit();

        test_activateRestaking();

        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(initialShares, 0, "Shares should be 0 ETH in wei before verifying withdrawal credentials");
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.INACTIVE, "Validator status should be INACTIVE");
        assertEq(validatorInfo.validatorIndex, 0);
        assertEq(validatorInfo.restakedBalanceGwei, 0);
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, 0);

        // 2. Trigger a function
        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        // 3. Check the result
        int256 updatedShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(updatedShares, 1e18, "Shares should be 1 ETH in wei after verifying withdrawal credentials");
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.ACTIVE, "Validator status should be ACTIVE");
        assertEq(validatorInfo.validatorIndex, validatorIndices[0], "Validator index should be set");
        assertEq(validatorInfo.restakedBalanceGwei, 1 ether / 1e9, "Restaked balance should be 1 eth0");
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, oracleTimestamp, "Most recent balance update timestamp should be set");
    }

    function test_verifyAndProcessWithdrawals_OnlyOnce() public {
        test_verifyWithdrawalCredentials_1ETH();
        
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);

        // Can perform 'verifyWithdrawalCredentials' only once
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyCorrectWithdrawalCredentials: Validator must be inactive to prove withdrawal credentials");
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();
    }

    // https://holesky.beaconcha.in/validator/1644305#deposits
    function test_verifyWithdrawalCredentials_32ETH() public {
        _beacon_process_32ETH_deposit();

        test_activateRestaking();

        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(initialShares, 0, "Shares should be 0 ETH in wei before verifying withdrawal credentials");
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.INACTIVE, "Validator status should be INACTIVE");
        assertEq(validatorInfo.validatorIndex, 0);
        assertEq(validatorInfo.restakedBalanceGwei, 0);
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, 0);

        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);
        vm.prank(owner);
        managerInstance.callEigenPod(validatorIds, data);

        int256 updatedShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(updatedShares, 32e18, "Shares should be 32 ETH in wei after verifying withdrawal credentials");
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.ACTIVE, "Validator status should be ACTIVE");
        assertEq(validatorInfo.validatorIndex, validatorIndices[0], "Validator index should be set");
        assertEq(validatorInfo.restakedBalanceGwei, 32 ether / 1e9, "Restaked balance should be 32 eth");
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, oracleTimestamp, "Most recent balance update timestamp should be set");
    }

    function test_verifyBalanceUpdates_FAIL_1() public {
        _beacon_process_32ETH_deposit();
        
        test_activateRestaking();

        bytes4 selector = bytes4(keccak256("verifyBalanceUpdates(uint64,uint40[],(bytes32,bytes),bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, validatorIndices, stateRootProof, withdrawalCredentialProofs, validatorFields);

        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);

        // Calling 'verifyBalanceUpdates' before 'verifyWithdrawalCredentials' should fail
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyBalanceUpdate: Validator not active");
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        vm.warp(oracleTimestamp + 5 hours);

        // If the proof is too old, it should fail
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyBalanceUpdates: specified timestamp is too far in past");
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();
    }

    function test_verifyBalanceUpdates_32ETH() public {
        test_verifyWithdrawalCredentials_1ETH();

        _beacon_process_32ETH_deposit();

        vm.warp(block.timestamp + 1);

        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("verifyBalanceUpdates(uint64,uint40[],(bytes32,bytes),bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, validatorIndices, stateRootProof, withdrawalCredentialProofs, validatorFields);

        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(eigenLayerEigenPodManager.podOwnerShares(podOwner), 32e18, "Shares should be 32 ETH in wei after verifying withdrawal credentials");
        assertEq(validatorInfo.restakedBalanceGwei, 32 ether / 1e9, "Restaked balance should be 32 eth");
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, oracleTimestamp, "Most recent balance update timestamp should be set");
    }

    function test_verifyAndProcessWithdrawals_32ETH() public {
        // TODO
    }

    function test_createDelayedWithdrawal() public {
        test_verifyWithdrawalCredentials_32ETH();

        bytes4 selector = bytes4(keccak256("createDelayedWithdrawal(address,address)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, podOwner, alice);

        vm.prank(owner);
        vm.expectRevert("DelayedWithdrawalRouter.onlyEigenPod: not podOwner's EigenPod");
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);
    }

    function test_sweep() public {
        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();

        test_activateRestaking();

        (uint256 new_withdrawalSafe, uint256 new_eigenPod, uint256 new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(new_withdrawalSafe, _withdrawalSafe, "withdrawalSafe should not change");
        assertEq(new_eigenPod, 0, "eigenPod should be emptied");
        assertEq(new_delayedWithdrawalRouter, _eigenPod + _delayedWithdrawalRouter, "funds in eigenPod should be moved to delayedWithdrawalRouter");

        vm.roll(block.number + (50400) + 1);

        ws.claimQueuedWithdrawals(1, false);
        
        (uint256 new_new_withdrawalSafe, uint256 new_new_eigenPod, uint256 new_new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(new_new_withdrawalSafe, _withdrawalSafe + _eigenPod);
        assertEq(new_new_eigenPod, 0);
        assertEq(new_new_delayedWithdrawalRouter, 0);
    }

    function test_recoverTokens() public {
        test_sweep();

        bytes4 selector = bytes4(keccak256("recoverTokens(address[],uint256[],address)"));
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        address[] memory recipients = new address[](1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, tokens, amounts, recipients);

        vm.prank(owner);
        vm.expectRevert("NOT_ALLOWED");
        managerInstance.callEigenPod(validatorIds, data);
    }

    function test_withdrawNonBeaconChainETHBalanceWei() public {
        test_sweep();

        // 1.
        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();

        _transferTo(address(eigenPod), 1 ether);

        // 2.
        (uint256 new_withdrawalSafe, uint256 new_eigenPod, uint256 new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, new_withdrawalSafe);
        assertEq(_eigenPod + 1 ether, new_eigenPod);
        assertEq(_delayedWithdrawalRouter, new_delayedWithdrawalRouter);

        bytes4 selector = bytes4(keccak256("withdrawNonBeaconChainETHBalanceWei(address,uint256)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, alice, 1 ether);

        vm.prank(owner);
        vm.expectRevert("INCORRECT_RECIPIENT");
        managerInstance.callEigenPod(validatorIds, data);        

        data[0] = abi.encodeWithSelector(selector, podOwner, 1 ether);
        vm.prank(owner);
        managerInstance.callEigenPod(validatorIds, data);

        // 3.
        (new_withdrawalSafe, new_eigenPod, new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, new_withdrawalSafe);
        assertEq(_eigenPod, new_eigenPod);
        assertEq(_delayedWithdrawalRouter + 1 ether, new_delayedWithdrawalRouter);

        vm.roll(block.number + (50400) + 1);

        ws.claimQueuedWithdrawals(5, false);
        
        // 4.
        (uint256 new_new_withdrawalSafe, uint256 new_new_eigenPod, uint256 new_new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe + 1 ether, new_new_withdrawalSafe);
        assertEq(_eigenPod, new_new_eigenPod);
        assertEq(_delayedWithdrawalRouter, new_new_delayedWithdrawalRouter);
    }

    function _registerAsOperator(address avs_operator) internal {
        assertEq(eigenLayerDelegationManager.isOperator(avs_operator), false);

        vm.startPrank(avs_operator);
        IDelegationManager.OperatorDetails memory detail = IDelegationManager.OperatorDetails({
            earningsReceiver: address(treasuryInstance),
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 0
        });
        eigenLayerDelegationManager.registerAsOperator(detail, "");
        vm.stopPrank();

        assertEq(eigenLayerDelegationManager.isOperator(avs_operator), true);
    }

    function test_registerAsOperator() public {
        _registerAsOperator(p2p);
        _registerAsOperator(dsrv);
    }

    // activateStaking & verifyWithdrawalCredentials & delegate to p2p
    function test_delegateTo() public {
        test_verifyWithdrawalCredentials_32ETH();

        test_registerAsOperator();

        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, p2p, signatureWithExpiry, bytes32(0));

        // Confirm, the earningsReceiver is set to treasuryInstance
        assertEq(eigenLayerDelegationManager.earningsReceiver(p2p), address(treasuryInstance));
        assertEq(eigenLayerDelegationManager.operatorShares(p2p, eigenLayerDelegationManager.beaconChainETHStrategy()), 0);
        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), false);

        vm.startPrank(owner);
        managerInstance.callDelegationManager(validatorIds, data);
        vm.stopPrank();

        assertEq(eigenLayerDelegationManager.operatorShares(p2p, eigenLayerDelegationManager.beaconChainETHStrategy()), 32 ether);
        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), true);
    }

    function test_undelegate() public {
        // 1. activateStaking & verifyWithdrawalCredentials & delegate to p2p & undelegate from p2p
        {
            bytes4 selector = bytes4(keccak256("undelegate(address)"));
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, podOwner);
            
            vm.prank(owner);
            vm.expectRevert("DelegationManager.undelegate: staker must be delegated to undelegate");
            managerInstance.callDelegationManager(validatorIds, data);

            test_delegateTo();

            vm.prank(owner);
            managerInstance.callDelegationManager(validatorIds, data);
        }

        // 2. delegate to dsrv
        {
            bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
            IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, dsrv, signatureWithExpiry, bytes32(0));

            vm.startPrank(owner);
            managerInstance.callDelegationManager(validatorIds, data);
            vm.stopPrank();
        }
    }

    // Only {eigenLayerOperatingAdmin / Admin / Owner} can perform EigenLayer-related actions
    function test_access_control() public {
        bytes4 selector = bytes4(keccak256(""));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);

        // FAIL
        vm.startPrank(chad);

        selector = bytes4(keccak256("nonBeaconChainETHBalanceWei()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callEigenPod(validatorIds, data);

        selector = bytes4(keccak256("ethPOS()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callDelegationManager(validatorIds, data);

        selector = bytes4(keccak256("domainSeparator()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callEigenPodManager(validatorIds, data);

        selector = bytes4(keccak256("withdrawalDelayBlocks()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);

        vm.stopPrank();

        // SUCCEEDS
        address el_operating_admin = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
        vm.startPrank(el_operating_admin);

        selector = bytes4(keccak256("nonBeaconChainETHBalanceWei()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callEigenPod(validatorIds, data);

        selector = bytes4(keccak256("ethPOS()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callEigenPodManager(validatorIds, data);

        selector = bytes4(keccak256("domainSeparator()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callDelegationManager(validatorIds, data);

        selector = bytes4(keccak256("withdrawalDelayBlocks()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);

        vm.stopPrank();

    }

    function _incrementAddress(address start, uint256 inc) internal pure returns(address) {
        return address(uint160(uint256(uint160(start) + inc)));
    }

    function _registerOperatorWithCoordinator(address operator, uint256 quorumBitmap, BN254.G1Point memory pubKey, uint96 stake) internal {
        // // quorumBitmap can only have 192 least significant bits
        // quorumBitmap &= MAX_QUORUM_BITMAP;

        // blsApkRegistry.setBLSPublicKey(operator, pubKey);

        // bytes memory quorumNumbers = BitmapUtils.bitmapToBytesArray(quorumBitmap);
        // for (uint i = 0; i < quorumNumbers.length; i++) {
        //     _setOperatorWeight(operator, uint8(quorumNumbers[i]), stake);
        // }

        // ISignatureUtils.SignatureWithSaltAndExpiry memory emptySignatureAndExpiry;
        // cheats.prank(operator);
        // registryCoordinator.registerOperator(quorumNumbers, defaultSocket, pubkeyRegistrationParams, emptySignatureAndExpiry);
    }

    function test_avs_operator() public {
        // initializeRealisticFork(TESTNET_FORK);
        // blsApkRegistry = IBLSApkRegistry(managerInstance.getBlsApkRegistry());
        // avsOperator = EtherFiAvsOperator(address(new UUPSProxy(address(new EtherFiAvsOperator()), "")));

        {
            OperatorMetadata[] memory operatorMetadatas = new OperatorMetadata[](maxOperatorsToRegister);
            for (uint i = 0; i < operatorMetadatas.length; i++) {
                // limit to 16 quorums so we don't run out of gas, make them all register for quorum 0 as well
                operatorMetadatas[i].quorumBitmap = uint256(keccak256(abi.encodePacked("quorumBitmap", pseudoRandomNumber, i))) & (1 << maxQuorumsToRegisterFor - 1) | 1;
                operatorMetadatas[i].operator = _incrementAddress(defaultOperator, i);
                operatorMetadatas[i].pubkey = BN254.hashToG1(keccak256(abi.encodePacked("pubkey", pseudoRandomNumber, i)));
                // operatorMetadatas[i].operatorId = operatorMetadatas[i].pubkey.hashG1Point();
                operatorMetadatas[i].operatorId = BN254.hashG1Point(operatorMetadatas[i].pubkey);
                operatorMetadatas[i].stakes = new uint96[](maxQuorumsToRegisterFor);
                for (uint j = 0; j < maxQuorumsToRegisterFor; j++) {
                    operatorMetadatas[i].stakes[j] = uint96(uint64(uint256(keccak256(abi.encodePacked("stakes", pseudoRandomNumber, i, j)))));
                }
            }

            // get the index in quorumBitmaps of each operator in each quorum in the order they will register
            uint256[][] memory expectedOperatorOverallIndices = new uint256[][](numQuorums);
            for (uint i = 0; i < numQuorums; i++) {
                uint32 numOperatorsInQuorum;
                // for each quorumBitmap, check if the i'th bit is set
                for (uint j = 0; j < operatorMetadatas.length; j++) {
                    if (operatorMetadatas[j].quorumBitmap >> i & 1 == 1) {
                        numOperatorsInQuorum++;
                    }
                }
                expectedOperatorOverallIndices[i] = new uint256[](numOperatorsInQuorum);
                uint256 numOperatorCounter;
                for (uint j = 0; j < operatorMetadatas.length; j++) {
                    if (operatorMetadatas[j].quorumBitmap >> i & 1 == 1) {
                        expectedOperatorOverallIndices[i][numOperatorCounter] = j;
                        numOperatorCounter++;
                    }
                }
            }

            // register operators
            // for (uint i = 0; i < operatorMetadatas.length; i++) {
            //     cheats.roll(registrationBlockNumber + blocksBetweenRegistrations * i);

            //     _registerOperatorWithCoordinator(operatorMetadatas[i].operator, operatorMetadatas[i].quorumBitmap, operatorMetadatas[i].pubkey, operatorMetadatas[i].stakes);
            // }
        }


        // uint256 MAX_QUORUM_BITMAP = type(uint192).max;

        // address defaultOperator = address(uint160(uint256(keccak256("defaultOperator"))));
        // bytes32 defaultOperatorId;
        // BN254.G1Point internal defaultPubKey =  BN254.G1Point(18260007818883133054078754218619977578772505796600400998181738095793040006897,3432351341799135763167709827653955074218841517684851694584291831827675065899);
        // string defaultSocket = "69.69.69.69:420";

        // // quorumBitmap can only have 192 least significant bits
        // quorumBitmap &= MAX_QUORUM_BITMAP;

        // blsApkRegistry.setBLSPublicKey(operator, pubKey);

        // bytes memory quorumNumbers = BitmapUtils.bitmapToBytesArray(quorumBitmap);
        // for (uint i = 0; i < quorumNumbers.length; i++) {
        //     _setOperatorWeight(operator, uint8(quorumNumbers[i]), stake);
        // }

        // ISignatureUtils.SignatureWithSaltAndExpiry memory emptySignatureAndExpiry;
        // cheats.prank(operator);
        // registryCoordinator.registerOperator(quorumNumbers, defaultSocket, pubkeyRegistrationParams, emptySignatureAndExpiry);
    }

}