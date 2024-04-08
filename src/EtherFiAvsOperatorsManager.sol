// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/proxy/beacon/IBeaconUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./EtherFiAvsOperator.sol";


contract EtherFiAvsOperatorsManager is
    Initializable,
    IBeaconUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    UpgradeableBeacon private upgradableBeacon;
    mapping(uint256 => EtherFiAvsOperator) public avsOperators;

    uint32 nextAvsOperatorId;
    uint32 numAvsOperators;

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize to set variables on deployment
    function initialize() external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextAvsOperatorId = 1;
        upgradableBeacon = new UpgradeableBeacon(address(new EtherFiAvsOperator()));      
    }


    function registerOperator(
        address _avsContract,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        avsOperators[_id].registerOperator(_avsContract, _quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        address _avsContract,
        bytes calldata _quorumNumbers, 
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        avsOperators[_id].registerOperatorWithChurn(_avsContract, _quorumNumbers, _socket, _params, _operatorKickParams, _churnApproverSignature, _operatorSignature);
    }

    function deregisterOperator(
        address _avsContract,
        bytes calldata quorumNumbers
    ) external managerOnly {
        avsOperators[_id].deregisterOperator(_avsContract, quorumNumbers);
    }

    function updateAvsNodeOperator(uint256 _id, address _avsNodeOperator) external onlyOwner {
        avsOperators[_id].updateAvsNodeOperator(_avsNodeOperator);
    }

    function updateAvsWhitelist(address _avsContract, bool _isWhitelisted) external onlyOwner {
        avsOperators[_id].updateAvsNodeOperator(_avsContract, _isWhitelisted);
    }

    function updateEcdsaSigner(address _ecdsaSigner) external onlyOwner {
        avsOperators[_id].updateEcdsaSigner(_ecdsaSigner);
    }

    function instantiateEtherFiAvsOperator() external onlyOwner returns (uint32 _id) {
        _id = nextAvsOperatorId++;
        require(avsOperators[_id] == address(0), "INVALID_ID");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        avsOperators[_id] = EtherFiAvsOperator(address(proxy));
        avsOperators[_id].initialize();
    }

    function upgradeEtherFiAvsOperator(address _newImplementation) public onlyOwner {
        upgradableBeacon.upgradeTo(_newImplementation);
    }

    modifier operatorOnly(uint256 _id) {
        require(msg.sender == avsOperators[_id].avsNodeOperator || msg.sender == owner(), "INCORRECT_CALLER");
        _;
    }

}