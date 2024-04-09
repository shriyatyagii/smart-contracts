// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./EtherFiAvsOperator.sol";


contract EtherFiAvsOperatorsManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    UpgradeableBeacon public upgradableBeacon;
    uint256 public nextAvsOperatorId;
 
    mapping(uint256 => EtherFiAvsOperator) public avsOperators;

    IDelegationManager public delegationManager;
    
 
    event CreatedEtherFiAvsOperator(uint256 indexed id, address etherFiAvsOperator);
    event RegisteredOperator(uint256 indexed id, address avsContract, bytes quorumNumbers, string socket, IBLSApkRegistry.PubkeyRegistrationParams params, ISignatureUtils.SignatureWithSaltAndExpiry operatorSignature);
    event DeregisteredOperator(uint256 indexed id, address avsContract, bytes quorumNumbers);
    event RegisteredAsOperator(uint256 indexed id, IDelegationManager.OperatorDetails detail);
    event ModifiedOperatorDetails(uint256 indexed id, IDelegationManager.OperatorDetails newOperatorDetails);
    event UpdatedOperatorMetadataURI(uint256 indexed id, string metadataURI);
    event UpdatedAvsNodeOperator(uint256 indexed id, address avsNodeOperator);
    event UpdatedAvsWhitelist(uint256 indexed id, address avsContract, bool isWhitelisted);
    event UpdatedEcdsaSigner(uint256 indexed id, address ecdsaSigner);

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize to set variables on deployment
    function initialize(address _delegationManager) external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextAvsOperatorId = 1;
        upgradableBeacon = new UpgradeableBeacon(address(new EtherFiAvsOperator()));      
        delegationManager = IDelegationManager(_delegationManager);
    }

    function registerOperator(
        uint256 _id,
        address _avsContract,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external onlyOperator(_id) {
        avsOperators[_id].registerOperator(_avsContract, _quorumNumbers, _socket, _params, _operatorSignature);

        emit RegisteredOperator(_id, _avsContract, _quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        uint256 _id,
        address _avsContract,
        bytes calldata _quorumNumbers, 
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external onlyOperator(_id) {
        avsOperators[_id].registerOperatorWithChurn(_avsContract, _quorumNumbers, _socket, _params, _operatorKickParams, _churnApproverSignature, _operatorSignature);

        emit RegisteredOperator(_id, _avsContract, _quorumNumbers, _socket, _params, _operatorSignature);
    }

    function deregisterOperator(
        uint256 _id,
        address _avsContract,
        bytes calldata quorumNumbers
    ) external onlyOperator(_id) {
        avsOperators[_id].deregisterOperator(_avsContract, quorumNumbers);

        emit DeregisteredOperator(_id, _avsContract, quorumNumbers);
    }

    function registerAsOperator(uint256 _id, IDelegationManager.OperatorDetails calldata _detail, string calldata _metaDataURI) external onlyOwner {
        avsOperators[_id].registerAsOperator(delegationManager, _detail, _metaDataURI);

        emit RegisteredAsOperator(_id, _detail);
    }

    function modifyOperatorDetails(uint256 _id, IDelegationManager.OperatorDetails calldata _newOperatorDetails) external onlyOperator(_id) {
        avsOperators[_id].modifyOperatorDetails(delegationManager, _newOperatorDetails);

        emit ModifiedOperatorDetails(_id, _newOperatorDetails);
    }

    function updateOperatorMetadataURI(uint256 _id, string calldata _metadataURI) external onlyOperator(_id) {
        avsOperators[_id].updateOperatorMetadataURI(delegationManager, _metadataURI);

        emit UpdatedOperatorMetadataURI(_id, _metadataURI);
    }

    function updateAvsNodeOperator(uint256 _id, address _avsNodeOperator) external onlyOwner {
        avsOperators[_id].updateAvsNodeOperator(_avsNodeOperator);

        emit UpdatedAvsNodeOperator(_id, _avsNodeOperator);
    }

    function updateAvsWhitelist(uint256 _id, address _avsContract, bool _isWhitelisted) external onlyOwner {
        avsOperators[_id].updateAvsWhitelist(_avsContract, _isWhitelisted);

        emit UpdatedAvsWhitelist(_id, _avsContract, _isWhitelisted);
    }

    function updateEcdsaSigner(uint256 _id, address _ecdsaSigner) external onlyOwner {
        avsOperators[_id].updateEcdsaSigner(_ecdsaSigner);

        emit UpdatedEcdsaSigner(_id, _ecdsaSigner);
    }

    function instantiateEtherFiAvsOperator(uint256 _nums) external onlyOwner returns (uint256[] memory _ids) {
        _ids = new uint256[](_nums);
        for (uint256 i = 0; i < _nums; i++) {
            _ids[i] = _instantiateEtherFiAvsOperator();
        }
    }

    function upgradeEtherFiAvsOperator(address _newImplementation) public onlyOwner {
        upgradableBeacon.upgradeTo(_newImplementation);
    }

    function _instantiateEtherFiAvsOperator() internal  returns (uint256 _id) {
        _id = nextAvsOperatorId++;
        require(address(avsOperators[_id]) == address(0), "INVALID_ID");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        avsOperators[_id] = EtherFiAvsOperator(address(proxy));
        avsOperators[_id].initialize(address(this));

        emit CreatedEtherFiAvsOperator(_id, address(avsOperators[_id]));

        return _id;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyOperator(uint256 _id) {
        require(msg.sender == avsOperators[_id].avsNodeOperator() || msg.sender == owner(), "INCORRECT_CALLER");
        _;
    }

}