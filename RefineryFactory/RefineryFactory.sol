pragma solidity >=0.8.0;

import './interfaces/IRefineryFactory.sol';
import './interfaces/IRefineryPair.sol';
import './RefineryPair.sol';

contract RefineryFactory is IRefineryFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(RefineryPair).creationCode));

    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'Refinery: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Refinery: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'Refinery: PAIR_EXISTS'); // single check is sufficient
 
        pair = address(new RefineryPair{salt: keccak256(abi.encodePacked(token0, token1))}());
        IRefineryPair(pair).initialize(token0, token1);
        
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, 'Refinery: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(feeToSetter == msg.sender, 'Refinery: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}